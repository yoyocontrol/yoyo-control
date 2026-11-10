import XCTest
@testable import YoyoServer

/// What counts as a focused element that takes typing (FocusProbe.isEditable): the phone brings up its keyboard for it.
final class FocusTests: XCTestCase {
    private func editable(_ role: String?, subrole: String? = nil, enabled: Bool? = nil, settable: Bool = false, selection: Bool = false) -> Bool {
        FocusProbe.isEditable(role: role, subrole: subrole, enabled: enabled, valueSettable: settable, hasSelectedRange: selection)
    }

    func testTextRolesTakeTyping() {
        XCTAssertTrue(editable("AXTextField"))
        XCTAssertTrue(editable("AXTextArea"))  // also a terminal, an editor, a web contenteditable
        XCTAssertTrue(editable("AXComboBox"))
        XCTAssertTrue(editable("AXTextField", subrole: "AXSecureTextField"))
        XCTAssertTrue(editable(nil, subrole: "AXSearchField"))
    }

    func testDisabledFieldsDoNot() {
        XCTAssertFalse(editable("AXTextField", enabled: false))
        XCTAssertFalse(editable("AXGroup", enabled: false, settable: true, selection: true))
    }

    func testOtherRolesNeedASettableValueAndACaret() {
        XCTAssertTrue(editable("AXGroup", settable: true, selection: true))
        XCTAssertFalse(editable("AXGroup", settable: true))
        XCTAssertFalse(editable("AXStaticText", selection: true))  // selectable text on a web page
        XCTAssertFalse(editable("AXButton"))
        XCTAssertFalse(editable("AXWebArea", selection: true))
        XCTAssertFalse(editable(nil))
    }

    func testChromiumBrowsersAreKnownByBundleID() {
        XCTAssertTrue(FocusProbe.isChromiumBrowser("com.google.Chrome"))
        XCTAssertTrue(FocusProbe.isChromiumBrowser("com.google.Chrome.canary"))
        XCTAssertTrue(FocusProbe.isChromiumBrowser("com.microsoft.edgemac.Beta"))
        XCTAssertTrue(FocusProbe.isChromiumBrowser("company.thebrowser.Browser"))
        XCTAssertFalse(FocusProbe.isChromiumBrowser("com.apple.Safari"))
        XCTAssertFalse(FocusProbe.isChromiumBrowser("com.google.ChromeRemoteDesktop"))
        XCTAssertFalse(FocusProbe.isChromiumBrowser("com.apple.Terminal"))
    }

    func testAnswerJSON() {
        let none = FocusProbe.Answer(editable: false, role: nil).json
        XCTAssertEqual(none["editable"] as? Bool, false)
        XCTAssertTrue(none["role"] is NSNull)
        XCTAssertEqual(FocusProbe.Answer(editable: true, role: "AXTextArea").json["role"] as? String, "AXTextArea")
    }
}
