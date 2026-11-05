import Foundation

/// Instellingen van de DJ-logica.
struct RadioConfig: Equatable, Sendable {
    /// Vanaf hoe lang voor de afspraak de DJ de nummers aan elkaar praat.
    var runUp: TimeInterval = 12 * 60
    /// Begint de afspraak binnen deze tijd na het einde van het nummer, dan geen nieuw nummer meer.
    var finalCutoff: TimeInterval = 120
    /// Muziek die hoogstens zo laat na het begin start, krijgt alsnog het slot.
    var grace: TimeInterval = 60
    /// Zoveel seconden voor het einde van het nummer pauzeert de DJ voor het slot.
    var endMargin: TimeInterval = 1
    /// Zo ver vooruit worden tekst en audio klaargezet.
    var prepareLead: TimeInterval = 30
    /// Zoveel seconden voor het einde van het nummer begint de DJ te praten, over de outro heen;
    /// het volgende nummer start dan onder zijn stem (zoals op de radio).
    var talkOverLead: TimeInterval = 7
    /// Na een aankondiging bij een wissel zo lang niet nog eens (het slot gaat wel altijd door).
    var minGap: TimeInterval = 45
    /// Een nummer met een nieuw id en een positie hieronder is net begonnen.
    var newTrackPosition: TimeInterval = 6
    /// Afspraken die zo dicht bij elkaar liggen, gaan samen in één aankondiging.
    var groupWindow: TimeInterval = 60
}

struct TrackInfo: Equatable, Sendable {
    var id: String
    var title: String
    var artist: String
}

/// Wat de DJ moet zeggen.
struct DJRequest: Equatable, Sendable {
    enum Kind: String, Sendable {
        /// Tussen twee nummers in de aanloop.
        case transition
        /// "Tijd om naar je meeting te gaan."
        case final
    }

    var kind: Kind
    var events: [AgendaEvent]
    /// Het moment waarop de DJ (naar verwachting) praat; daarmee reken je de minuten uit.
    var at: Date
    /// Het nummer dat net speelde (alleen bij `transition`).
    var previous: TrackInfo?

    /// Gelijk bij hetzelfde soort aankondiging, zodat klaargezette audio te herkennen is.
    var signature: String {
        ([kind.rawValue, previous?.id ?? "-"] + events.map(\.key)).joined(separator: "|")
    }
}

enum SpeakMode: Equatable, Sendable {
    /// Het nummer is bijna klaar: muziek zachter, DJ over de outro en het begin van het volgende
    /// nummer heen, muziek terug.
    case overOutro
    /// Volgend nummer is net begonnen (bijvoorbeeld doorgeskipt): muziek zachter, DJ, muziek terug.
    case overIntro
    /// Slot bij de wissel: muziek pauzeren, dan de DJ.
    case pauseThenSpeak
    /// Slot midden in een nummer: muziek zachter, DJ, dan pauzeren.
    case overMusicThenPause
}

enum RadioAction: Equatable, Sendable {
    case prepare(DJRequest)
    case speak(DJRequest, SpeakMode)
}

struct RadioDecision: Equatable, Sendable {
    var actions: [RadioAction] = []
    /// Hoe lang tot de volgende ronde.
    var sleep: TimeInterval
}

/// De DJ-logica, zonder klok, speler of netwerk: je geeft de tijd en de speler mee, en krijgt
/// terug wat er moet gebeuren. Daardoor helemaal te testen met een nep-klok en nep-speler.
struct RadioLogic: Sendable {
    var config = RadioConfig()
    private(set) var current: TrackInfo?
    private(set) var previous: TrackInfo?
    /// Per afspraak: bij welke nummers de DJ al heeft gepraat.
    private var announcedAt: [String: Set<String>] = [:]
    /// Afspraken waarvoor het slot al is geweest (of die voorbij zijn).
    private var finished: Set<String> = []
    /// Nummers waarover de DJ al aan het eind heeft gepraat (dan niet nog eens bij de wissel).
    private var talkedOverOutro: Set<String> = []
    private var lastTransitionTalk: Date?

    init(config: RadioConfig = RadioConfig()) {
        self.config = config
    }

    /// De afspraken waar de DJ nu mee bezig is (de eerstvolgende, met wat er tegelijk begint).
    func activeGroup(now: Date, events: [AgendaEvent]) -> [AgendaEvent] {
        let pending = events
            .filter { ev in
                let toStart = ev.alertTime.timeIntervalSince(now)
                return !finished.contains(ev.key) && toStart <= config.runUp && -toStart <= config.grace
            }
            .sorted { $0.alertTime < $1.alertTime }
        guard let first = pending.first else { return [] }
        return pending.filter { $0.alertTime.timeIntervalSince(first.alertTime) <= config.groupWindow }
    }

    mutating func tick(now: Date, player: PlayerState?, events: [AgendaEvent]) -> RadioDecision {
        // Nummerwissel bijhouden.
        var trackChanged = false
        if let p = player, p.status == .playing || p.status == .paused,
           !p.trackID.isEmpty, p.trackID != current?.id {
            previous = current
            current = TrackInfo(id: p.trackID, title: p.title, artist: p.artist)
            trackChanged = true
        }

        // Afspraken die al te lang bezig zijn, laten we los.
        for ev in events where now.timeIntervalSince(ev.alertTime) > config.grace {
            finished.insert(ev.key)
        }

        let group = activeGroup(now: now, events: events)
        guard let first = group.first else { return RadioDecision(sleep: 2) }
        // Geen muziek, geen DJ.
        guard let p = player, p.playing else { return RadioDecision(sleep: 2) }

        let toStart = first.alertTime.timeIntervalSince(now)
        let keys = group.map(\.key)
        func final(at: Date) -> DJRequest { DJRequest(kind: .final, events: group, at: at) }

        // 1. De afspraak begint (of is net begonnen): over de muziek heen, dan pauzeren.
        if toStart <= 0 {
            finish(keys)
            return RadioDecision(actions: [.speak(final(at: now), .overMusicThenPause)], sleep: 1)
        }

        // 2. Er is net een nieuw nummer begonnen (ook bij handmatig doorskippen).
        let quiet = lastTransitionTalk.map { now.timeIntervalSince($0) < config.minGap } ?? false
        if trackChanged, !quiet, let prev = previous, !talkedOverOutro.contains(prev.id),
           p.position < config.newTrackPosition,
           !keys.allSatisfy({ announcedAt[$0, default: []].contains(p.trackID) }) {
            if toStart <= config.finalCutoff {
                // Dit nummer haalt het einde toch niet: meteen het slot.
                finish(keys)
                return RadioDecision(actions: [.speak(final(at: now), .pauseThenSpeak)], sleep: 1)
            }
            for k in keys { announcedAt[k, default: []].insert(p.trackID) }
            lastTransitionTalk = now
            let req = DJRequest(kind: .transition, events: group, at: now, previous: previous)
            return RadioDecision(actions: [.speak(req, .overIntro)], sleep: 1)
        }

        let remaining = p.remaining
        let startAfterSong = toStart - remaining

        // 3. Het nummer is bijna klaar en de afspraak begint kort daarna: geen nieuw nummer meer.
        if remaining <= config.endMargin, startAfterSong <= config.finalCutoff {
            finish(keys)
            return RadioDecision(actions: [.speak(final(at: now), .pauseThenSpeak)], sleep: 1)
        }

        // 4. Het nummer is bijna klaar en er komt nog een nummer: over de outro heen praten.
        if remaining <= config.talkOverLead, remaining > config.endMargin,
           p.position >= config.newTrackPosition, startAfterSong > config.finalCutoff, !quiet,
           let cur = current, !talkedOverOutro.contains(cur.id) {
            talkedOverOutro.insert(cur.id)
            lastTransitionTalk = now
            let req = DJRequest(kind: .transition, events: group, at: now.addingTimeInterval(remaining),
                                previous: cur)
            return RadioDecision(actions: [.speak(req, .overOutro)], sleep: 1)
        }

        // 5. Alvast klaarzetten (zelfde verzoek als bij 4, zodat de audio klaarligt).
        var actions: [RadioAction] = []
        if remaining <= config.prepareLead, remaining < toStart {
            let at = now.addingTimeInterval(remaining)
            if startAfterSong <= config.finalCutoff {
                actions.append(.prepare(final(at: at)))
            } else {
                actions.append(.prepare(DJRequest(kind: .transition, events: group, at: at,
                                                  previous: current)))
            }
        } else if toStart <= config.prepareLead {
            actions.append(.prepare(final(at: first.alertTime)))
        }

        // 6. Slapen tot er iets te doen is; kort rond het einde van een nummer en de start.
        let soonest = min(remaining - config.talkOverLead, toStart)
        let sleep = soonest < 8 ? 0.25 : max(0.25, min(2, soonest - 8))
        return RadioDecision(actions: actions, sleep: sleep)
    }

    private mutating func finish(_ keys: [String]) {
        finished.formUnion(keys)
    }
}
