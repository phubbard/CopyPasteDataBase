#if os(macOS)
import Testing
import Foundation
import AppKit
import SwiftUI
import GRDB
@testable import CpdbApp
@testable import CpdbShared

/// Parent suite whose only job is to serialize its children against each
/// other (Swift Testing serializes `.serialized` suites transitively). Both
/// drive real AppKit state — `Routing` shows and hides the shared popup
/// panel, `Focus` choreographs first responders in its own window — and
/// run together they perturb each other's key-window and first-responder
/// state.
@Suite("Popup sticky notes — AppKit state", .serialized)
enum PopupNoteAppKitSuites {}

extension PopupNoteAppKitSuites {
    /// Popup-side sticky notes: that the editor's save path reaches
    /// `EntryRepository.setNote` for the right entry with the edited text, and
    /// that the key monitor hands the keyboard to the editor without leaking
    /// Return (paste!) or Delete (delete!) through to the strip.
    ///
    /// Like `PopupPasteRoutingTests`, the controller-level tests drive
    /// `PopupController.shared` and stay synchronous with no internal `await`
    /// (see that suite's note on why); they use a real in-memory `Store` and
    /// read the note back, so there is nothing to mock and no pasteboard or
    /// keystroke side effect to suppress.
    @Suite("editor routing", .serialized)
    @MainActor
    struct Routing {

        private func makeStoreWithTwoEntries(
            firstNote: String? = nil, secondNote: String? = nil
        ) throws -> (store: Store, firstId: Int64, secondId: Int64) {
            let store = try Store.inMemory()
            let devId = try store.dbQueue.write { db -> Int64 in
                var d = Device(identifier: "d", name: "D", kind: "mac")
                try d.insert(db)
                return d.id!
            }
            func insert(byte: UInt8, text: String, createdAt: Double, note: String?) throws -> Int64 {
                try store.dbQueue.write { db in
                    var e = Entry(
                        uuid: Data(repeating: byte, count: 16), createdAt: createdAt, capturedAt: createdAt,
                        kind: .text, sourceDeviceId: devId, textPreview: text,
                        contentHash: Data(repeating: byte, count: 32), totalSize: Int64(text.utf8.count),
                        note: note
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
            let firstId = try insert(byte: 1, text: "first entry", createdAt: 1_700_000_000, note: firstNote)
            let secondId = try insert(byte: 2, text: "second entry", createdAt: 1_700_000_001, note: secondNote)
            return (store, firstId, secondId)
        }

        /// Configures and shows the shared controller (show() is what runs
        /// `PopupState.refresh()`, exactly as a hotkey summon does).
        private func summon(_ store: Store) throws -> PopupState {
            PopupController.shared.configure(store: store, captureMode: .capturing)
            PopupController.shared.show()
            return try #require(PopupController.shared.state)
        }

        private func rowIndex(of id: Int64, in state: PopupState) -> Int? {
            state.rows.firstIndex { $0.entry.id == id }
        }

        private static let returnKey: UInt16 = 36
        private static let escapeKey: UInt16 = 53

        @Test("⌘Return saves the draft onto the entry the editor was opened on, not the current selection")
        func commitWritesToEditedEntryNotSelection() throws {
            let (store, firstId, secondId) = try makeStoreWithTwoEntries()
            let state = try summon(store)
            defer { PopupController.shared.hide() }

            state.beginNoteEdit(entryId: firstId)
            #expect(state.isEditingNote)
            state.noteDraft = "call back Tuesday\nask about the invoice"
            // Selection drifts to the other card (a refresh shifted the rows,
            // or a click) while the editor stays on its own entry — the
            // v3.3.1 lesson: never resolve a target through selectedIndex.
            state.selectedIndex = try #require(rowIndex(of: secondId, in: state))

            #expect(PopupController.shared.noteEditorKeyDown(keyCode: Self.returnKey, cmdHeld: true))

            let repo = EntryRepository(store: store)
            #expect(try repo.note(id: firstId) == "call back Tuesday\nask about the invoice")
            #expect(try repo.note(id: secondId) == nil)
            #expect(!state.isEditingNote)
            // The strip refreshes without reopening the popup: the rows the
            // cards render from already carry the note.
            #expect(state.rows.first { $0.entry.id == firstId }?.entry.note == "call back Tuesday\nask about the invoice")
        }

        @Test("Esc discards the draft, writes nothing, and leaves the popup open")
        func escapeCancelsWithoutDismissing() throws {
            let (store, firstId, _) = try makeStoreWithTwoEntries(firstNote: "keep me")
            let state = try summon(store)
            defer { PopupController.shared.hide() }

            state.beginNoteEdit(entryId: firstId)
            state.noteDraft = "changed my mind"
            #expect(PopupController.shared.noteEditorKeyDown(keyCode: Self.escapeKey, cmdHeld: false))

            #expect(!state.isEditingNote)
            #expect(try EntryRepository(store: store).note(id: firstId) == "keep me")
            #expect(NSApplication.shared.windows.contains { $0 is PopupPanel && $0.isVisible })
        }

        @Test("While editing, every other key falls through to the text view")
        func otherKeysFallThroughWhileEditing() throws {
            let (store, firstId, _) = try makeStoreWithTwoEntries()
            let state = try summon(store)
            defer { PopupController.shared.hide() }
            state.beginNoteEdit(entryId: firstId)
            state.noteDraft = "draft"

            // Return (would paste), ←/→ (would move selection), Backspace /
            // forward-delete (would delete the ENTRY), Space, ⌘Z (would undo
            // an entry action), ⌘Return's un-modified twin.
            let fallThrough: [(UInt16, Bool)] = [
                (Self.returnKey, false), (76, false), (123, false), (124, false),
                (51, false), (117, false), (49, false), (6, true), (45, true),
            ]
            for (key, cmd) in fallThrough {
                #expect(!PopupController.shared.noteEditorKeyDown(keyCode: key, cmdHeld: cmd), "key \(key) cmd=\(cmd) was consumed")
            }
            // Nothing was saved, deleted or closed by any of them.
            #expect(state.isEditingNote)
            #expect(state.noteDraft == "draft")
            #expect(try EntryRepository(store: store).note(id: firstId) == nil)
            #expect(state.rows.count == 2)
        }

        @Test("Outside editing the editor hook claims nothing, not even Esc")
        func hookIsInertWhenNotEditing() throws {
            let (store, _, _) = try makeStoreWithTwoEntries()
            _ = try summon(store)
            defer { PopupController.shared.hide() }
            for key: UInt16 in [Self.escapeKey, Self.returnKey, 51, 123] {
                #expect(!PopupController.shared.noteEditorKeyDown(keyCode: key, cmdHeld: true))
                #expect(!PopupController.shared.noteEditorKeyDown(keyCode: key, cmdHeld: false))
            }
        }

        @Test("⌘N opens the editor on the selected card, seeded with its existing note")
        func editNoteOnSelectedSeedsDraft() throws {
            let (store, firstId, secondId) = try makeStoreWithTwoEntries(secondNote: "existing note")
            let state = try summon(store)
            defer { PopupController.shared.hide() }

            state.selectedIndex = try #require(rowIndex(of: secondId, in: state))
            PopupController.shared.editNoteOnSelected()

            #expect(state.noteEditEntryId == secondId)
            #expect(state.noteDraft == "existing note")
            #expect(state.noteEditEntryId != firstId)
        }

        @Test("A blank draft clears the note")
        func blankDraftClears() throws {
            let (store, firstId, _) = try makeStoreWithTwoEntries(firstNote: "old note")
            let state = try summon(store)
            defer { PopupController.shared.hide() }

            state.beginNoteEdit(entryId: firstId)
            state.noteDraft = "  \n \n"
            #expect(state.commitNoteEdit())

            #expect(try EntryRepository(store: store).note(id: firstId) == nil)
            #expect(state.rows.first { $0.entry.id == firstId }?.entry.note == nil)
        }

        @Test("Opening and saving an edit without changing it writes nothing (no modified_at bump, no push)")
        func unchangedCommitIsNoOp() throws {
            let (store, firstId, _) = try makeStoreWithTwoEntries(firstNote: "steady")
            let state = try summon(store)
            defer { PopupController.shared.hide() }
            let repo = EntryRepository(store: store)
            let before = try #require(try repo.fetch(id: firstId)).modifiedAt

            state.beginNoteEdit(entryId: firstId)
            #expect(state.commitNoteEdit())

            #expect(try #require(try repo.fetch(id: firstId)).modifiedAt == before)
        }

        @Test("Dismissing the popup saves a half-typed note instead of dropping it")
        func hideSavesInFlightEdit() throws {
            let (store, firstId, _) = try makeStoreWithTwoEntries()
            let state = try summon(store)

            state.beginNoteEdit(entryId: firstId)
            state.noteDraft = "typed, then clicked away"
            PopupController.shared.hide()

            #expect(!state.isEditingNote)
            #expect(try EntryRepository(store: store).note(id: firstId) == "typed, then clicked away")
        }

        @Test("Starting an edit on another card saves the first one")
        func secondEditCommitsFirst() throws {
            let (store, firstId, secondId) = try makeStoreWithTwoEntries()
            let state = try summon(store)
            defer { PopupController.shared.hide() }

            state.beginNoteEdit(entryId: firstId)
            state.noteDraft = "first note"
            state.beginNoteEdit(entryId: secondId)

            #expect(state.noteEditEntryId == secondId)
            #expect(state.noteDraft == "")
            #expect(try EntryRepository(store: store).note(id: firstId) == "first note")
        }

        @Test("If the edited card leaves the strip the editor closes and the text is kept")
        func editorClosesWhenEntryLeavesRows() throws {
            let (store, firstId, _) = try makeStoreWithTwoEntries()
            let state = try summon(store)
            defer { PopupController.shared.hide() }

            state.beginNoteEdit(entryId: firstId)
            state.noteDraft = "typed before the filter changed"
            state.query = "no-entry-contains-this"   // empties `rows`

            #expect(!state.isEditingNote)
            #expect(try EntryRepository(store: store).note(id: firstId) == "typed before the filter changed")
            // The monitor is back in normal mode, not stuck swallowing keys.
            #expect(!PopupController.shared.noteEditorKeyDown(keyCode: Self.returnKey, cmdHeld: true))
        }

        @Test("Remove Note clears the note, refreshes the strip, and drops a stale draft")
        func removeNote() throws {
            let (store, firstId, _) = try makeStoreWithTwoEntries(firstNote: "to remove")
            let state = try summon(store)

            state.beginNoteEdit(entryId: firstId)
            state.noteDraft = "to remove, edited"
            state.setNote(id: firstId, note: nil)
            #expect(!state.isEditingNote)
            #expect(state.rows.first { $0.entry.id == firstId }?.entry.note == nil)

            // The discarded draft must not resurrect the note on hide.
            PopupController.shared.hide()
            #expect(try EntryRepository(store: store).note(id: firstId) == nil)
        }

        @Test("beginNoteEdit ignores an entry the popup isn't showing")
        func beginIgnoresUnknownEntry() throws {
            let (store, _, _) = try makeStoreWithTwoEntries()
            let state = try summon(store)
            defer { PopupController.shared.hide() }

            state.beginNoteEdit(entryId: 999_999)
            #expect(!state.isEditingNote)
        }
    }

    /// First-responder discipline: the note editor takes keyboard focus from
    /// the popup's search field and hands it back — caret and all — when it
    /// closes, however it closes.
    @Suite("focus hand-off", .serialized)
    @MainActor
    struct Focus {

        private func allViews(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(allViews) }

        /// A popup view tree in a real (never shown) window, plus the search
        /// field and the id of the one entry.
        private func makePopup() async throws -> (window: NSWindow, state: PopupState, field: NSTextField, entryId: Int64) {
            // `PopupState.init` probes the embedding model in a Task and flips
            // `semanticAvailable` when it answers, which adds a header chip
            // and re-lays the search row out. Answer it (the verdict is
            // memoized process-wide) before the focus choreography starts.
            _ = await EmbeddingService.isAvailable()
            let store = try Store.inMemory()
            let devId = try await store.dbQueue.write { db -> Int64 in
                var d = Device(identifier: "d", name: "D", kind: "mac")
                try d.insert(db)
                return d.id!
            }
            let entryId = try await store.dbQueue.write { db -> Int64 in
                var e = Entry(
                    uuid: Data(repeating: 1, count: 16), createdAt: 1, capturedAt: 1,
                    kind: .text, sourceDeviceId: devId, textPreview: "HEADLINE",
                    contentHash: Data(repeating: 1, count: 32), totalSize: 8
                )
                try e.insert(db)
                try FtsIndex.indexEntry(db: db, entryId: e.id!, title: nil, text: "HEADLINE", appName: nil)
                return e.id!
            }
            let state = PopupState(store: store)
            state.refresh()
            let hosting = NSHostingView(
                rootView: PopupRootView(state: state, onPaste: { _ in }).environment(\.cpdbStore, store)
            )
            hosting.frame = NSRect(x: 0, y: 0, width: 900, height: PopupController.panelHeight)
            let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = hosting
            window.orderOut(nil)
            hosting.layoutSubtreeIfNeeded()
            let field = try #require(allViews(hosting).compactMap { $0 as? NSTextField }.first { $0.isEditable })
            // Let the model-probe Task land its `semanticAvailable` verdict.
            try await Task.sleep(for: .milliseconds(200))
            return (window, state, field, entryId)
        }

        /// Waits (main run loop turning: SwiftUI updates, AppKit's deferred
        /// first-responder changes) until `condition` holds, up to 5s — a
        /// poll, not a fixed sleep, so a loaded machine is slow rather than
        /// flaky.
        @discardableResult
        private func waitUntil(_ condition: () -> Bool) async throws -> Bool {
            for _ in 0..<100 {
                if condition() { return true }
                try await Task.sleep(for: .milliseconds(50))
            }
            return condition()
        }

        private func searchFieldHasFocus(_ window: NSWindow, _ field: NSTextField) -> Bool {
            let editor = window.firstResponder as? NSTextView
            return editor?.isFieldEditor == true && editor?.delegate === field
        }

        /// Focus the search field with a query (one the entry matches, so its
        /// card stays on screen) and the caret mid-string. The query goes
        /// through the binding, as typing does: poking `stringValue` directly
        /// would be undone by SwiftUI at the next render.
        private func focusSearch(_ window: NSWindow, _ field: NSTextField, _ state: PopupState) async throws {
            state.query = "head"
            try await waitUntil { field.stringValue == "head" }
            #expect(window.makeFirstResponder(field))
            try await waitUntil { field.currentEditor() != nil }
            (field.currentEditor() as? NSTextView)?.setSelectedRange(NSRange(location: 2, length: 0))
        }

        private func expectSearchHasFocus(_ window: NSWindow, _ field: NSTextField) async throws {
            try await waitUntil { searchFieldHasFocus(window, field) }
            let editor = window.firstResponder as? NSTextView
            #expect(searchFieldHasFocus(window, field), "search field lost focus: first responder is \(String(describing: window.firstResponder))")
            #expect(editor?.selectedRange == NSRange(location: 2, length: 0), "caret not restored: \(String(describing: editor?.selectedRange))")
        }

        @Test("Saving a note returns focus to the search field with its caret")
        func commitRestoresSearchFocus() async throws {
            let (window, state, field, entryId) = try await makePopup()
            try await focusSearch(window, field, state)

            state.beginNoteEdit(entryId: entryId)
            try await waitUntil { window.firstResponder is NoteNSTextView }
            let editor = try #require(window.firstResponder as? NoteNSTextView)
            editor.insertText("remember this", replacementRange: NSRange(location: 0, length: 0))
            #expect(state.noteDraft == "remember this")

            #expect(state.commitNoteEdit())
            try await expectSearchHasFocus(window, field)
        }

        @Test("Cancelling a note returns focus to the search field with its caret")
        func cancelRestoresSearchFocus() async throws {
            let (window, state, field, entryId) = try await makePopup()
            try await focusSearch(window, field, state)

            state.beginNoteEdit(entryId: entryId)
            try await waitUntil { window.firstResponder is NoteNSTextView }
            #expect(window.firstResponder is NoteNSTextView)

            state.cancelNoteEdit()
            try await expectSearchHasFocus(window, field)
        }

        @Test("The editor handles the standard edit shortcuts itself (the app has no Edit menu)")
        func standardEditShortcuts() {
            func key(_ chars: String, _ flags: NSEvent.ModifierFlags) -> NSEvent {
                NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                    windowNumber: 0, context: nil, characters: chars, charactersIgnoringModifiers: chars,
                    isARepeat: false, keyCode: 0
                )!
            }
            let textView = NoteNSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
            textView.string = "hello world"

            #expect(textView.performKeyEquivalent(with: key("a", .command)))
            #expect(textView.selectedRange == NSRange(location: 0, length: 11))
            // Not ours: unmodified, and ⌘⌥ combinations are left to AppKit.
            #expect(!textView.performKeyEquivalent(with: key("a", [])))
            textView.setSelectedRange(NSRange(location: 3, length: 0))
            _ = textView.performKeyEquivalent(with: key("a", [.command, .option]))
            #expect(textView.selectedRange == NSRange(location: 3, length: 0))
        }
    }
}

@Suite("Popup sticky notes — search attribution and card text")
@MainActor
struct PopupNoteSearchTests {

    @Test("A note-only hit is attributed to the note and keeps the clip's own text")
    func noteOnlyHitIsAttributed() throws {
        let store = try Store.inMemory()
        let devId = try store.dbQueue.write { db -> Int64 in
            var d = Device(identifier: "d", name: "D", kind: "mac")
            try d.insert(db)
            return d.id!
        }
        let repo = EntryRepository(store: store)
        let id = try store.dbQueue.write { db -> Int64 in
            var e = Entry(
                uuid: Data(repeating: 1, count: 16), createdAt: 1, capturedAt: 1,
                kind: .text, sourceDeviceId: devId, textPreview: "quarterly numbers",
                contentHash: Data(repeating: 1, count: 32), totalSize: 17
            )
            try e.insert(db)
            try FtsIndex.indexEntry(db: db, entryId: e.id!, title: nil, text: "quarterly numbers", appName: nil)
            return e.id!
        }
        try repo.setNote(id: id, note: "send to the zebra team")

        let state = PopupState(store: store)
        state.query = "zebra"

        #expect(state.rows.map(\.entry.id) == [id])
        #expect(state.matchSourcesById[id] == .note)
        // The snippet FTS5 produced for this hit comes from the note; the
        // card must not show it as if it were the clip's text.
        #expect(EntryCard.bodySnippet(state.snippetsById[id], matchSource: state.matchSourcesById[id]) == nil)
    }

    @Test("Only note-involved hits drop the snippet")
    func bodySnippetPerSource() {
        #expect(EntryCard.bodySnippet("[hit]", matchSource: nil) == "[hit]")
        #expect(EntryCard.bodySnippet("[hit]", matchSource: .text) == "[hit]")
        #expect(EntryCard.bodySnippet("[hit]", matchSource: .semantic) == "[hit]")
        #expect(EntryCard.bodySnippet("[hit]", matchSource: .note) == nil)
        #expect(EntryCard.bodySnippet("[hit]", matchSource: .multiple) == nil)
    }
}

@Suite("Popup sticky notes — strip text")
struct NoteStripTextTests {

    @Test("firstLine skips leading blank lines and trims")
    func firstLine() {
        #expect(NoteStrip.firstLine(of: "plain") == "plain")
        #expect(NoteStrip.firstLine(of: "one\ntwo\nthree") == "one")
        #expect(NoteStrip.firstLine(of: "\n\n  \n   padded line  \nnext") == "padded line")
        #expect(NoteStrip.firstLine(of: "crlf\r\nnext") == "crlf")
    }

    @Test("visibleNote hides blank notes")
    func visibleNote() {
        #expect(NoteStrip.visibleNote(nil) == nil)
        #expect(NoteStrip.visibleNote("") == nil)
        #expect(NoteStrip.visibleNote(" \n\t ") == nil)
        #expect(NoteStrip.visibleNote("x") == "x")
    }
}
#endif
