import XCTest
@testable import YoyoServer

/// `/status`'s identity fields (docs/LOCAL-API.md): clients attach only to `app == "YoyoControl"`.
final class IdentityTests: XCTestCase {
    func testStatusCarriesAppVersionAndApi() {
        let j = ServerIdentity.json
        XCTAssertEqual(j["app"] as? String, "YoyoControl")
        XCTAssertEqual(j["api"] as? Int, 1)
        XCTAssertFalse((j["version"] as? String ?? "").isEmpty)
    }
}
