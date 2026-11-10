import XCTest
@testable import YoyoServer

/// `/status` display entries: the name / kind fields (DisplayInfo.json, DisplayNames.clean).
final class DisplayInfoTests: XCTestCase {
    func testNamesAreTrimmedAndMeaninglessOnesDropped() {
        XCTAssertEqual(DisplayNames.clean("Built-in Retina Display"), "Built-in Retina Display")
        XCTAssertEqual(DisplayNames.clean("  LG UltraFine \n"), "LG UltraFine")
        XCTAssertEqual(DisplayNames.clean("Living Room (AirPlay)"), "Living Room (AirPlay)")
        XCTAssertNil(DisplayNames.clean(""))
        XCTAssertNil(DisplayNames.clean("   "))
        XCTAssertNil(DisplayNames.clean(" (AirPlay)"))  // an empty product name plus the transport
    }

    func testJSONCarriesKindAndNameOnlyWhenPresent() {
        let named = DisplayInfo(id: 1, width: 1728, height: 1117, scale: 2, main: true, asleep: false,
                                name: "Built-in Retina Display", kind: "builtin")
        XCTAssertEqual(named.json["name"] as? String, "Built-in Retina Display")
        XCTAssertEqual(named.json["kind"] as? String, "builtin")
        XCTAssertNil(named.json["label"])

        let plain = DisplayInfo(id: 2, width: 2560, height: 1440, scale: 1, main: false, asleep: false)
        XCTAssertNil(plain.json["name"])
        XCTAssertEqual(plain.json["kind"] as? String, "external")
        XCTAssertNil(plain.json["label"], "no display has a label any more")
    }
}
