import XCTest
@testable import DJAgenda

final class EventFilterTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    let skip = ["focus", "lunch"]

    func raw(_ title: String = "Overleg", inMinutes m: Double = 30) -> RawEvent {
        RawEvent(identifier: "id", title: title, start: t0.addingTimeInterval(m * 60))
    }

    func testNormalEventPasses() {
        let ev = EventFilter.event(from: raw(), skipKeywords: skip)
        XCTAssertEqual(ev?.title, "Overleg")
        XCTAssertEqual(ev?.kind, "afspraak")
    }

    func testAllDayCanceledDeclinedAreSkipped() {
        var r = raw(); r.isAllDay = true
        XCTAssertNil(EventFilter.event(from: r, skipKeywords: skip))
        r = raw(); r.isCanceled = true
        XCTAssertNil(EventFilter.event(from: r, skipKeywords: skip))
        r = raw(); r.declinedByMe = true
        XCTAssertNil(EventFilter.event(from: r, skipKeywords: skip))
    }

    func testSkipKeywordsCaseInsensitive() {
        XCTAssertNil(EventFilter.event(from: raw("Focus time"), skipKeywords: skip))
        XCTAssertNil(EventFilter.event(from: raw("LUNCH met Anne"), skipKeywords: skip))
    }

    func testTravelFromNotes() {
        XCTAssertEqual(EventFilter.travelMinutes(fromNotes: "Perron 5\nreistijd: 12"), 12)
        XCTAssertEqual(EventFilter.travelMinutes(fromNotes: "  Vertrek = 7"), 7)
        XCTAssertEqual(EventFilter.travelMinutes(fromNotes: "TRAVEL:20"), 20)
        XCTAssertEqual(EventFilter.travelMinutes(fromNotes: "geen reistijd: hier"), 0)
        var r = raw("Trein naar Utrecht"); r.notes = "reistijd: 12"
        let ev = EventFilter.event(from: r, skipKeywords: skip)!
        XCTAssertEqual(ev.kind, "vertrek")
        XCTAssertEqual(ev.alertTime, ev.start.addingTimeInterval(-12 * 60))
    }

    func testAppleTravelTimeWinsOverNotes() {
        var r = raw(); r.travelSeconds = 900; r.notes = "reistijd: 3"
        XCTAssertEqual(EventFilter.event(from: r, skipKeywords: skip)?.travelMinutes, 15)
    }

    func testNotesSummaryAndAttendees() {
        var r = raw("Roadmap")
        r.notes = "Prioriteiten doornemen.\nreistijd: 10\nInbellen: https://meet.google.com/abc-def\n<b>Graag</b> cijfers meenemen."
        r.attendees = ["Sanne de Vries", "joris@example.com", " ", "Mark", "Eva", "Tom", "Noor"]
        let ev = EventFilter.event(from: r, skipKeywords: skip)!
        XCTAssertEqual(ev.notes, "Prioriteiten doornemen. Inbellen: Graag cijfers meenemen.")
        XCTAssertEqual(ev.attendees, ["Sanne de Vries", "Mark", "Eva", "Tom"], "Geen e-mailadressen, hoogstens vier")
        XCTAssertEqual(ev.travelMinutes, 10)
        let long = EventFilter.summary(ofNotes: String(repeating: "woord ", count: 100))
        XCTAssertLessThanOrEqual(long.count, 201)
        XCTAssertTrue(long.hasSuffix("…"))
    }

    func testCalendarRefMatchesTitleAndSource() {
        let ref = CalendarRef(title: "Calendar", source: "Work")
        XCTAssertTrue(ref.matches(title: "calendar", source: " Work "))
        XCTAssertFalse(ref.matches(title: "Calendar", source: "me@example.com"))
        XCTAssertFalse(ref.matches(title: "Huisplanning", source: "Work"))
    }
}
