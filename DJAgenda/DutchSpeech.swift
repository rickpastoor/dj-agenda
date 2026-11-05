import Foundation

/// Getallen en tijden zoals je ze uitspreekt ("om kwart over drie", "over twaalf minuten").
enum DutchSpeech {
    private static let units = ["nul", "een", "twee", "drie", "vier", "vijf", "zes", "zeven", "acht",
                                "negen", "tien", "elf", "twaalf", "dertien", "veertien", "vijftien",
                                "zestien", "zeventien", "achttien", "negentien"]
    private static let tens = ["", "", "twintig", "dertig", "veertig", "vijftig", "zestig",
                               "zeventig", "tachtig", "negentig"]

    static func number(_ n: Int) -> String {
        guard n >= 0, n < 100 else { return String(n) }
        if n < 20 { return units[n] }
        let (t, u) = (n / 10, n % 10)
        if u == 0 { return tens[t] }
        let unit = units[u]
        return unit + (unit.hasSuffix("e") ? "ën" : "en") + tens[t]   // tweeëntwintig, vierentwintig
    }

    /// "een minuut", "een kwartier", "twaalf minuten".
    static func minutes(_ m: Int) -> String {
        switch m {
        case 1: "een minuut"
        case 15: "een kwartier"
        default: "\(number(m)) minuten"
        }
    }

    /// Kloktijd zoals op de radio: "drie uur", "kwart over drie", "tien voor half vier".
    static func clock(_ date: Date, calendar: Calendar = .current) -> String {
        let rounded = Date(timeIntervalSinceReferenceDate:
            (date.timeIntervalSinceReferenceDate / 60).rounded() * 60)
        let c = calendar.dateComponents([.hour, .minute], from: rounded)
        let h = c.hour ?? 0, m = c.minute ?? 0
        func hour(_ x: Int) -> String { number(x % 12 == 0 ? 12 : x % 12) }
        let now = hour(h), next = hour(h + 1)
        switch m {
        case 0: return "\(now) uur"
        case 15: return "kwart over \(now)"
        case 30: return "half \(next)"
        case 45: return "kwart voor \(next)"
        case 1..<15: return "\(number(m)) over \(now)"
        case 16..<30: return "\(number(30 - m)) voor half \(next)"
        case 31..<45: return "\(number(m - 30)) over half \(next)"
        default: return "\(number(60 - m)) voor \(next)"
        }
    }

    /// Alle getalwoorden van twee tot en met zestig (voor de controle van modeltekst).
    static let numberWords: Set<String> = Set((2...60).map(number))
}
