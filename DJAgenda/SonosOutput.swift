import Foundation

/// Spotify Connect op een Sonos; de DJ als audioclip, die de muziek zelf zachter zet.
@MainActor
final class SonosOutput: Output {
    enum Failure: LocalizedError {
        case notFound(String)

        var errorDescription: String? {
            switch self {
            case .notFound(let what): "Sonos \(what.isEmpty ? "" : what + " ")not found. Does DJ Agenda have local network access? (System Settings → Privacy & Security → Local Network)"
            }
        }
    }

    /// Vast IP als terugval, voor als Bonjour niets vindt.
    var fixedHost: String
    /// De DJ volgt het volume van elke speaker, plus dit aantal stappen (de muziek gaat zelf zachter).
    var clipBoost = SonosOutput.defaultClipBoost
    nonisolated static let defaultClipBoost = 3
    nonisolated static let clipBoostRange = -10...15

    /// Clipvolume bij dit muziekvolume. Is dat onbekend, dan een rustige 20.
    nonisolated static func clipVolume(music: Int?, boost: Int) -> Int {
        guard let music else { return 20 }
        return min(max(music + boost, 3), 70)
    }

    /// Zo vaak kijkt de app opnieuw welke groep speelt.
    static let refreshInterval: TimeInterval = 10

    private let server: AudioServer
    private let speaker: Speaker
    /// Speakers die eerder antwoordden; elke speaker kent de hele indeling van het huis.
    private var knownHosts: [String] = []
    private(set) var group: SonosGroup?
    private var refreshedAt = Date.distantPast
    private var clips: [String: SonosClip] = [:]
    /// Eén verversing tegelijk, ook als de DJ-lus en de testknop tegelijk vragen.
    private var refreshing: Task<SonosGroup, Error>?

    init(fixedHost: String, server: AudioServer, speaker: Speaker) {
        self.fixedHost = fixedHost
        self.server = server
        self.speaker = speaker
    }

    var label: String { group.map { "Sonos \($0.name)" } ?? "Sonos" }

    func reset() {
        refreshing = nil
        group = nil
        refreshedAt = .distantPast
        knownHosts = []
        clips = [:]
    }

    // MARK: - Welke groep speelt

    /// Speelt deze groep muziek? Tv-geluid en line-in tellen niet: daar praat de DJ niet overheen.
    nonisolated static func playsMusic(state: String, uri: String) -> Bool {
        guard state == "PLAYING" || state == "TRANSITIONING" else { return false }
        return !["x-sonos-htastream:", "x-rincon-stream:"].contains { uri.hasPrefix($0) }
    }

    /// Volg de muziek: de groep van nu zolang die speelt (niet heen en weer springen), anders
    /// een groep die wel speelt. Speelt er niets, dan blijft de groep van nu (of de eerste).
    nonisolated static func pick(_ groups: [SonosGroup], playing: Set<String>, current: String?) -> SonosGroup? {
        let now = groups.first { $0.coordinator == current }
        if let now, playing.contains(now.coordinator) { return now }
        if let other = groups.filter({ playing.contains($0.coordinator) }).min(by: { $0.name < $1.name }) {
            return other
        }
        return now ?? groups.min { $0.name < $1.name }
    }

    private func currentGroup() async throws -> SonosGroup {
        if let group, Date().timeIntervalSince(refreshedAt) < Self.refreshInterval { return group }
        if let refreshing { return try await refreshing.value }
        let task = Task { try await self.refresh() }
        refreshing = task
        defer { refreshing = nil }
        return try await task.value
    }

    private func refresh() async throws -> SonosGroup {
        let groups = try await fetchGroups()

        // Per groep de coördinator vragen of hij speelt, allemaal tegelijk.
        let playing = await withTaskGroup(of: String?.self) { tasks in
            for g in groups {
                guard let host = g.coordinatorHost else { continue }
                tasks.addTask {
                    let client = SonosClient(host: host)
                    guard let state = try? await client.transportState(),
                          let info = try? await client.positionInfo(),
                          Self.playsMusic(state: state, uri: info.uri) else { return nil }
                    return g.coordinator
                }
            }
            var out = Set<String>()
            for await c in tasks { if let c { out.insert(c) } }
            return out
        }

        guard let chosen = Self.pick(groups, playing: playing, current: group?.coordinator) else {
            throw Failure.notFound("")
        }
        if chosen != group {
            log.info("Sonos: \(chosen.name, privacy: .public) (coördinator \(chosen.coordinatorHost ?? "?", privacy: .public)); speelt: \(groups.filter { playing.contains($0.coordinator) }.map(\.name).joined(separator: ", "), privacy: .public)")
            try? server.start()
        }
        group = chosen
        refreshedAt = Date()
        knownHosts = groups.flatMap { $0.members.map(\.host) }
        return chosen
    }

    /// De indeling ophalen bij een speaker die antwoordt. Eerst bekende adressen, dan Bonjour.
    private func fetchGroups() async throws -> [SonosGroup] {
        var tried = Set<String>()
        func attempt(_ hosts: [String]) async -> [SonosGroup]? {
            for h in hosts where !h.isEmpty && tried.insert(h).inserted {
                do { return try await SonosClient(host: h).groups() } catch {
                    log.error("Sonos \(h, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }
            return nil
        }
        // Dit is ook het moment dat macOS om toegang tot het lokale netwerk vraagt.
        if let g = await attempt([group?.coordinatorHost].compactMap { $0 } + knownHosts) { return g }
        let found = await SonosDiscovery.find()
        log.info("Sonos gevonden: \(found.map { "\($0.room) (\($0.host))" }.joined(separator: ", "), privacy: .public)")
        if let g = await attempt(found.map(\.host) + [fixedHost]) { return g }
        throw Failure.notFound("")
    }

    private func coordinatorClient() async throws -> SonosClient {
        let g = try await currentGroup()
        guard let host = g.coordinatorHost else { throw Failure.notFound(g.name) }
        return SonosClient(host: host)
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
            group = nil   // volgende keer opnieuw kijken welke groep speelt (IP kan veranderd zijn)
            throw error
        }
    }

    /// Clip op elke speaker van de groep tegelijk; lukt dat nergens, dan via de Mac-speakers.
    private func speak(_ audio: URL) async {
        do {
            let g = try await currentGroup()
            let hosts = g.visibleMembers.map(\.host)
            guard let first = hosts.first, let me = AudioServer.localAddress(toward: first) else {
                throw Failure.notFound("adres")
            }
            let url = server.url(for: audio, host: me)
            let duration = SonosClip.duration(of: audio)
            let boost = clipBoost
            let targets = hosts.map { h in (h, clips[h] ?? SonosClip(host: h)) }
            for (h, c) in targets { clips[h] = c }
            log.info("Clip naar \(g.name, privacy: .public) (\(hosts.joined(separator: ", "), privacy: .public)): \(url.absoluteString, privacy: .public)")
            let played = await withTaskGroup(of: Bool.self) { tasks in
                for (h, clip) in targets {
                    tasks.addTask {
                        let volume = Self.clipVolume(music: try? await SonosClient(host: h).volume(), boost: boost)
                        do { try await clip.play(url, duration: duration, volume: volume); return true } catch {
                            log.error("Audioclip op \(h, privacy: .public) mislukt: \(error.localizedDescription, privacy: .public)")
                            return false
                        }
                    }
                }
                var any = false
                for await ok in tasks { any = any || ok }
                return any
            }
            if !played { throw Failure.notFound("audioclip") }
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
