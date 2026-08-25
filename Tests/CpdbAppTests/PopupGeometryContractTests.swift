#if os(macOS)
import Testing
@testable import CpdbApp

/// Regression guard for the v3.2.2–v3.2.5 popup layout chain.
///
/// `PopupController.panelHeight` is a bare `CGFloat` constant — nothing
/// enforces that it actually has room for a card. v3.2.3 pinned the
/// hosting view's window sizing (`hosting.sizingOptions = []`), which
/// turned the old (fictional) 420pt height into a real constraint: the
/// horizontal ScrollView vertically centered its too-tall content and
/// clipped ~29pt off the top and bottom of every card. This test asserts
/// the height contract both ways so neither a future squeeze nor a
/// runaway balloon can land unnoticed.
@Suite("PopupController panel-height geometry contract")
struct PopupGeometryContractTests {

    @Test("panelHeight has room for a card plus strip padding")
    @MainActor
    func panelHeightHasMinimumRoom() {
        let requiredMinimum = EntryCard.cardSize.height
            + 2 * EntryStripView.verticalPadding
            + 60 // search field + kind chips + divider can never fit under 60pt
        #expect(PopupController.panelHeight >= requiredMinimum)
    }

    @Test("panelHeight doesn't silently balloon past the card + chrome")
    @MainActor
    func panelHeightHasUpperBound() {
        let upperBound = EntryCard.cardSize.height
            + 2 * EntryStripView.verticalPadding
            + 160
        #expect(PopupController.panelHeight <= upperBound)
    }
}
#endif
