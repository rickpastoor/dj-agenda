import Foundation

/// Spotify-app op de Mac, bestuurd via AppleScript; de DJ via de Mac-speakers.
@MainActor
final class MacOutput {
    enum Failure: LocalizedError {
        case script(String, code: Int)

        var errorDescription: String? {
            switch self {
            case .script(let msg, let code):
                code == -1743
                    ? "Geen toestemming om Spotify te besturen (Systeeminstellingen → Privacy en beveiliging → Automatisering)."
                    : "AppleScript-fout \(code): \(msg)"
            }
        }

        var notPermitted: Bool {
            if case .script(_, -1743) = self { return true }
            return false
        }
    }

    static let stateScript = """
    if application "Spotify" is running then
      tell application "Spotify"
        set s to player state as string
        if s is "stopped" then return "stopped"
        set t to current track
        set d to ASCII character 31
        return s & d & (player position as string) & d & ((duration of t) as string) & d & (name of t) & d & (artist of t) & d & (sound volume as string) & d & (id of t)
      end tell
    end if
    return "not_running"
    """

    var duckVolume = 25
    private let speaker: Speaker
    private let runner = AppleScriptRunner()

    init(speaker: Speaker) {
        self.speaker = speaker
    }

    private func spotify(_ command: String) async throws {
        try await runner.run("tell application \"Spotify\" to \(command)")
    }

    func state() async throws -> PlayerState {
        PlayerState.parseSpotify(try await runner.run(Self.stateScript))
    }

    private func fade(from start: Int, to end: Int, seconds: Double = 1.5, steps: Int = 10) async {
        for i in 1...steps {
            try? await spotify("set sound volume to \(start + (end - start) * i / steps)")
            try? await Task.sleep(for: .seconds(seconds / Double(steps)))
        }
        // Spotify zet het volume vaak één te laag (73 wordt 72); zonder correctie zakt het
        // volume bij elke aankondiging een stapje.
        if let actual = try? await state().volume, actual != end {
            try? await spotify("set sound volume to \(min(100, max(0, end + (end - actual))))")
        }
    }

    // MARK: - De DJ laten praten

    func pause() async throws {
        try await spotify("pause")
    }

    /// Volume omlaag, DJ, volume terug. Met `quick` (zoals een radio-DJ aan het eind van een nummer)
    /// duikt het volume in 0,6 s omlaag en begint de DJ meteen, tijdens het faden.
    func overMusic(audio: URL, state st: PlayerState, quick: Bool = false) async {
        let duck = min(duckVolume, st.volume)
        if quick {
            let down = Task { await fade(from: st.volume, to: duck, seconds: 0.6, steps: 6) }
            await speaker.play(audio)
            await down.value
        } else {
            await fade(from: st.volume, to: duck)
            await speaker.play(audio)
        }
        await fade(from: duck, to: st.volume)
    }

    /// Slot bij de wissel: muziek stil, dan de DJ. De muziek blijft daarna op pauze.
    func pauseThenSpeak(audio: URL) async {
        try? await pause()
        await speaker.play(audio)
    }

    /// Slot midden in een nummer: volume omlaag, DJ, pauzeren, en het volume terugzetten
    /// zodat de muziek straks weer normaal klinkt.
    func overMusicThenPause(audio: URL, state st: PlayerState) async {
        let duck = min(duckVolume, st.volume)
        await fade(from: st.volume, to: duck)
        await speaker.play(audio)
        await fade(from: duck, to: max(duck / 2, 1), seconds: 0.8, steps: 4)
        try? await pause()
        await fade(from: max(duck / 2, 1), to: st.volume, seconds: 0.1, steps: 1)
    }

    /// Er speelt niets: gewoon uitspreken (alleen voor de testknop).
    func idle(audio: URL) async {
        await speaker.play(audio)
    }
}

/// Voert AppleScript uit op een eigen seriële wachtrij. Zo blijft het menu reageren, ook als
/// macOS om toestemming vraagt of Spotify traag antwoordt.
private final class AppleScriptRunner: @unchecked Sendable {
    private let queue = DispatchQueue(label: "nl.rickpastoor.dj-agenda.applescript")
    private var compiled: [String: NSAppleScript] = [:]   // alleen op `queue`

    @discardableResult
    func run(_ source: String) async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            queue.async { cont.resume(with: Result { try self.execute(source) }) }
        }
    }

    private func execute(_ source: String) throws -> String {
        let script: NSAppleScript
        if let s = compiled[source] {
            script = s
        } else {
            guard let s = NSAppleScript(source: source) else {
                throw MacOutput.Failure.script("kan script niet maken", code: 0)
            }
            compiled[source] = s
            script = s
        }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            throw MacOutput.Failure.script(error[NSAppleScript.errorMessage] as? String ?? "onbekend",
                                           code: error[NSAppleScript.errorNumber] as? Int ?? 0)
        }
        return result.stringValue ?? ""
    }
}
