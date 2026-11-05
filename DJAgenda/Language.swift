import Foundation

/// De taal van de DJ: tekst, vaste zinnen en stem.
enum Language: String, CaseIterable, Identifiable, Sendable {
    case nl, en

    var id: String { rawValue }
    var label: String { self == .nl ? "Dutch" : "English" }
    /// Voor in de prompt ("Write in Dutch").
    var englishName: String { self == .nl ? "Dutch" : "English" }

    func minutes(_ m: Int) -> String { self == .nl ? DutchSpeech.minutes(m) : EnglishSpeech.minutes(m) }
    func clock(_ d: Date) -> String { self == .nl ? DutchSpeech.clock(d) : EnglishSpeech.clock(d) }
    var numberWords: Set<String> { self == .nl ? DutchSpeech.numberWords : EnglishSpeech.numberWords }

    /// "a, b en c" / "a, b and c".
    func list(_ items: [String]) -> String {
        guard items.count > 1 else { return items.first ?? "" }
        return items.dropLast().joined(separator: ", ") + (self == .nl ? " en " : " and ") + items.last!
    }
}

/// Getallen en tijden zoals je ze in het Engels uitspreekt ("at quarter past three", "in twelve minutes").
enum EnglishSpeech {
    private static let units = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight",
                                "nine", "ten", "eleven", "twelve", "thirteen", "fourteen", "fifteen",
                                "sixteen", "seventeen", "eighteen", "nineteen"]
    private static let tens = ["", "", "twenty", "thirty", "forty", "fifty", "sixty",
                               "seventy", "eighty", "ninety"]

    static func number(_ n: Int) -> String {
        guard n >= 0, n < 100 else { return String(n) }
        if n < 20 { return units[n] }
        let (t, u) = (n / 10, n % 10)
        return u == 0 ? tens[t] : "\(tens[t])-\(units[u])"
    }

    static func minutes(_ m: Int) -> String {
        m == 1 ? "one minute" : "\(number(m)) minutes"
    }

    /// "three o'clock", "quarter past three", "twenty to four", "three thirty-three", "three oh seven".
    static func clock(_ date: Date, calendar: Calendar = .current) -> String {
        let rounded = Date(timeIntervalSinceReferenceDate:
            (date.timeIntervalSinceReferenceDate / 60).rounded() * 60)
        let c = calendar.dateComponents([.hour, .minute], from: rounded)
        let h = c.hour ?? 0, m = c.minute ?? 0
        func hour(_ x: Int) -> String { number(x % 12 == 0 ? 12 : x % 12) }
        let now = hour(h), next = hour(h + 1)
        switch m {
        case 0: return "\(now) o'clock"
        case 15: return "quarter past \(now)"
        case 30: return "half past \(now)"
        case 45: return "quarter to \(next)"
        case let m where m % 5 == 0 && m < 30: return "\(number(m)) past \(now)"
        case let m where m % 5 == 0: return "\(number(60 - m)) to \(next)"
        case 1..<10: return "\(now) oh \(number(m))"
        default: return "\(now) \(number(m))"
        }
    }

    /// Losse getalwoorden van twee tot en met zestig ("twenty-two" telt als "twenty" en "two").
    static let numberWords: Set<String> = Set((2...60).flatMap { number($0).split(separator: "-").map(String.init) })
}
