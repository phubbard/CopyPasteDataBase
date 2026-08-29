#if os(macOS)
import Testing
import Foundation
import AppKit
import GRDB
@testable import CpdbApp
@testable import CpdbShared

/// Regression coverage for the v3.3.1 "double-click silently drops the
/// paste" incident: `EntryStripView`'s double-click gesture resolved
/// what to paste through `state.selectedIndex` instead of the card that
/// was actually clicked, so a click landing ahead of the selection
/// highlight catching up (or a failed gesture arbitration against a
/// descendant chip) could paste the wrong entry, or — combined with the
/// arbitration failure — nothing at all.
///
/// `PopupController.paste(entryId:)` is the fix: it takes the clicked
/// entry's id directly and must write THAT entry regardless of what
/// `selectedIndex` currently holds. This suite proves that contract at
/// the `PopupController` seam without needing to drive SwiftUI's actual
/// gesture recognizer (not headlessly testable — see the task notes).
///
/// Shares `PopupController.shared` with `PopupControllerIntentPlumbingTests`
/// (`AppIntentsTests.swift`) — both suites reconfigure and drive that
/// singleton. `.serialized` below only orders the tests *within* this
/// suite; Swift Testing gives no way to serialize two independently
/// declared `@Suite` types against each other, so the two suites' tests
/// can and do run concurrently with each other (verified: their console
/// output interleaves). That's safe today only because every test body
/// in both suites is `@MainActor` and fully synchronous with no internal
/// `await` — MainActor's serial executor means only one test's body
/// actually executes at a time, so a mutate-then-assert sequence always
/// completes as one uninterrupted unit even though the two suites were
/// scheduled in parallel. That safety is incidental to the current test
/// bodies, not a guarantee: if a future test in either suite adds an
/// `await` between mutating and reading `PopupController.shared`'s
/// state, the two suites' tests could genuinely interleave mid-body.
/// Don't add such an `await` without first giving the two suites real
/// mutual exclusion (e.g. nesting them under one `@Suite(.serialized)`
/// parent, which Swift Testing does serialize transitively).
@Suite("PopupController — paste(entryId:) routing", .serialized)
@MainActor
struct PopupPasteRoutingTests {

    /// Inserts two distinguishable text entries and returns their ids in
    /// insertion order. `paste(entryId:)`'s whole job is choosing between
    /// these correctly.
    private func makeStoreWithTwoEntries() throws -> (store: Store, firstId: Int64, secondId: Int64) {
        let store = try Store.inMemory()
        let devId = try store.dbQueue.write { db -> Int64 in
            var d = Device(identifier: "d", name: "D", kind: "mac")
            try d.insert(db)
            return d.id!
        }
        func insert(byte: UInt8, text: String, createdAt: Double) throws -> Int64 {
            try store.dbQueue.write { db in
                var e = Entry(
                    uuid: Data(repeating: byte, count: 16), createdAt: createdAt, capturedAt: createdAt,
                    kind: .text, sourceDeviceId: devId, textPreview: text,
                    contentHash: Data(repeating: byte, count: 32), totalSize: Int64(text.utf8.count)
                )
                try e.insert(db)
                var f = Flavor(
                    entryId: e.id!, uti: "public.utf8-plain-text",
                    size: Int64(text.utf8.count), data: Data(text.utf8), blobKey: nil
                )
                try f.insert(db)
                return e.id!
            }
        }
        // Ascending createdAt: `firstId` is older (would sit at a later
        // popup row / lower selectedIndex priority), `secondId` newer.
        let firstId = try insert(byte: 1, text: "first entry", createdAt: 1_700_000_000)
        let secondId = try insert(byte: 2, text: "second entry", createdAt: 1_700_000_001)
        return (store, firstId, secondId)
    }

    /// A pasteboard scoped to this test process, never `.general` — so
    /// this suite can assert on written content without touching the
    /// developer's or CI runner's actual system clipboard.
    private func scratchPasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("net.phfactor.cpdb.tests.paste-routing"))
    }

    /// Index of `entryId` within the live popup rows — looked up rather
    /// than assumed, so this test doesn't depend on which sort order
    /// `PopupState` happens to use.
    private func rowIndex(of entryId: Int64) -> Int? {
        PopupController.shared.state?.rows.firstIndex { $0.entry.id == entryId }
    }

    @Test("paste(entryId:) writes the requested entry even when selectedIndex points at a different row")
    func pasteEntryIgnoresStaleSelection() throws {
        let (store, firstId, secondId) = try makeStoreWithTwoEntries()
        PopupController.shared.configure(store: store, captureMode: .capturing)
        // configure() alone leaves `state.rows` empty — show() is what
        // runs PopupState.refresh() and actually populates the popup's
        // row list, same as a real hotkey summon.
        PopupController.shared.show()
        defer { PopupController.shared.hide() }

        // Selection deliberately parked on `firstId`'s row while we ask
        // to paste `secondId` — the mouse-gesture scenario where the
        // clicked card and the (possibly stale) selection disagree.
        guard let firstIndex = rowIndex(of: firstId) else {
            Issue.record("firstId not found in popup rows")
            return
        }
        PopupController.shared.state?.selectedIndex = firstIndex
        #expect(PopupController.shared.state?.selectedEntry?.id == firstId)

        let pasteboard = scratchPasteboard()
        pasteboard.clearContents()
        // performsSystemPasteEffects: false — this suite only proves
        // entry-id routing into the pasteboard write. Leaving system
        // paste effects on would call `.activate()` on whatever app is
        // actually frontmost on the machine running this test, and —
        // on a machine where the test binary already holds Accessibility
        // trust — synthesize a real, unrelated system-wide ⌘V. See
        // `PasteAction.performsSystemPasteEffects`.
        PopupController.shared.paste(entryId: secondId, pasteboard: pasteboard, performsSystemPasteEffects: false)

        // If this ever regresses back to resolving through
        // selectedIndex, this reads back "first entry" instead.
        #expect(pasteboard.string(forType: .init("public.utf8-plain-text")) == "second entry")
    }

    @Test("paste(entryId:) is not hardcoded to one id — the other entry with the other selection also routes correctly")
    func pasteEntryWritesWhicheverIdIsPassed() throws {
        let (store, firstId, secondId) = try makeStoreWithTwoEntries()
        PopupController.shared.configure(store: store, captureMode: .capturing)
        // configure() alone leaves `state.rows` empty — show() is what
        // runs PopupState.refresh() and actually populates the popup's
        // row list, same as a real hotkey summon.
        PopupController.shared.show()
        defer { PopupController.shared.hide() }

        // Mirror image of the case above: selection now parked on
        // `secondId`'s row, pasting `firstId`.
        guard let secondIndex = rowIndex(of: secondId) else {
            Issue.record("secondId not found in popup rows")
            return
        }
        PopupController.shared.state?.selectedIndex = secondIndex
        #expect(PopupController.shared.state?.selectedEntry?.id == secondId)

        let pasteboard = scratchPasteboard()
        pasteboard.clearContents()
        // See the sibling test above for why performsSystemPasteEffects
        // must stay false in this suite.
        PopupController.shared.paste(entryId: firstId, pasteboard: pasteboard, performsSystemPasteEffects: false)

        #expect(pasteboard.string(forType: .init("public.utf8-plain-text")) == "first entry")
    }
}
#endif
