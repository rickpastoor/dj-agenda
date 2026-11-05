import XCTest
@testable import DJAgenda

final class PlayerStateTests: XCTestCase {
    func testParsesDutchLocaleAndMilliseconds() {
        let d = "\u{1F}"
        let out = ["playing", "155,561996459961", "215000", "Titel", "Artiest", "73", "spotify:track:abc"]
            .joined(separator: d)
        let st = PlayerState.parseSpotify(out)
        XCTAssertEqual(st.status, .playing)
        XCTAssertEqual(st.position, 155.562, accuracy: 0.001)
        XCTAssertEqual(st.duration, 215)
        XCTAssertEqual(st.remaining, 59.438, accuracy: 0.001)
        XCTAssertEqual(st.volume, 73)
        XCTAssertEqual(st.trackID, "spotify:track:abc")
        XCTAssertEqual(st.title, "Titel")
    }

    func testSimpleStates() {
        XCTAssertEqual(PlayerState.parseSpotify("stopped").status, .stopped)
        XCTAssertEqual(PlayerState.parseSpotify("not_running").status, .notRunning)
        XCTAssertEqual(PlayerState.parseSpotify("").status, .notRunning)
    }

    func testUnknownDurationMeansInfiniteRemaining() {
        XCTAssertEqual(PlayerState(status: .playing, position: 10, duration: 0).remaining, .infinity)
    }
}
