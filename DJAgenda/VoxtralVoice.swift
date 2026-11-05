import AVFoundation
import Foundation
import VoxtralTTS

/// Mistral Voxtral TTS, lokaal via MLX (soniqo speech-swift). Model wordt één keer geladen.
@MainActor
final class VoxtralVoice {
    enum State: Equatable {
        case idle
        case loading(progress: Double)
        case ready
        case failed(String)
    }

    /// Lokale stemmen per taal en geslacht (Voxtral heeft geen "en_male"; de Engelse heten "casual_…").
    nonisolated static func voice(_ lang: Language, female: Bool) -> String {
        switch lang {
        case .nl: female ? "nl_female" : "nl_male"
        case .en: female ? "casual_female" : "casual_male"
        }
    }

    private(set) var state: State = .idle
    var onStateChange: (() -> Void)?
    private var model: VoxtralTTSModel?
    private var loadTask: Task<Void, Never>?

    var isReady: Bool { model != nil }

    /// Laadt het model op de achtergrond (de eerste keer ~2,4 GB downloaden).
    func load() {
        guard model == nil, loadTask == nil else { return }
        setState(.loading(progress: 0))
        loadTask = Task {
            let started = Date()
            do {
                let m = try await VoxtralTTSModel.fromPretrained { @Sendable progress, _ in
                    // De stem leeft net zo lang als de app, dus een sterke verwijzing is prima.
                    Task { @MainActor in
                        if case .loading = self.state { self.setState(.loading(progress: progress)) }
                    }
                }
                model = m
                setState(.ready)
                log.info("Voxtral geladen in \(Date().timeIntervalSince(started), format: .fixed(precision: 1))s")
            } catch {
                setState(.failed(error.localizedDescription))
                log.error("Voxtral laden mislukt: \(error.localizedDescription, privacy: .public)")
            }
            loadTask = nil
        }
    }

    func render(_ text: String, voice: String) async throws -> URL {
        guard let model else { throw CocoaError(.featureUnsupported) }
        let started = Date()
        let samples = try await model.generate(text: text, voice: voice)
        let url = AudioFiles.next()
        try WAV.write(samples, sampleRate: model.sampleRate, to: url)
        let seconds = Double(samples.count) / Double(model.sampleRate)
        log.info("Voxtral \(voice, privacy: .public): \(seconds, format: .fixed(precision: 1))s audio in \(Date().timeIntervalSince(started), format: .fixed(precision: 1))s")
        return url
    }

    private func setState(_ s: State) {
        state = s
        onStateChange?()
    }
}

enum WAV {
    /// Mono float-samples naar 16-bit PCM WAV.
    static func write(_ samples: [Float], sampleRate: Int, to url: URL) throws {
        guard !samples.isEmpty,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(sampleRate),
                                         channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))
        else { throw CocoaError(.fileWriteUnknown) }
        buffer.frameLength = buffer.frameCapacity
        let out = buffer.floatChannelData![0]
        for (i, s) in samples.enumerated() { out[i] = max(-1, min(1, s)) }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buffer)
    }
}

/// Voxtral TTS via de Mistral-API. Mistral heeft alleen Engelse vaste stemmen; daarom kloont hij
/// een kort fragment van de lokale Voxtral-stem (in `Resources/voice-<taal>-<geslacht>.wav`).
@MainActor
final class MistralVoice {
    private var references: [String: String] = [:]

    static func referenceURL(_ lang: Language, female: Bool) -> URL? {
        Bundle.main.url(forResource: "voice-\(lang.rawValue)-\(female ? "female" : "male")", withExtension: "wav")
    }

    func render(_ text: String, lang: Language, female: Bool) async throws -> URL {
        guard let key = APIKey.mistral.value else {
            throw URLError(.userAuthenticationRequired, userInfo: [NSLocalizedDescriptionKey: "no Mistral key"])
        }
        let refKey = "\(lang.rawValue)-\(female)"
        if references[refKey] == nil, let url = Self.referenceURL(lang, female: female) {
            references[refKey] = try Data(contentsOf: url).base64EncodedString()
        }
        guard let ref = references[refKey] else { throw CocoaError(.fileNoSuchFile) }

        let started = Date()
        var request = URLRequest(url: URL(string: "https://api.mistral.ai/v1/audio/speech")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": "voxtral-mini-tts-latest", "input": text, "ref_audio": ref, "response_format": "wav",
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey:
                "HTTP \(status): \(String(data: data.prefix(300), encoding: .utf8) ?? "")"])
        }
        struct Reply: Decodable { var audio_data: String }
        guard let audio = Data(base64Encoded: try JSONDecoder().decode(Reply.self, from: data).audio_data),
              !audio.isEmpty else { throw URLError(.cannotDecodeContentData) }
        let url = AudioFiles.next()
        try audio.write(to: url)
        let seconds = Double(audio.count) / 48_000   // 24 kHz, 16-bit mono
        log.info("Voxtral (cloud) \(refKey, privacy: .public): \(seconds, format: .fixed(precision: 1))s audio in \(Date().timeIntervalSince(started), format: .fixed(precision: 1))s")
        return url
    }
}

/// Kiest de stem: Voxtral in de cloud of lokaal, met de systeemstem als laatste terugval.
@MainActor
final class DJVoice: Voice {
    enum Choice: String, CaseIterable, Identifiable {
        case cloudMale = "cloud_male"
        case cloudFemale = "cloud_female"
        case localMale = "local_male"
        case localFemale = "local_female"
        case system

        /// Ook de oude waarden uit de instellingen ("nl_male", "nl_female").
        init?(stored: String) {
            switch stored {
            case "nl_male": self = .localMale
            case "nl_female": self = .localFemale
            default: self.init(rawValue: stored)
            }
        }

        var id: String { rawValue }
        var isCloud: Bool { self == .cloudMale || self == .cloudFemale }
        var isLocal: Bool { self == .localMale || self == .localFemale }
        var female: Bool { self == .cloudFemale || self == .localFemale }
        var label: String {
            switch self {
            case .cloudMale: "Voxtral cloud, male"
            case .cloudFemale: "Voxtral cloud, female"
            case .localMale: "Voxtral local, male"
            case .localFemale: "Voxtral local, female"
            case .system: "System voice"
            }
        }
    }

    var choice: Choice {
        didSet { if choice.isLocal { voxtral.load() } }
    }
    var language: Language = .nl {
        didSet { system.language = language }
    }
    let voxtral = VoxtralVoice()
    let cloud = MistralVoice()
    let system = SystemVoice()
    /// Mislukte de cloud de vorige keer? Dan staat dat in het menu.
    private(set) var cloudProblem: String?

    init(choice: Choice) {
        self.choice = choice
    }

    /// Lokaal model alvast laden (bij het opstarten), zodat de eerste aankondiging niet hoeft te wachten.
    /// Bij de cloudstem niet: dat scheelt 2,5 GB geheugen.
    func warmUp() {
        if choice.isLocal { voxtral.load() }
    }

    var name: String {
        switch choice {
        case .system: return system.name
        case .cloudMale, .cloudFemale:
            return cloudProblem.map { _ in "\(choice.label) (failed, using fallback)" } ?? choice.label
        case .localMale, .localFemale:
            switch voxtral.state {
            case .ready: return choice.label
            case .loading(let p): return "\(choice.label) (loading \(Int(p * 100))%, using \(system.name))"
            case .failed: return "\(system.name) (Voxtral failed)"
            case .idle: return system.name
            }
        }
    }

    func render(_ text: String) async throws -> URL {
        let url = try await renderRaw(text)
        do { try Loudness.normalize(url) } catch {
            log.error("Normaliseren mislukt: \(error.localizedDescription, privacy: .public)")
        }
        return url
    }

    private func renderRaw(_ text: String) async throws -> URL {
        if choice.isCloud {
            do {
                let url = try await cloud.render(text, lang: language, female: choice.female)
                cloudProblem = nil
                return url
            } catch {
                cloudProblem = error.localizedDescription
                log.error("Voxtral cloud mislukt (\(error.localizedDescription, privacy: .public)); terugval")
                voxtral.load()   // voor de volgende keer; nu de systeemstem als die nog niet klaar is
            }
        }
        if choice != .system, voxtral.isReady {
            do {
                return try await voxtral.render(text, voice: VoxtralVoice.voice(language, female: choice.female))
            } catch {
                log.error("Voxtral mislukt (\(error.localizedDescription, privacy: .public)), ik gebruik de systeemstem")
            }
        }
        return try await system.render(text)
    }
}
