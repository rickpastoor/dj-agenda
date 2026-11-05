import SwiftUI

@main
struct DJAgendaApp: App {
    @State private var model: AppModel

    init() {
        let model = AppModel()
        let isTesting = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        if !isTesting { model.start() }
        _model = State(initialValue: model)
    }

    /// Testen: `-djOpenSettings` opent bij het starten meteen het instellingenvenster.
    static var openSettingsAtLaunch: Bool {
        #if DEBUG
        CommandLine.arguments.contains("-djOpenSettings")
        #else
        false
        #endif
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: model)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.menu)

        Window("DJ Agenda Settings", id: "settings") {
            SettingsView(model: model)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(Self.openSettingsAtLaunch ? .presented : .suppressed)
    }
}

struct MenuBarLabel: View {
    let model: AppModel

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: model.enabled ? "radio.fill" : "radio")
            if model.enabled, let m = model.minutesToNext, m <= 60 {
                Text("\(m)m")
            }
        }
    }
}
