import Foundation
import Testing
@testable import YoyoClipboard
@testable import YoyoCore
@testable import YoyoDirect
@testable import YoyoScreen

/// The display menu's words (`ScreenDisplayMenuText`): each display's name and size in pixels.
/// Unit tests run in English.
@Suite("Screen display menu")
struct ScreenDisplayMenuTests {
    private func display(_ w: Double, _ h: Double, scale: Double = 1, main: Bool = false,
                         name: String? = nil, kind: ScreenDisplayKind? = nil) -> ScreenDisplay {
        ScreenDisplay(id: 1, width: w, height: h, scale: scale, main: main, name: name, kind: kind)
    }

    // MARK: Title

    @Test func theMacsOwnNameWins() {
        let d = display(1728, 1117, scale: 2, main: true, name: "Built-in Retina Display", kind: .builtin)
        #expect(ScreenDisplayMenuText.title(d, index: 0) == "Built-in Retina Display")
    }

    @Test func withoutANameTheKindNamesIt() {
        #expect(ScreenDisplayMenuText.title(display(1728, 1117, main: true, kind: .builtin), index: 0) == "Built-in display")
        #expect(ScreenDisplayMenuText.title(display(1920, 1080, kind: .external), index: 1) == "External display")
    }

    @Test func anOlderServerFallsBackToMainAndANumber() {
        #expect(ScreenDisplayMenuText.title(display(1512, 982, scale: 2, main: true), index: 0) == "Main display")
        #expect(ScreenDisplayMenuText.title(display(1920, 1080), index: 1) == "Display 2")
    }

    // MARK: Subtitle

    @Test func sizesArePixelsWithTheScaleAndTheMainTag() {
        #expect(ScreenDisplayMenuText.subtitle(display(1728, 1117, scale: 2, main: true)) == "3456 × 2234 @2x · Main")
        #expect(ScreenDisplayMenuText.subtitle(display(1728, 1117, scale: 2)) == "3456 × 2234 @2x")
        #expect(ScreenDisplayMenuText.subtitle(display(3456, 2234)) == "3456 × 2234")
        #expect(ScreenDisplayMenuText.subtitle(display(1920, 1080, main: true)) == "1920 × 1080 · Main")
        #expect(ScreenDisplayMenuText.subtitle(display(1280, 720, scale: 3)) == "3840 × 2160 @3x")
    }

    @Test func aFractionalScaleRoundsThePixelsAndHasNoTag() {
        #expect(ScreenDisplayMenuText.subtitle(display(1000.4, 600.6, scale: 1.5)) == "1501 × 901")
    }

    @Test func badValuesDoNotTrap() {
        #expect(ScreenDisplayMenuText.subtitle(display(.infinity, .nan, scale: 2)) == "? × ? @2x")
        #expect(ScreenDisplayMenuText.subtitle(display(1e12, 10, scale: 1)) == "? × 10")
        #expect(ScreenDisplayMenuText.subtitle(display(100, 100, scale: .infinity)) == "? × ?")
    }
}
