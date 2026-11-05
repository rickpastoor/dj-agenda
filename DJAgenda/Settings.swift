import Foundation

/// Instellingen in UserDefaults.
@MainActor
struct Settings {
    private let d = UserDefaults.standard

    var enabled: Bool {
        get { d.object(forKey: "enabled") as? Bool ?? true }
        nonmutating set { d.set(newValue, forKey: "enabled") }
    }

    var skipKeywords: [String] {
        get { d.stringArray(forKey: "skipKeywords") ?? ["focus", "lunch"] }
        nonmutating set { d.set(newValue, forKey: "skipKeywords") }
    }

    var lookaheadHours: Double {
        get { d.object(forKey: "lookaheadHours") as? Double ?? 4 }
        nonmutating set { d.set(newValue, forKey: "lookaheadHours") }
    }

    /// Vanaf hoeveel minuten voor de afspraak de DJ de nummers aan elkaar praat.
    var runUpMinutes: Double {
        get { d.object(forKey: "runUpMinutes") as? Double ?? 12 }
        nonmutating set { d.set(newValue, forKey: "runUpMinutes") }
    }

    /// Begint de afspraak binnen zoveel seconden na het nummer, dan geen nieuw nummer meer.
    var finalCutoffSeconds: Double {
        get { d.object(forKey: "finalCutoffSeconds") as? Double ?? 120 }
        nonmutating set { d.set(newValue, forKey: "finalCutoffSeconds") }
    }

    var radioConfig: RadioConfig {
        var c = RadioConfig()
        c.runUp = runUpMinutes * 60
        c.finalCutoff = finalCutoffSeconds
        return c
    }

    /// "nl" of "en": de taal van de DJ.
    var language: String {
        get { d.string(forKey: "language") ?? "nl" }
        nonmutating set { d.set(newValue, forKey: "language") }
    }

    /// "mistral", "claude", "apple" of "fixed".
    var textEngine: String {
        get { d.string(forKey: "textEngine") ?? "mistral" }
        nonmutating set { d.set(newValue, forKey: "textEngine") }
    }

    /// Spotify-volume terwijl de DJ over de muziek heen praat (Mac).
    var duckVolume: Int {
        get { d.object(forKey: "duckVolume") as? Int ?? 25 }
        nonmutating set { d.set(newValue, forKey: "duckVolume") }
    }

    /// "cloud_male", "cloud_female", "local_male", "local_female" (Voxtral) of "system".
    var voice: String {
        get { d.string(forKey: "voice") ?? "cloud_male" }
        nonmutating set { d.set(newValue, forKey: "voice") }
    }

    /// "auto", "mac" of "sonos".
    var outputMode: String {
        get { d.string(forKey: "outputMode") ?? "auto" }
        nonmutating set { d.set(newValue, forKey: "outputMode") }
    }

    /// Vast IP als terugval (als Bonjour de speaker niet vindt).
    var sonosHost: String {
        get { d.string(forKey: "sonosHost") ?? "" }
        nonmutating set { d.set(newValue, forKey: "sonosHost") }
    }

    /// Hoeveel stappen de DJ-clip op de Sonos harder (of zachter) is dan de muziek op die speaker.
    var clipBoost: Int {
        get { d.object(forKey: "clipBoost") as? Int ?? SonosOutput.defaultClipBoost }
        nonmutating set { d.set(newValue, forKey: "clipBoost") }
    }

    /// Gekozen agenda's; `nil` (nog nooit gekozen) betekent alle agenda's.
    var calendars: [CalendarRef]? {
        get {
            guard let data = d.data(forKey: "calendars") else { return nil }
            return try? JSONDecoder().decode([CalendarRef].self, from: data)
        }
        nonmutating set { d.set(newValue.flatMap { try? JSONEncoder().encode($0) }, forKey: "calendars") }
    }

    /// Hoe de DJ je noemt; standaard je voornaam uit macOS. Het station heet "Radio <naam>".
    var listenerName: String {
        get {
            if let s = d.string(forKey: "listenerName"), !s.isEmpty { return s }
            return NSFullUserName().split(separator: " ").first.map(String.init) ?? "luisteraar"
        }
        nonmutating set { d.set(newValue, forKey: "listenerName") }
    }
}
