import Foundation
import Observation
import OSLog

let log = Logger(subsystem: "nl.rickpastoor.dj-agenda", category: "app")

@MainActor
@Observable
final class AppModel {
    struct Row: Identifiable {
        let event: AgendaEvent
        /// Vanaf wanneer de DJ de nummers aan elkaar praat.
        let runUpFrom: Date
        var id: String { event.key }
    }

    private(set) var events: [AgendaEvent] = []
    private(set) var demoEvents: [AgendaEvent] = []
    private(set) var now = Date()
    private(set) var access: CalendarService.Access = .unknown
    private(set) var player: PlayerState?
    private(set) var playerError: String?
    private(set) var busy = false

    var enabled: Bool {
        didSet { settings.enabled = enabled }
    }

    let settings = Settings()
    private let calendar = CalendarService()
    @ObservationIgnored let speaker: Speaker
    @ObservationIgnored let voice: DJVoice
    @ObservationIgnored let writer: TextWriter
    @ObservationIgnored let mac: MacOutput
    @ObservationIgnored let sonos: SonosOutput
    @ObservationIgnored let output: AutoOutput
    @ObservationIgnored let server = AudioServer(port: 8765)
    @ObservationIgnored private var logic: RadioLogic
    /// Klaargezette tekst en audio, per `DJRequest.signature`.
    @ObservationIgnored private var prepared: (signature: String, task: Task<(String, URL?), Never>)?
    /// Telt op bij elke wijziging in stem of tekstmodel, zodat het menu ververst.
    private(set) var voiceStatus = 0
    private var loops: [Task<Void, Never>] = []

    init() {
        let speaker = Speaker()
        let settings = Settings()
        self.speaker = speaker
        mac = MacOutput(speaker: speaker)
        sonos = SonosOutput(room: settings.sonosRoom, fixedHost: settings.sonosHost, server: server, speaker: speaker)
        sonos.clipVolume = settings.clipVolume
        output = AutoOutput(mode: AutoOutput.Mode(rawValue: settings.outputMode) ?? .auto, mac: mac, sonos: sonos)
        voice = DJVoice(choice: DJVoice.Choice(stored: settings.voice) ?? .cloudMale)
        writer = TextWriter(engine: TextWriter.Engine(rawValue: settings.textEngine) ?? .mistral)
        let lang = Language(rawValue: settings.language) ?? .nl
        voice.language = lang
        writer.language = lang
        writer.listener = settings.listenerName
        logic = RadioLogic(config: settings.radioConfig)
        enabled = settings.enabled
        calendar.onChange = { [weak self] in self?.reload() }
        voice.voxtral.onStateChange = { [weak self] in self?.voiceStatus += 1 }
    }

    func start() {
        guard loops.isEmpty else { return }
        voice.warmUp()
        log.info("Taal: \(self.language.rawValue, privacy: .public); stem: \(self.voice.name, privacy: .public); tekst: \(self.writer.engine.rawValue, privacy: .public) (Apple-model beschikbaar: \(TextWriter.appleAvailable))")
        AudioFiles.cleanUp()
        loops.append(Task { [weak self] in
            await self?.calendar.requestAccess()
            while !Task.isCancelled {
                self?.reload()
                try? await Task.sleep(for: .seconds(60))
            }
        })
        loops.append(Task { [weak self] in
            while !Task.isCancelled {
                let sleep = await self?.radioTick() ?? 2
                try? await Task.sleep(for: .seconds(sleep))
            }
        })
        #if DEBUG
        if let test = UserDefaults.standard.string(forKey: "djTest") {
            Task { await self.runDebugTest(test) }
        }
        #endif
    }

    func reload() {
        now = Date()
        access = calendar.access
        events = calendar.upcoming(selected: settings.calendars,
                                   skipKeywords: settings.skipKeywords,
                                   lookaheadHours: settings.lookaheadHours,
                                   now: now)
        log.info("Agenda: \(self.events.count) afspraken (toegang: \(String(describing: self.access), privacy: .public))")
        demoEvents.removeAll { $0.alertTime.timeIntervalSince(now) < -120 }
    }

    /// Nep-afspraak over een paar minuten (zoals `--demo 3`).
    func addDemo(minutes: Double = 3) {
        let start = Date().addingTimeInterval(minutes * 60)
        let demo = Self.demos(language).randomElement()!
        demoEvents.append(AgendaEvent(key: "demo-\(start.timeIntervalSince1970)",
                                      title: demo.title, start: start, location: demo.location,
                                      notes: demo.notes, attendees: demo.attendees))
        now = Date()
        log.info("Demo-afspraak om \(start, privacy: .public)")
    }

    /// Nep-afspraken voor de testknop, met omschrijving en deelnemers.
    typealias Demo = (title: String, notes: String, attendees: [String], location: String)

    static func demos(_ lang: Language) -> [Demo] { lang == .nl ? demosNL : demosEN }

    static let demosEN: [Demo] = [
        ("Roadmap session", "Go through the priorities for the first quarter. Bring the numbers from the pilot.",
         ["Sarah Miller", "James Carter"], ""),
        ("Coffee with Peter", "Catching up about his new job at the city council.", ["Peter Hughes"], "The Swan Café"),
        ("Client demo Baker & Sons", "Show the new ordering app. Questions about the link with the till.",
         ["Ellen Baker", "Mark Davies"], ""),
        ("Interview frontend developer", "Second round. The candidate sent a portfolio with three apps.",
         ["Lisa Smith", "Tom Brown"], ""),
        ("Retrospective", "What went well, what can be better. Everyone brings one improvement.",
         ["Eve Martin", "Dan Price", "Nora Wells"], ""),
        ("Bike repair", "Fix the rear tyre and adjust the brakes.", [], "South Street Cycles"),
    ]

    static let demosNL: [Demo] = [
        ("Roadmap-sessie", "Prioriteiten voor het eerste kwartaal doornemen. Neem de cijfers van de pilot mee.",
         ["Sanne de Vries", "Joris Bakker"], ""),
        ("Koffie met Pieter", "Bijpraten over zijn nieuwe baan bij de gemeente.", ["Pieter Hendriks"], "Café De Zwaan"),
        ("Klantdemo Bakkerij Jansen", "Nieuwe bestelapp laten zien. Vragen over de koppeling met de kassa.",
         ["Ellen Jansen", "Mark Visser"], ""),
        ("Sollicitatiegesprek frontend developer", "Tweede ronde. Kandidaat heeft een portfolio met drie apps gestuurd.",
         ["Lisa Smit", "Tom de Boer"], ""),
        ("Retrospective", "Wat ging er goed, wat kan beter. Iedereen neemt één verbeterpunt mee.",
         ["Eva Mulder", "Daan Peters", "Noor Vermeulen"], ""),
        ("Fietsenmaker", "Achterband plakken en de remmen laten afstellen.", [], "Fietsenwinkel Zuid"),
    ]

    var allEvents: [AgendaEvent] { events + demoEvents }

    /// Komende afspraken (inclusief demo), met het moment waarop de DJ begint.
    var rows: [Row] {
        let runUp = settings.radioConfig.runUp
        return allEvents
            .filter { $0.alertTime.timeIntervalSince(now) >= -60 }
            .sorted { $0.alertTime < $1.alertTime }
            .map { Row(event: $0, runUpFrom: $0.alertTime.addingTimeInterval(-runUp)) }
    }

    /// Minuten tot de eerstvolgende afspraak (of vertrek), voor in de menubalk.
    var minutesToNext: Int? {
        guard let first = rows.first else { return nil }
        return max(0, Int((first.event.alertTime.timeIntervalSince(now) / 60).rounded(.up)))
    }

    /// Welk apparaat speelt, voor in het menu.
    var deviceName: String {
        if let playerError { return playerError }
        guard let p = player else { return "—" }
        let where_ = output.label
        switch p.status {
        case .notRunning: return "niets (Spotify staat uit)"
        case .stopped: return "\(where_) (gestopt)"
        case .paused: return "\(where_) (gepauzeerd)"
        case .playing: return where_
        }
    }

    /// Waarom de Sonos niet meedoet, als dat zo is.
    var sonosProblem: String? { _ = player; return output.sonosProblem }

    var outputMode: AutoOutput.Mode {
        get { _ = voiceStatus; return output.mode }
        set {
            output.mode = newValue
            settings.outputMode = newValue.rawValue
            output.retrySonosNow()
            voiceStatus += 1
        }
    }

    // MARK: - De DJ-lus

    /// Eén ronde: speler uitlezen, logica vragen wat er moet gebeuren, dat uitvoeren.
    private func radioTick() async -> TimeInterval {
        now = Date()
        do {
            player = try await output.state()
            playerError = nil
        } catch {
            player = nil
            playerError = error.localizedDescription
        }
        guard enabled, !busy else { return 2 }

        let decision = logic.tick(now: now, player: player, events: allEvents)
        for action in decision.actions {
            switch action {
            case .prepare(let req):
                prepare(req)
            case .speak(let req, let mode):
                await speak(req, mode: mode)
            }
        }
        return decision.sleep
    }

    @discardableResult
    private func prepare(_ req: DJRequest) -> Task<(String, URL?), Never> {
        if let p = prepared, p.signature == req.signature { return p.task }
        log.info("Klaarzetten: \(req.signature, privacy: .public)")
        let task = Task { [writer, voice] () -> (String, URL?) in
            let text = await writer.write(req)
            let audio = try? await voice.render(text)
            return (text, audio)
        }
        prepared = (req.signature, task)
        return task
    }

    private func speak(_ req: DJRequest, mode: SpeakMode) async {
        busy = true
        defer { busy = false; prepared = nil }
        mac.duckVolume = settings.duckVolume
        let (text, audio) = await prepare(req).value
        log.info("DJ (\(req.kind.rawValue, privacy: .public), \(String(describing: mode), privacy: .public)): \(text, privacy: .public)")
        guard let audio else { return }
        // De status van deze ronde is net gelezen; niet nog eens vragen, dan begint de DJ strakker.
        let fresh = player != nil ? nil : try? await output.active.state()
        let st = player ?? fresh ?? PlayerState(status: .playing, volume: 50)
        log.info("Via: \(self.output.label, privacy: .public), nog \(st.remaining, format: .fixed(precision: 1))s van het nummer")
        switch mode {
        case .overOutro: await output.overOutro(audio: audio, state: st)
        case .overIntro: await output.overIntro(audio: audio, state: st)
        case .pauseThenSpeak: await output.pauseThenSpeak(audio: audio)
        case .overMusicThenPause: await output.overMusicThenPause(audio: audio, state: st)
        }
    }

    /// Test: kondig de eerstvolgende afspraak meteen aan; praat ook als er niets speelt.
    func announceNow() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        mac.duckVolume = settings.duckVolume
        let st = try? await output.state()
        let text: String
        if let ev = rows.first?.event {
            let previous = st.flatMap { $0.title.isEmpty ? nil : TrackInfo(id: $0.trackID, title: $0.title, artist: $0.artist) }
            text = await writer.write(DJRequest(kind: .transition, events: [ev], at: Date(), previous: previous))
        } else {
            text = language == .nl ? "Je agenda is leeg. Nog even genieten van de muziek."
                                   : "Your calendar is empty. Just enjoy the music."
        }
        log.info("DJ (test): \(text, privacy: .public)")
        do {
            let audio = try await voice.render(text)
            log.info("Via: \(self.output.label, privacy: .public)")
            if let st, st.playing {
                await output.overIntro(audio: audio, state: st)
            } else {
                await output.idle(audio: audio)
            }
        } catch {
            log.error("Aankondigen mislukt: \(error.localizedDescription, privacy: .public)")
        }
    }

    #if DEBUG
    /// Ontwikkelhulp: `open DJAgenda.app --args -djTest announce` of `-djTest demo -djDemoMinutes 5`.
    private func runDebugTest(_ test: String) async {
        for _ in 0..<120 where voice.choice.isLocal && !voice.voxtral.isReady {
            try? await Task.sleep(for: .seconds(0.5))
        }
        log.info("Debugtest: \(test, privacy: .public)")
        switch test {
        case "announce":
            await announceNow()
        case "texts":
            // Drie wissels in de aanloop van één demo-afspraak, om de variatie te zien.
            let demo = Self.demos(language).randomElement()!
            let start = Date().addingTimeInterval(11 * 60)
            let ev = AgendaEvent(key: "demo", title: demo.title, start: start, location: demo.location,
                                 notes: demo.notes, attendees: demo.attendees)
            let tracks = [("Wake Me Up", "Avicii"), ("Dreams", "Fleetwood Mac"), ("Kom van dat dak af", "Peter Koelewijn")]
            for (i, t) in tracks.enumerated() {
                let req = DJRequest(kind: .transition, events: [ev],
                                    at: Date().addingTimeInterval(Double(i) * 210),
                                    previous: TrackInfo(id: "\(i)", title: t.0, artist: t.1))
                let text = await writer.write(req)
                log.info("Voorbeeld \(i + 1): \(text, privacy: .public)")
            }
            let fin = DJRequest(kind: .final, events: [ev], at: start)
            let slot = await writer.write(fin)
            log.info("Slot: \(slot, privacy: .public)")
        case "demo":
            let m = UserDefaults.standard.double(forKey: "djDemoMinutes")
            addDemo(minutes: m > 0 ? m : 3)
        default: break
        }
    }
    #endif

    // MARK: - Instellingen in het menu

    var voiceChoice: DJVoice.Choice {
        get { _ = voiceStatus; return voice.choice }
        set {
            voice.choice = newValue
            settings.voice = newValue.rawValue
            prepared = nil
            voiceStatus += 1
        }
    }

    var voiceName: String {
        _ = voiceStatus
        return voice.name
    }

    var language: Language {
        get { _ = voiceStatus; return writer.language }
        set {
            writer.language = newValue
            voice.language = newValue
            settings.language = newValue.rawValue
            prepared = nil
            voiceStatus += 1
        }
    }

    var listenerName: String {
        get { _ = voiceStatus; return writer.listener }
        set {
            settings.listenerName = newValue
            writer.listener = settings.listenerName
            prepared = nil
            voiceStatus += 1
        }
    }

    var sonosRoom: String {
        get { _ = voiceStatus; return sonos.room }
        set { sonos.room = newValue; settings.sonosRoom = newValue; sonosChanged() }
    }

    var sonosHost: String {
        get { _ = voiceStatus; return sonos.fixedHost }
        set { sonos.fixedHost = newValue; settings.sonosHost = newValue; sonosChanged() }
    }

    private func sonosChanged() {
        sonos.reset()
        output.retrySonosNow()
        voiceStatus += 1
    }

    var textEngine: TextWriter.Engine {
        get { _ = voiceStatus; return writer.engine }
        set {
            writer.engine = newValue
            settings.textEngine = newValue.rawValue
            prepared = nil
            voiceStatus += 1
        }
    }

    // MARK: - Agenda's kiezen

    var availableCalendars: [CalendarService.CalendarInfo] {
        _ = voiceStatus; _ = access
        return calendar.allCalendars()
    }

    func isSelected(_ ref: CalendarRef) -> Bool {
        _ = voiceStatus
        guard let selected = settings.calendars else { return true }
        return selected.contains { $0.matches(title: ref.title, source: ref.source) }
    }

    func setSelected(_ ref: CalendarRef, _ on: Bool) {
        // Nog nooit gekozen (alles aan): begin met alle agenda's.
        let current = settings.calendars ?? calendar.allCalendars().map(\.ref)
        var refs = current.filter { !$0.matches(title: ref.title, source: ref.source) }
        if on { refs.append(ref) }
        settings.calendars = refs
        voiceStatus += 1
        reload()
    }

    func openCalendarPrivacy() { CalendarService.openPrivacySettings() }
}
