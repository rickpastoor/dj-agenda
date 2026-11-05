import XCTest
@testable import DJAgenda

final class EnglishTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_793_800_000)

    func request(minutes: Double, travel: Int = 0) -> DJRequest {
        var ev = AgendaEvent(key: "k", title: "Weekly", start: t0.addingTimeInterval(minutes * 60 + Double(travel) * 60))
        ev.travelMinutes = travel
        ev.attendees = ["Sarah Miller"]
        return DJRequest(kind: .transition, events: [ev], at: t0,
                         previous: TrackInfo(id: "x", title: "Wake Me Up", artist: "Avicii"))
    }

    func testClockAndNumbers() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Amsterdam")!
        func t(_ h: Int, _ m: Int) -> Date {
            cal.date(from: DateComponents(year: 2026, month: 11, day: 4, hour: h, minute: m))!
        }
        XCTAssertEqual(EnglishSpeech.clock(t(15, 0), calendar: cal), "three o'clock")
        XCTAssertEqual(EnglishSpeech.clock(t(14, 15), calendar: cal), "quarter past two")
        XCTAssertEqual(EnglishSpeech.clock(t(14, 30), calendar: cal), "half past two")
        XCTAssertEqual(EnglishSpeech.clock(t(14, 45), calendar: cal), "quarter to three")
        XCTAssertEqual(EnglishSpeech.clock(t(14, 20), calendar: cal), "twenty past two")
        XCTAssertEqual(EnglishSpeech.clock(t(14, 40), calendar: cal), "twenty to three")
        XCTAssertEqual(EnglishSpeech.clock(t(8, 33), calendar: cal), "eight thirty-three")
        XCTAssertEqual(EnglishSpeech.clock(t(9, 7), calendar: cal), "nine oh seven")
        XCTAssertEqual(EnglishSpeech.clock(t(23, 50), calendar: cal), "ten to twelve")
        XCTAssertEqual(EnglishSpeech.minutes(1), "one minute")
        XCTAssertEqual(EnglishSpeech.minutes(22), "twenty-two minutes")
        XCTAssertTrue(EnglishSpeech.numberWords.isSuperset(of: ["twenty", "two", "eleven"]))
    }

    func testFallbackAndFinal() {
        let text = DJText.fallback(request(minutes: 12), lang: .en)
        XCTAssertTrue(text.hasPrefix("That was Wake Me Up by Avicii. In twelve minutes, Weekly, with Sarah Miller, at "), text)
        XCTAssertTrue(DJText.phrases(.en).closingsRelaxed.contains { text.hasSuffix($0) }, text)
        let leave = DJText.fallback(request(minutes: 8, travel: 20), lang: .en)
        XCTAssertTrue(leave.contains("In eight minutes you need to leave for Weekly."), leave)
        var final = request(minutes: 0)
        final.kind = .final
        XCTAssertTrue(DJText.phrases(.en).finalMeeting.map { String(format: $0, "Weekly") }
            .contains(DJText.finalText(final, lang: .en)))
    }

    func testPayloadHasNoDigitsAndSpokenTimes() {
        let payload = DJText.llmPayload(request(minutes: 7), lang: .en)
        XCTAssertTrue(payload.contains("\"in\":\"seven minutes\""), payload)
        XCTAssertNil(payload.rangeOfCharacter(from: .decimalDigits), payload)
        XCTAssertTrue(DJText.llmSystem(.en, listener: "Sam").contains("Write in English"))
        XCTAssertTrue(DJText.llmSystem(.nl, listener: "Sam").contains("Write in Dutch"))
        XCTAssertTrue(DJText.llmSystem(.nl, listener: "Sam").contains("Radio Sam"))
    }

    func testPlausibleInEnglish() {
        let req = request(minutes: 7)
        let payload = DJText.llmPayload(req, lang: .en)
        XCTAssertTrue(DJText.isPlausible("Wake Me Up, and wake up you should: Weekly with Sarah in seven minutes.",
                                         prompt: payload, request: req, lang: .en))
        XCTAssertFalse(DJText.isPlausible("Weekly with Sarah in eleven minutes.", prompt: payload, request: req, lang: .en))
        XCTAssertFalse(DJText.isPlausible("Weekly in 7 minutes.", prompt: payload, request: req, lang: .en))
        XCTAssertFalse(DJText.isPlausible("Weekly in half an hour, relax.", prompt: payload, request: req, lang: .en))
    }

    func testCleanRemovesMarkdown() {
        XCTAssertEqual(DJText.clean("*Dreams* by Fleetwood Mac.\n\nIn four minutes..."),
                       "Dreams by Fleetwood Mac. In four minutes...")
    }

    func testOldVoiceSettingStillWorks() {
        XCTAssertEqual(DJVoice.Choice(stored: "nl_male"), .localMale)
        XCTAssertEqual(DJVoice.Choice(stored: "cloud_female"), .cloudFemale)
        XCTAssertEqual(VoxtralVoice.voice(.en, female: false), "casual_male")
    }

    func testLoudnessGain() {
        // Zacht fragment (-36 dBFS, piek -20): 16 dB erbij.
        let g = Loudness.gain(rms: pow(10, -36 / 20), peak: pow(10, -20 / 20))
        XCTAssertEqual(20 * log10(g), 16, accuracy: 0.1)
        // De piek mag niet boven -1 dBFS: dan minder versterken.
        let capped = Loudness.gain(rms: pow(10, -30 / 20), peak: pow(10, -3 / 20))
        XCTAssertEqual(20 * log10(capped), 2, accuracy: 0.1)
        // Bijna stilte: niet eindeloos opblazen.
        XCTAssertLessThanOrEqual(Loudness.gain(rms: 1e-6, peak: 1e-5), 30)
    }
}
