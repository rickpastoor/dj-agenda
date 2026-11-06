import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") { GeneralSettings(model: model) }
            Tab("Calendars", systemImage: "calendar") { CalendarSettings(model: model) }
            Tab("API Keys", systemImage: "key") { KeySettings() }
        }
        .frame(width: 520)
    }
}

private struct GeneralSettings: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            Section("Playback") {
                Picker("Play through", selection: $model.outputMode) {
                    ForEach(AutoOutput.Mode.allCases) { Text($0.label).tag($0) }
                }
                CommitField("Sonos IP (fallback)", text: model.sonosHost, prompt: "optional") {
                    model.sonosHost = $0
                }
                Stepper(value: $model.sonosClipBoost, in: SonosOutput.clipBoostRange) {
                    LabeledContent("DJ volume on Sonos",
                                   value: model.sonosClipBoost == 0 ? "same as the music"
                                       : "\(model.sonosClipBoost > 0 ? "+" : "")\(model.sonosClipBoost) relative to the music")
                }
                LabeledContent("Now playing on", value: model.deviceName)
            }
            Section("DJ") {
                CommitField("Your name", text: model.listenerName, prompt: "for \"Radio …\"") {
                    model.listenerName = $0
                }
                Picker("DJ language", selection: $model.language) {
                    ForEach(Language.allCases) { Text($0.label).tag($0) }
                }
                Picker("Voice", selection: $model.voiceChoice) {
                    ForEach(DJVoice.Choice.allCases) { Text($0.label).tag($0) }
                }
                Picker("Script", selection: $model.textEngine) {
                    ForEach(TextWriter.Engine.allCases) { Text($0.label).tag($0) }
                }
                LabeledContent("Current voice", value: model.voiceName)
            }
            Section("System") {
                LaunchAtLoginToggle()
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// "Start bij inloggen" via `SMAppService`. De status komt van macOS zelf, zodat hij klopt als je
/// hem in Systeeminstellingen → Algemeen → Inloggen wijzigt.
private struct LaunchAtLoginToggle: View {
    @State private var status = SMAppService.mainApp.status
    @State private var error: String?

    var body: some View {
        Toggle("Launch at login", isOn: Binding(get: { status == .enabled || status == .requiresApproval },
                                                   set: set))
            .onAppear { status = SMAppService.mainApp.status }
        if status == .requiresApproval {
            HStack {
                Text("Allow DJ Agenda in System Settings.")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Open") { SMAppService.openSystemSettingsLoginItems() }
            }
        }
        if let error {
            Text(error).foregroundStyle(.red).font(.callout)
        }
    }

    private func set(_ on: Bool) {
        error = nil
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            self.error = "Couldn't change this: \(error.localizedDescription)"
        }
        status = SMAppService.mainApp.status
    }
}

/// Tekstveld dat pas opslaat bij Enter of als je het veld verlaat.
private struct CommitField: View {
    let label: String
    let text: String
    var prompt = ""
    let commit: (String) -> Void

    @State private var draft = ""
    @FocusState private var focused: Bool

    init(_ label: String, text: String, prompt: String = "", commit: @escaping (String) -> Void) {
        self.label = label
        self.text = text
        self.prompt = prompt
        self.commit = commit
    }

    var body: some View {
        TextField(label, text: $draft, prompt: Text(prompt))
            .focused($focused)
            .onAppear { draft = text }
            .onSubmit(save)
            .onChange(of: focused) { _, now in if !now { save() } }
    }

    private func save() {
        let value = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if value != text { commit(value) }
    }
}

private struct CalendarSettings: View {
    let model: AppModel

    var body: some View {
        Form {
            switch model.access {
            case .granted:
                let all = model.availableCalendars
                let sources = Array(Set(all.map(\.ref.source))).sorted()
                ForEach(sources, id: \.self) { source in
                    Section(source) {
                        ForEach(all.filter { $0.ref.source == source }) { cal in
                            Toggle(isOn: Binding(get: { model.isSelected(cal.ref) },
                                                 set: { model.setSelected(cal.ref, $0) })) {
                                HStack(spacing: 6) {
                                    Circle().fill(Color(cgColor: cal.color ?? CGColor(gray: 0.5, alpha: 1)))
                                        .frame(width: 9, height: 9)
                                    Text(cal.ref.title)
                                }
                            }
                        }
                    }
                }
                if all.isEmpty { Text("No calendars found.").foregroundStyle(.secondary) }
            case .denied:
                Text("DJ Agenda doesn't have access to your calendars.")
                Button("Open Privacy Settings…") { model.openCalendarPrivacy() }
            case .unknown:
                Text("Loading calendars…").foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(minHeight: 300, maxHeight: 520)
    }
}

private struct KeySettings: View {
    var body: some View {
        Form {
            Section {
                Label {
                    Text("Before you paste a key, set a low monthly spend limit and a usage alert in the Mistral or Anthropic console. DJ Agenda uses very little, but a limit is always a good idea, in case a key ever leaks.")
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.shield").foregroundStyle(.orange)
                }
            }
            Section {
                ForEach(APIKey.allCases) { APIKeyRow(key: $0) }
            } footer: {
                Text("Keys are stored in your Keychain, not in the app's settings, and are never logged.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct APIKeyRow: View {
    let key: APIKey

    @State private var input = ""
    @State private var stored: String?
    @State private var status: Status = .idle

    enum Status: Equatable {
        case idle, checking, ok, failed(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(key.label).font(.headline)
                Spacer()
                Link("Create a key…", destination: key.consoleURL).font(.callout)
            }
            HStack {
                SecureField(stored == nil ? "Paste your key here" : "Paste a new key to replace it",
                            text: $input)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(save)
                Button("Save", action: save)
                    .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            HStack(spacing: 10) {
                statusText
                Spacer()
                if stored != nil {
                    Button("Test") { Task { await check(stored!) } }
                        .disabled(status == .checking)
                    Button("Remove", role: .destructive) {
                        Keychain.delete(service: key.service)
                        refresh()
                        status = .idle
                    }
                }
            }
            .font(.callout)
        }
        .padding(.vertical, 4)
        .onAppear(perform: refresh)
    }

    @ViewBuilder private var statusText: some View {
        switch status {
        case .checking:
            ProgressView().controlSize(.small)
            Text("Checking…").foregroundStyle(.secondary)
        case .ok:
            Label("Works (\(masked))", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed(let why):
            Label(why, systemImage: "xmark.octagon.fill").foregroundStyle(.red).lineLimit(2)
        case .idle:
            if stored != nil {
                Label("Saved (\(masked))", systemImage: "key.fill").foregroundStyle(.secondary)
            } else if key.value != nil {
                Text("From \(key.environmentName)").foregroundStyle(.secondary)
            } else {
                Text("Not set").foregroundStyle(.secondary)
            }
        }
    }

    private var masked: String {
        guard let s = stored, s.count > 4 else { return "••••" }
        return "••••" + s.suffix(4)
    }

    private func refresh() {
        stored = key.stored
    }

    private func save() {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        guard Keychain.save(value, service: key.service) else {
            status = .failed("Couldn't save to the Keychain")
            return
        }
        input = ""
        refresh()
        Task { await check(value) }
    }

    private func check(_ value: String) async {
        status = .checking
        switch await key.check(value) {
        case .success: status = .ok
        case .failure(let e): status = .failed(e.localizedDescription)
        }
    }
}
