import Foundation

/// Een afspraak zoals de DJ hem ziet.
struct AgendaEvent: Identifiable, Hashable, Sendable {
    let key: String
    let title: String
    let start: Date
    var location: String = ""
    var travelMinutes: Int = 0
    /// Korte, opgeschoonde omschrijving (zonder links en reistijdregel).
    var notes: String = ""
    /// Namen van de andere deelnemers.
    var attendees: [String] = []

    var id: String { key }

    /// Moment waarop je er moet zijn: begin van de afspraak, of je vertrektijd.
    var alertTime: Date { start.addingTimeInterval(-Double(travelMinutes) * 60) }

    /// "vertrek" als er reistijd is, anders "afspraak".
    var kind: String { travelMinutes > 0 ? "vertrek" : "afspraak" }
}

/// Een agenda, herkenbaar aan titel én bron (want meerdere heten "Calendar").
struct CalendarRef: Codable, Hashable, Sendable {
    let title: String
    let source: String

    func matches(title: String, source: String) -> Bool {
        Self.norm(self.title) == Self.norm(title) && Self.norm(self.source) == Self.norm(source)
    }

    private static func norm(_ s: String) -> String {
        s.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

/// De gegevens die we uit een EKEvent halen, los van EventKit, zodat het filter testbaar is.
struct RawEvent: Sendable {
    var identifier: String
    var title: String
    var start: Date
    var isAllDay = false
    var isCanceled = false
    var declinedByMe = false
    var location = ""
    var notes = ""
    /// Namen van de andere deelnemers (zonder jezelf).
    var attendees: [String] = []
    /// De private `travelTime` van Agenda.app, in seconden (0 = geen).
    var travelSeconds: Double = 0
}

enum EventFilter {
    static let travelRegex = try! NSRegularExpression(
        pattern: #"(?im)^\s*(?:reistijd|vertrek|travel)\s*[:=]\s*(\d+)"#)

    /// Reistijd in minuten uit de notities ("reistijd: 12"), of 0.
    static func travelMinutes(fromNotes notes: String) -> Int {
        let range = NSRange(notes.startIndex..., in: notes)
        guard let m = travelRegex.firstMatch(in: notes, range: range),
              let r = Range(m.range(at: 1), in: notes) else { return 0 }
        return Int(notes[r]) ?? 0
    }

    /// Omschrijving voor de DJ: zonder links, zonder de reistijdregel, hoogstens ~200 tekens.
    static func summary(ofNotes notes: String, limit: Int = 200) -> String {
        let lines = notes.components(separatedBy: .newlines).filter { line in
            travelMinutes(fromNotes: line) == 0
        }
        var text = lines.joined(separator: " ")
            .replacingOccurrences(of: #"(?i)(https?://|www\.)\S+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        if text.count > limit {
            let cut = text.prefix(limit)
            text = (cut.lastIndex(of: " ").map { String(cut[..<$0]) } ?? String(cut)) + "…"
        }
        return text
    }

    /// Zet een ruwe afspraak om, of `nil` als de DJ hem moet negeren.
    static func event(from raw: RawEvent, skipKeywords: [String]) -> AgendaEvent? {
        if raw.isAllDay || raw.isCanceled || raw.declinedByMe { return nil }
        let title = raw.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = title.lowercased()
        if skipKeywords.contains(where: { !$0.isEmpty && lower.contains($0.lowercased()) }) {
            return nil
        }
        var travel = Int(raw.travelSeconds / 60)
        if travel <= 0 { travel = travelMinutes(fromNotes: raw.notes) }
        let iso = ISO8601DateFormatter().string(from: raw.start)
        return AgendaEvent(key: "\(raw.identifier)@\(iso)",
                           title: title.isEmpty ? "Afspraak" : title,
                           start: raw.start,
                           location: raw.location.trimmingCharacters(in: .whitespacesAndNewlines),
                           travelMinutes: max(0, travel),
                           notes: summary(ofNotes: raw.notes),
                           attendees: Array(raw.attendees
                               .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                               .filter { !$0.isEmpty && !$0.contains("@") }
                               .prefix(4)))
    }
}
