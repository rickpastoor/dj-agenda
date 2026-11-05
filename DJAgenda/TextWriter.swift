import Foundation
import Security
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Schrijft wat de DJ zegt: met Mistral of Claude (API), het lokale model van macOS, of vaste zinnen.
@MainActor
final class TextWriter {
    enum Engine: String, CaseIterable, Identifiable {
        case mistral, claude, apple, fixed

        var id: String { rawValue }
        var label: String {
            switch self {
            case .mistral: "Mistral Large (API)"
            case .apple: "On-device model (Apple)"
            case .claude: "Claude (API)"
            case .fixed: "Fixed phrases"
            }
        }
    }

    var engine: Engine
    var language: Language = .nl
    /// Hoe de DJ de luisteraar noemt ("Radio <naam>").
    var listener = "luisteraar"
    /// De laatste paar teksten, zodat de DJ zichzelf niet herhaalt.
    private(set) var recent: [String] = []

    init(engine: Engine) {
        self.engine = engine
    }

    static var appleAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            if case .available = SystemLanguageModel.default.availability { return true }
        }
        #endif
        return false
    }

    func write(_ req: DJRequest) async -> String {
        let text = await compose(req)
        recent = Array((recent + [text]).suffix(3))
        return text
    }

    private func compose(_ req: DJRequest) async -> String {
        if req.kind == .final { return DJText.finalText(req, avoiding: recent, lang: language) }
        let started = Date()
        do {
            let text: String?
            switch engine {
            case .apple: text = try await apple(req)
            case .mistral: text = try await checked(req, using: mistral)
            case .claude: text = try await checked(req, using: claude)
            case .fixed: text = nil
            }
            if let text {
                log.info("Tekst (\(self.engine.rawValue, privacy: .public), \(Date().timeIntervalSince(started), format: .fixed(precision: 1))s): \(text, privacy: .public)")
                return text
            }
        } catch {
            log.error("Tekst via \(self.engine.rawValue, privacy: .public) mislukt: \(error.localizedDescription, privacy: .public)")
        }
        return DJText.fallback(req, avoiding: recent, lang: language)
    }

    /// Een API-model, met dezelfde controle als het lokale model: drie pogingen, anders een vaste zin.
    private func checked(_ req: DJRequest,
                         using call: (_ system: String, _ user: String) async throws -> String?) async throws -> String? {
        let system = DJText.llmSystem(language, listener: listener)
        let payload = DJText.llmPayload(req, recent: recent, lang: language)
        for _ in 0..<3 {
            guard let text = try await call(system, payload).map(DJText.clean), !text.isEmpty else { return nil }
            if !DJText.isPlausible(text, prompt: payload, request: req, lang: language) {
                log.notice("Modeltekst afgekeurd (feiten): \(text, privacy: .public)")
            } else if DJText.repeats(text, recent: recent, request: req, lang: language) {
                log.notice("Modeltekst afgekeurd (herhaling): \(text, privacy: .public)")
            } else {
                return text
            }
        }
        return nil
    }

    // MARK: - Lokaal (Foundation Models)

    private func apple(_ req: DJRequest) async throws -> String? {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *), Self.appleAvailable else { return nil }
        if language != .nl {
            return try await checked(req) { system, user in
                let session = LanguageModelSession(instructions: system)
                return try await session.respond(to: user, options: GenerationOptions(temperature: 0.9)).content
            }
        }
        let prompt = DJText.applePrompt(req)
        var rng = SystemRandomNumberGenerator()
        // Drie pogingen; daarna een vaste zin.
        for _ in 0..<3 {
            let session = LanguageModelSession(instructions: DJText.appleInstructions(listener: listener, using: &rng))
            let response = try await session.respond(to: prompt, options: GenerationOptions(temperature: 0.9))
            let text = DJText.clean(response.content)
            if !DJText.isPlausible(text, prompt: prompt, request: req) {
                log.notice("Modeltekst afgekeurd (feiten): \(text, privacy: .public)")
            } else if DJText.repeats(text, recent: recent, request: req) {
                log.notice("Modeltekst afgekeurd (herhaling): \(text, privacy: .public)")
            } else {
                return text
            }
        }
        #endif
        return nil
    }

    // MARK: - Claude

    private func claude(system: String, user: String) async throws -> String? {
        guard let key = APIKey.anthropic.value else { return nil }

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        let body: [String: Any] = [
            "model": "claude-haiku-5-5",
            "max_tokens": 250,
            "thinking": ["type": "disabled"],
            "system": system,
            "messages": [["role": "user", "content": user]],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        struct Reply: Decodable {
            struct Block: Decodable { var type: String; var text: String? }
            var content: [Block]
            var stop_reason: String?
        }
        guard status == 200 else {
            throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey:
                "HTTP \(status): \(String(data: data.prefix(300), encoding: .utf8) ?? "")"])
        }
        let reply = try JSONDecoder().decode(Reply.self, from: data)
        guard reply.stop_reason != "refusal" else { return nil }
        let text = DJText.clean(reply.content.filter { $0.type == "text" }.compactMap(\.text).joined())
        return text.isEmpty ? nil : text
    }

    // MARK: - Mistral

    private func mistral(system: String, user: String) async throws -> String? {
        guard let key = APIKey.mistral.value else { return nil }
        var request = URLRequest(url: URL(string: "https://api.mistral.ai/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let body: [String: Any] = [
            "model": "mistral-large-latest",
            "temperature": 0.8,
            "max_tokens": 200,
            "messages": [["role": "system", "content": system], ["role": "user", "content": user]],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey:
                "HTTP \(status): \(String(data: data.prefix(300), encoding: .utf8) ?? "")"])
        }
        struct Reply: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable { var content: String? }
                var message: Message
                var finish_reason: String?
            }
            var choices: [Choice]
        }
        let reply = try JSONDecoder().decode(Reply.self, from: data)
        guard let choice = reply.choices.first, choice.finish_reason != "length" else { return nil }
        return choice.message.content
    }
}
