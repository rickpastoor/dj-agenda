import Foundation

/// Een plek waar Spotify speelt en de DJ praat: de Mac of een Sonos.
@MainActor
protocol Output: AnyObject {
    /// Voor in het menu: "Mac" of de naam van de Sonos.
    var label: String { get }
    func state() async throws -> PlayerState
    /// Nummer bijna klaar: DJ over de outro en het begin van het volgende nummer heen.
    func overOutro(audio: URL, state: PlayerState) async
    /// Volgend nummer is net begonnen: DJ over de intro heen.
    func overIntro(audio: URL, state: PlayerState) async
    /// Slot bij de wissel: muziek pauzeren, dan de DJ.
    func pauseThenSpeak(audio: URL) async
    /// Slot midden in een nummer: DJ over de muziek heen, dan pauzeren.
    func overMusicThenPause(audio: URL, state: PlayerState) async
    /// Er speelt niets (testknop).
    func idle(audio: URL) async
}

extension MacOutput: Output {
    var label: String { "Mac" }

    func overIntro(audio: URL, state: PlayerState) async {
        await overMusic(audio: audio, state: state)
    }

    func overOutro(audio: URL, state: PlayerState) async {
        await overMusic(audio: audio, state: state, quick: true)
    }
}

/// Kijkt zelf waar Spotify speelt: eerst de Sonos, anders de Mac.
@MainActor
final class AutoOutput: Output {
    enum Mode: String, CaseIterable, Identifiable {
        case auto, mac, sonos
        var id: String { rawValue }
        var label: String {
            switch self {
            case .auto: "Automatisch"
            case .mac: "Altijd de Mac"
            case .sonos: "Altijd de Sonos"
            }
        }
    }

    static let retryAfter: TimeInterval = 300

    var mode: Mode
    let mac: MacOutput
    let sonos: SonosOutput
    private(set) var active: Output
    private var sonosSkipUntil = Date.distantPast
    /// Waarom de Sonos niet meedoet (voor in het menu).
    private(set) var sonosProblem: String?

    init(mode: Mode, mac: MacOutput, sonos: SonosOutput) {
        self.mode = mode
        self.mac = mac
        self.sonos = sonos
        active = mac
    }

    var label: String { active.label }

    func state() async throws -> PlayerState {
        if mode != .mac, Date() >= sonosSkipUntil {
            do {
                let st = try await sonos.state()
                sonosProblem = nil
                if st.playing || mode == .sonos {
                    switchTo(sonos)
                    return st
                }
            } catch {
                sonosProblem = error.localizedDescription
                if mode == .sonos { throw error }
                // Niet steeds blijven hangen op een Sonos die niet antwoordt.
                sonosSkipUntil = Date().addingTimeInterval(Self.retryAfter)
                log.error("Sonos niet bereikbaar, ik gebruik de Mac; nieuwe poging over 5 minuten. \(error.localizedDescription, privacy: .public)")
            }
        }
        let st = try await mac.state()
        switchTo(mac)
        return st
    }

    /// Opnieuw proberen (bijvoorbeeld na het wijzigen van de instellingen).
    func retrySonosNow() {
        sonosSkipUntil = .distantPast
        sonos.reset()
    }

    private func switchTo(_ out: Output) {
        if out !== active {
            log.info("Spotify speelt nu op: \(out.label, privacy: .public)")
            active = out
        }
    }

    func overIntro(audio: URL, state: PlayerState) async { await active.overIntro(audio: audio, state: state) }
    func overOutro(audio: URL, state: PlayerState) async { await active.overOutro(audio: audio, state: state) }
    func pauseThenSpeak(audio: URL) async { await active.pauseThenSpeak(audio: audio) }
    func overMusicThenPause(audio: URL, state: PlayerState) async {
        await active.overMusicThenPause(audio: audio, state: state)
    }
    func idle(audio: URL) async { await active.idle(audio: audio) }
}
