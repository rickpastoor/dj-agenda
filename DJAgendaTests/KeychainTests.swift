import XCTest
@testable import DJAgenda

final class KeychainTests: XCTestCase {
    let service = "dj-agenda-test-\(UUID().uuidString)"

    override func tearDown() {
        Keychain.delete(service: service)
    }

    func testSaveReadReplaceDelete() {
        XCTAssertNil(Keychain.read(service: service))
        XCTAssertTrue(Keychain.save("eerste", service: service))
        XCTAssertEqual(Keychain.read(service: service), "eerste")
        XCTAssertTrue(Keychain.save("tweede", service: service))   // vervangen, geen dubbel item
        XCTAssertEqual(Keychain.read(service: service), "tweede")
        XCTAssertTrue(Keychain.delete(service: service))
        XCTAssertNil(Keychain.read(service: service))
        XCTAssertTrue(Keychain.delete(service: service))           // nog eens verwijderen mag
    }

    func testServiceNames() {
        XCTAssertEqual(APIKey.mistral.service, "dj-agenda-mistral")
        XCTAssertEqual(APIKey.anthropic.service, "dj-agenda-anthropic")
    }
}
