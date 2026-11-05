import Foundation

/// Wat er speelt.
struct PlayerState: Equatable, Sendable {
    enum Status: String, Sendable {
        case playing, paused, stopped
        case notRunning = "not_running"
    }

    var status: Status
    var position: Double = 0
    /// Seconden; 0 = onbekend (podcast, radio, advertentie).
    var duration: Double = 0
    var title = ""
    var artist = ""
    var volume = 50
    var trackID = ""

    var playing: Bool { status == .playing }

    var remaining: Double {
        duration <= 0 ? .infinity : max(0, duration - position)
    }

    static let separator: Character = "\u{1F}"

    /// Leest de uitvoer van `MacOutput.stateScript`.
    static func parseSpotify(_ out: String) -> PlayerState {
        let parts = out.split(separator: separator, omittingEmptySubsequences: false).map(String.init)
        guard parts.count > 1 else {
            return PlayerState(status: Status(rawValue: out) ?? .notRunning)
        }
        let p = parts + Array(repeating: "", count: max(0, 7 - parts.count))
        return PlayerState(status: Status(rawValue: p[0]) ?? .paused,
                           position: number(p[1]),
                           duration: number(p[2]) / 1000,   // Spotify geeft milliseconden
                           title: p[3], artist: p[4],
                           volume: Int(number(p[5])),
                           trackID: p[6])
    }

    /// De Nederlandse locale geeft een komma.
    static func number(_ s: String) -> Double {
        Double(s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")) ?? 0
    }
}
