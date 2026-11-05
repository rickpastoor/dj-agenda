import SwiftUI

struct MenuContent: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Toggle("DJ aan", isOn: $model.enabled)

        Divider()

        switch model.access {
        case .denied:
            Text("Geen toegang tot je agenda")
            Button("Open Privacy-instellingen…") { model.openCalendarPrivacy() }
        case .unknown:
            Text("Agenda laden…")
        case .granted:
            let rows = Array(model.rows.prefix(3))
            if rows.isEmpty {
                Text("Geen afspraken in de komende \(Int(model.settings.lookaheadHours)) uur")
            }
            ForEach(rows) { row in
                Text(Self.line(for: row))
            }
        }

        Divider()

        Text("Speelt op: \(model.deviceName)")
        if let problem = model.sonosProblem {
            Text("Sonos: \(problem)").foregroundStyle(.secondary)
        }
        if let p = model.player, p.status == .playing || p.status == .paused, !p.title.isEmpty {
            Text("♪ \(p.title) — \(p.artist)")
        }
        Button(model.busy ? "DJ is aan het woord…" : "Nu aankondigen") {
            Task { await model.announceNow() }
        }
        .disabled(model.busy)
        Divider()

        Button("Instellingen…") {
            // Menubalk-app zonder Dock-icoon: eerst naar voren halen, anders opent het venster erachter.
            NSApplication.shared.activate()
            openWindow(id: "settings")
        }
        .keyboardShortcut(",")
        Button("Stop DJ Agenda") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }

    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "nl_NL")
        f.dateFormat = "HH:mm"
        return f
    }()

    static func line(for row: AppModel.Row) -> String {
        let ev = row.event
        var s = "\(time.string(from: ev.start))  \(ev.title)"
        if ev.travelMinutes > 0 {
            s += " (vertrek \(time.string(from: ev.alertTime)))"
        }
        let from = row.runUpFrom.timeIntervalSinceNow <= 0 ? "nu" : "vanaf \(time.string(from: row.runUpFrom))"
        s += "  ·  DJ \(from)"
        return s
    }
}
