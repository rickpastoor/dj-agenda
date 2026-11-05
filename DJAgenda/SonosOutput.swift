import Foundation

/// Spotify Connect op een Sonos; de DJ als audioclip, die de muziek zelf zachter zet.
@MainActor
final class SonosOutput: Output {
    enum Failure: LocalizedError {
        case notFound(String)

        var errorDescription: String? {
            switch self {
            case .notFound(let what): "Sonos \(what.isEmpty ? "" : what + " ")niet gevonden. Mag DJ Agenda bij het lokale netwerk? (Systeeminstellingen → Privacy en beveiliging → Lokaal netwerk)"
            }
        }
    }

    /// Kamernaam zoals in de Sonos-app (via Bonjour), en/of een vast IP als terugval.
    /// Allebei leeg: de eerste Sonos die speelt (of anders de eerste die antwoordt).
    var room: String
    var fixedHost: String
    var clipVolume = 35

    private let server: AudioServer
    private let speaker: Speaker
    private(set) var host: String?
    private var roomName: String?
    private var coordinator: String?
    private var coordinatorCheckedAt = Date.distantPast
    private var clip: SonosClip?
    /// Eén zoekopdracht tegelijk, ook als de DJ-lus en de testknop tegelijk vragen.
    private var resolving: Task<String, Error>?

    init(room: String, fixedHost: String, server: AudioServer, speaker: Speaker) {
        self.room = room
        self.fixedHost = fixedHost
        self.server = server
        self.speaker = speaker
    }

    var label: String { "Sonos \(roomName ?? (room.isEmpty ? "" : room))".trimmingCharacters(in: .whitespaces) }

    func reset() {
        resolving = nil
        host = nil
        coordinator = nil
        clip = nil
    }

    // MARK: - Verbinden

    private func resolve() async throws -> String {
        if let host { return host }
        if let resolving { return try await resolving.value }
        let task = Task { try await self.findSpeaker() }
        resolving = task
        defer { resolving = nil }
        return try await task.value
    }

    private func findSpeaker() async throws -> String {
        let anyRoom = room.isEmpty && fixedHost.isEmpty
        var candidates: [(host: String, room: String)] = []
        if !room.isEmpty || anyRoom {
            let found = await SonosDiscovery.find()
            log.info("Sonos gevonden: \(found.map { "\($0.room) (\($0.host))" }.joined(separator: ", "), privacy: .public)")
            candidates += found
                .filter { anyRoom || $0.room.caseInsensitiveCompare(room) == .orderedSame }
                .map { ($0.host, $0.room) }
        }
        if !fixedHost.isEmpty { candidates.append((fixedHost, room.isEmpty ? fixedHost : room)) }

        // Meteen testen of hij antwoordt; dit is ook het moment dat macOS om toestemming vraagt.
        // Zonder vaste kamer gaat een speler die speelt voor.
        var firstOK: (host: String, room: String)?
        for c in candidates {
            do {
                let state = try await SonosClient(host: c.host).transportState()
                if !anyRoom || state == "PLAYING" { return use(c) }
                if firstOK == nil { firstOK = c }
            } catch {
                log.error("Sonos \(c.host, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
        if let firstOK { return use(firstOK) }
        throw Failure.notFound(anyRoom ? "" : room.isEmpty ? fixedHost : "'\(room)'")
    }

    private func use(_ c: (host: String, room: String)) -> String {
        host = c.host
        roomName = c.room
        clip = SonosClip(host: c.host)
        try? server.start()
        log.info("Sonos: \(c.room, privacy: .public) op \(c.host, privacy: .public)")
        return c.host
    }

    /// Spotify Connect speelt op de groepscoördinator; af en toe opnieuw opzoeken.
    private func coordinatorClient() async throws -> SonosClient {
        let h = try await resolve()
        if coordinator == nil || Date().timeIntervalSince(coordinatorCheckedAt) > 30 {
            coordinator = (try? await SonosClient(host: h).coordinatorHost()) ?? h
            coordinatorCheckedAt = Date()
        }
        return SonosClient(host: coordinator ?? h)
    }

    // MARK: - Output

    static let states: [String: PlayerState.Status] = [
        "PLAYING": .playing, "TRANSITIONING": .playing,
        "PAUSED_PLAYBACK": .paused, "STOPPED": .stopped,
    ]

    /// Bij Spotify Connect is de TrackURI een sessie-adres dat voor elk nummer hetzelfde blijft
    /// (`x-sonos-vli:…`), dus herken je een nummer aan titel, artiest en duur.
    static func trackID(uri: String, title: String, artist: String, duration: Double) -> String {
        if uri.hasPrefix("x-sonos-vli:") || uri.isEmpty {
            return "\(title)|\(artist)|\(Int(duration))"
        }
        return uri
    }

    func state() async throws -> PlayerState {
        let co = try await coordinatorClient()
        do {
            let transport = try await co.transportState()
            let info = try await co.positionInfo()
            return PlayerState(status: Self.states[transport] ?? .paused,
                               position: info.position, duration: info.duration,
                               title: info.title, artist: info.artist, volume: 50,
                               trackID: Self.trackID(uri: info.uri, title: info.title,
                                                     artist: info.artist, duration: info.duration))
        } catch {
            reset()   // volgende keer opnieuw zoeken (IP kan veranderd zijn)
            throw error
        }
    }

    /// Clip op de Sonos; lukt dat niet, dan via de Mac-speakers.
    private func speak(_ audio: URL) async {
        do {
            _ = try await resolve()
            guard let host, let clip, let me = AudioServer.localAddress(toward: host) else {
                throw Failure.notFound("adres")
            }
            let url = server.url(for: audio, host: me)
            log.info("Clip naar \(host, privacy: .public): \(url.absoluteString, privacy: .public)")
            try await clip.play(url, duration: SonosClip.duration(of: audio), volume: clipVolume)
        } catch {
            log.error("Audioclip op Sonos mislukt (\(error.localizedDescription, privacy: .public)); ik speel de DJ via de Mac af.")
            await speaker.play(audio)
        }
    }

    func overIntro(audio: URL, state: PlayerState) async {
        await speak(audio)   // de Sonos zet de muziek zelf zachter
    }

    func overOutro(audio: URL, state: PlayerState) async {
        await speak(audio)   // idem; het volgende nummer start gewoon onder de clip
    }

    func pauseThenSpeak(audio: URL) async {
        try? await coordinatorClient().pause()
        await speak(audio)
    }

    func overMusicThenPause(audio: URL, state: PlayerState) async {
        await speak(audio)
        try? await coordinatorClient().pause()
    }

    func idle(audio: URL) async {
        await speak(audio)
    }
}
