import SwiftUI

struct MenuContent: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Toggle("DJ on", isOn: $model.enabled)

        Divider()

        switch model.access {
        case .denied:
            Text("No access to your calendars")
            Button("Open Privacy Settings…") { model.openCalendarPrivacy() }
        case .unknown:
            Text("Loading calendars…")
        case .granted:
            let rows = Array(model.rows.prefix(3))
            if rows.isEmpty {
                Text("No meetings in the next \(Int(model.settings.lookaheadHours)) hours")
            }
            ForEach(rows) { row in
                Text(Self.line(for: row))
            }
        }

        Divider()

        Text("Playing on: \(model.deviceName)")
        if let problem = model.sonosProblem {
            Text("Sonos: \(problem)").foregroundStyle(.secondary)
        }
        if let p = model.player, p.status == .playing || p.status == .paused, !p.title.isEmpty {
            Text("♪ \(p.title) — \(p.artist)")
        }
        Button(model.busy ? "DJ is talking…" : "Announce Now") {
            Task { await model.announceNow() }
        }
        .disabled(model.busy)
        Divider()

        Button("Settings…") {
            // Menubalk-app zonder Dock-icoon: eerst naar voren halen, anders opent het venster erachter.
            NSApplication.shared.activate()
            openWindow(id: "settings")
        }
        .keyboardShortcut(",")
        Button("Quit DJ Agenda") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }

    /// Tijd in de notatie van de gebruiker (24 uur of AM/PM).
    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()

    static func line(for row: AppModel.Row) -> String {
        let ev = row.event
        var s = "\(time.string(from: ev.start))  \(ev.title)"
        if ev.travelMinutes > 0 {
            s += " (leave \(time.string(from: ev.alertTime)))"
        }
        let from = row.runUpFrom.timeIntervalSinceNow <= 0 ? "now" : "from \(time.string(from: row.runUpFrom))"
        s += "  ·  DJ \(from)"
        return s
    }
}
