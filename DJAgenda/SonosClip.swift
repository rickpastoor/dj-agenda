import AVFoundation
import Foundation

/// De DJ als audioclip op een Sonos, via de lokale WebSocket-API op poort 1443 (zoals
/// het PyPI-pakket `sonos-websocket` en Home Assistant doen). De Sonos duckt de muziek zelf.
final class SonosClip: NSObject, URLSessionDelegate, @unchecked Sendable {
    static let apiKey = "123e4567-e89b-12d3-a456-426655440000"

    enum Failure: LocalizedError {
        case noPlayer, noClipSupport, refused(String), badReply

        var errorDescription: String? {
            switch self {
            case .noPlayer: "Sonos-speler niet gevonden in getGroups"
            case .noClipSupport: "Deze Sonos ondersteunt geen audioclips (AUDIO_CLIP)"
            case .refused(let r): "Sonos weigert de clip: \(r)"
            case .badReply: "Onverwacht antwoord van de Sonos"
            }
        }
    }

    let host: String
    private var session: URLSession!
    private var playerID: String?

    var websocketURL: URL { URL(string: "wss://\(host):1443/websocket/api")! }

    init(host: String) {
        self.host = host
        super.init()
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 6
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    /// Speel een clip af en wacht tot hij klaar is.
    func play(_ audioURL: URL, duration: TimeInterval, volume: Int) async throws {
        var request = URLRequest(url: websocketURL)
        request.setValue(Self.apiKey, forHTTPHeaderField: "X-Sonos-Api-Key")
        request.setValue("v1.api.smartspeaker.audio", forHTTPHeaderField: "Sec-WebSocket-Protocol")
        let ws = session.webSocketTask(with: request)
        ws.resume()
        defer { ws.cancel(with: .normalClosure, reason: nil) }

        // 1. householdId: dit "ongeldige" commando geeft hem toch terug.
        let hello = try await send(ws, [:], [:])
        guard let household = hello.header["householdId"] as? String else { throw Failure.badReply }

        // 2. De speler bij deze websocket-URL, en kan hij clips afspelen?
        if playerID == nil {
            let groups = try await send(ws, ["namespace": "groups:1", "command": "getGroups",
                                             "householdId": household], [:])
            let players = groups.body["players"] as? [[String: Any]] ?? []
            guard let me = players.first(where: { ($0["websocketUrl"] as? String) == websocketURL.absoluteString })
            else { throw Failure.noPlayer }
            guard (me["capabilities"] as? [String] ?? []).contains("AUDIO_CLIP") else { throw Failure.noClipSupport }
            playerID = me["id"] as? String
        }
        guard let playerID else { throw Failure.noPlayer }

        // 3. De clip.
        var options: [String: Any] = ["name": "DJ Agenda", "appId": "nl.rickpastoor.dj-agenda",
                                      "streamUrl": audioURL.absoluteString]
        if volume > 0 { options["volume"] = volume }
        let reply = try await send(ws, ["namespace": "audioClip:1", "command": "loadAudioClip",
                                        "householdId": household, "playerId": playerID], options)
        if let ok = reply.header["success"] as? Bool, !ok {
            throw Failure.refused(String(describing: reply.body))
        }
        // De Sonos meldt niet betrouwbaar wanneer de clip klaar is: zelf de duur afwachten.
        try await Task.sleep(for: .seconds(duration + 0.6))
    }

    private struct Reply {
        var header: [String: Any]
        var body: [String: Any]
    }

    /// Stuur `[command, options]` en wacht op het antwoord met hetzelfde cmdId.
    private func send(_ ws: URLSessionWebSocketTask, _ command: [String: Any],
                      _ options: [String: Any]) async throws -> Reply {
        var cmd = command
        let id = UUID().uuidString
        cmd["cmdId"] = id
        let data = try JSONSerialization.data(withJSONObject: [cmd, options])
        try await ws.send(.string(String(data: data, encoding: .utf8)!))
        for _ in 0..<10 {
            let message = try await ws.receive()
            let raw: Data
            switch message {
            case .string(let s): raw = Data(s.utf8)
            case .data(let d): raw = d
            @unknown default: continue
            }
            guard let arr = try JSONSerialization.jsonObject(with: raw) as? [Any], arr.count >= 2,
                  let header = arr[0] as? [String: Any] else { continue }
            // Events en andere antwoorden overslaan.
            if let replyID = header["cmdId"] as? String, replyID != id { continue }
            return Reply(header: header, body: arr[1] as? [String: Any] ?? [:])
        }
        throw Failure.badReply
    }

    // Het certificaat van de Sonos is zelfondertekend: alleen voor dit IP accepteren.
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge)
        async -> (URLSession.AuthChallengeDisposition, URLCredential?)
    {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           challenge.protectionSpace.host == host,
           let trust = challenge.protectionSpace.serverTrust {
            return (.useCredential, URLCredential(trust: trust))
        }
        return (.performDefaultHandling, nil)
    }

    static func duration(of url: URL) -> TimeInterval {
        guard let f = try? AVAudioFile(forReading: url) else { return 6 }
        return Double(f.length) / f.fileFormat.sampleRate
    }
}
