import Foundation
import Security

/// Generieke wachtwoorden in de login-Keychain, op service-naam.
enum Keychain {
    static let account = "rick"

    static func read(service: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func save(_ value: String, service: String) -> Bool {
        delete(service: service)
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrLabel as String: service,
            kSecValueData as String: Data(value.utf8),
        ]
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    static func delete(service: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}

/// De API-sleutels van de app: in de Keychain, of anders een omgevingsvariabele.
enum APIKey: String, CaseIterable, Identifiable, Sendable {
    case mistral, anthropic

    var id: String { rawValue }
    var service: String { "dj-agenda-\(rawValue)" }
    var environmentName: String { rawValue == "mistral" ? "MISTRAL_API_KEY" : "ANTHROPIC_API_KEY" }

    var label: String {
        switch self {
        case .mistral: "Mistral"
        case .anthropic: "Anthropic (Claude)"
        }
    }

    var consoleURL: URL {
        switch self {
        case .mistral: URL(string: "https://console.mistral.ai/api-keys")!
        case .anthropic: URL(string: "https://console.anthropic.com/settings/keys")!
        }
    }

    var stored: String? { Keychain.read(service: service).flatMap { $0.isEmpty ? nil : $0 } }

    var value: String? {
        if let stored { return stored }
        let env = ProcessInfo.processInfo.environment[environmentName] ?? ""
        return env.isEmpty ? nil : env
    }

    /// Klopt de sleutel? Vraagt de lijst met modellen op (kost niets).
    func check(_ key: String) async -> Result<Void, Error> {
        var request: URLRequest
        switch self {
        case .mistral:
            request = URLRequest(url: URL(string: "https://api.mistral.ai/v1/models")!)
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        case .anthropic:
            request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/models")!)
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        }
        request.timeoutInterval = 10
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 200 { return .success(()) }
            let detail = status == 401 ? "sleutel ongeldig" : "HTTP \(status): \(String(decoding: data.prefix(160), as: UTF8.self))"
            return .failure(URLError(.userAuthenticationRequired, userInfo: [NSLocalizedDescriptionKey: detail]))
        } catch {
            return .failure(error)
        }
    }
}
