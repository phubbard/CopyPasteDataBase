import SwiftUI
import AppKit
import CpdbShared

/// Sticky-note editor shown over the lower part of a card (`EntryCard`
/// overlays it while `PopupState.noteEditEntryId` names that card). It
/// lives inside the popup panel — no separate window — and does not touch
/// the card's layout, so the panel-height contract is unaffected.
///
/// Saving and cancelling are keyboard-driven and handled by
/// `PopupController`'s key monitor (⌘↩ / Esc), not here: that monitor sees
/// every key before the text view does, and while the editor is open it
/// lets everything except those two through.
struct NoteEditor: View {
    @Binding var text: String
    /// See `NoteNSTextView.onFocusLost`.
    var onFocusLost: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: "note.text")
                    .font(.system(size: 10, weight: .semibold))
                Text("Note")
                    .font(.system(size: 10, weight: .semibold))
                Spacer(minLength: 0)
                Text("⌘↩ save · ⎋ cancel")
                    .font(.system(size: 9, design: .monospaced))
                    .opacity(0.6)
            }
            NoteTextView(text: $text, onFocusLost: onFocusLost)
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        // Aligned with the text view's container inset +
                        // line-fragment padding (4pt / 5pt) so typing
                        // starts exactly where the placeholder was.
                        Text("Write a note…")
                            .font(.system(size: 12))
                            .opacity(0.4)
                            .padding(.leading, 9)
                            .padding(.top, 4)
                            .allowsHitTesting(false)
                    }
                }
        }
        .foregroundStyle(StickyNoteStyle.ink)
        .padding(8)
        .frame(maxWidth: .infinity)
        .frame(height: EntryCard.noteEditorHeight)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(StickyNoteStyle.paper)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(StickyNoteStyle.ink.opacity(0.25), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.25), radius: 4, y: 1)
    }
}

/// Multiline plain-text field backing `NoteEditor`. An `NSTextView` rather
/// than SwiftUI's `TextEditor` so focus is explicit: see `NoteNSTextView`.
struct NoteTextView: NSViewRepresentable {
    @Binding var text: String
    /// See `NoteNSTextView.onFocusLost`.
    var onFocusLost: (() -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder

        let textView = NoteNSTextView(frame: .zero)
        textView.delegate = context.coordinator
        textView.onFocusLost = onFocusLost
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(width: scroll.contentSize.width, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainerInset = NSSize(width: 4, height: 4)

        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.font = .systemFont(ofSize: 12)
        textView.textColor = StickyNoteStyle.nsInk
        textView.insertionPointColor = StickyNoteStyle.nsInk
        // A note is scratch text, often identifiers, paths and error
        // strings: no squiggles, smart quotes or dash rewriting.
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false

        textView.string = text
        scroll.documentView = textView
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        (scroll.documentView as? NoteNSTextView)?.onFocusLost = onFocusLost
        guard let textView = scroll.documentView as? NSTextView, textView.string != text else { return }
        textView.string = text
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NoteTextView

        init(_ parent: NoteTextView) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            // Enforce the stored bound up front (EntryRepository.setNote
            // would truncate silently at save time).
            let capped = EntryRepository.cappedNote(textView.string)
            if capped != textView.string {
                textView.string = capped
                textView.setSelectedRange(NSRange(location: (capped as NSString).length, length: 0))
            }
            parent.text = capped
        }
    }
}

/// The popup is a non-activating panel whose search field is normally
/// first responder. This text view takes first responder when it joins
/// the window and gives it back to whoever held it when it leaves (editor
/// closed, card scrolled out of the lazy strip), so typing after a note
/// edit still lands in the search field with its caret where it was.
final class NoteNSTextView: NSTextView {
    private weak var focusDonor: NSResponder?
    private var donorSelection: NSRange?

    /// Fired (next runloop turn) when this view genuinely loses first
    /// responder — the user clicked the search field, say. The popup's
    /// key monitor keys its editor mode off `PopupState.isEditingNote`,
    /// so an editor that keeps "editing" after its focus left would eat
    /// Return/arrows/Esc that the user now expects to act on the popup.
    /// The wired handler commits the draft (idempotent: a no-op once the
    /// editor is already closed, which also covers the resign that fires
    /// during this view's own save/unmount).
    var onFocusLost: (() -> Void)?

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned {
            // Async: resign can fire inside makeFirstResponder re-entrancy
            // and mid-SwiftUI-update; the commit mutates observable state.
            DispatchQueue.main.async { [weak self] in
                self?.onFocusLost?()
            }
        }
        return resigned
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        // Remember the previous owner synchronously — by the next runloop
        // turn this view is first responder and the evidence is gone. A
        // text field's focus lives in the shared field editor, so record
        // the field (the thing to refocus) and the caret.
        let current = window.firstResponder
        if let editor = current as? NSTextView, editor.isFieldEditor, let field = editor.delegate as? NSResponder {
            focusDonor = field
            donorSelection = editor.selectedRange
        } else if current !== self {
            focusDonor = current
            donorSelection = nil
        }
        // Not inside this layout pass: SwiftUI is still mid-update.
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            window.makeFirstResponder(self)
        }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil, let window, window.firstResponder === self {
            let donor = focusDonor
            let selection = donorSelection
            focusDonor = nil
            donorSelection = nil
            // AppKit parks first responder on the window once this view is
            // out, and that lands after this callback — so hand focus back
            // on the next turn, and only if nothing else (the user
            // clicking elsewhere) has claimed it in the meantime.
            //
            // The window must NOT be captured here, even weakly: when this
            // unmount is the window itself deallocating (a torn-down panel
            // in tests; PopupController.configure replacing the panel),
            // forming a weak reference to a deallocating instance is an
            // Objective-C fatal error. `donor` is captured strongly — at
            // this point it is alive, merely un-parented later — and the
            // window is re-derived from it at fire time, coming back nil
            // if the window is gone by then.
            DispatchQueue.main.async { [donor] in
                guard let donor,
                      let window = (donor as? NSView)?.window,
                      window.firstResponder === window,
                      window.makeFirstResponder(donor)
                else { return }
                // makeFirstResponder selects a text field's whole contents;
                // put the caret back where the user left it.
                if let selection, let editor = (donor as? NSControl)?.currentEditor() {
                    let length = (editor.string as NSString).length
                    editor.selectedRange = NSRange(location: min(selection.location, length), length: 0)
                }
            }
        }
        super.viewWillMove(toWindow: newWindow)
    }

    /// cpdb is an accessory app with no main menu, so nothing routes the
    /// standard editing shortcuts to a text view (they are menu key
    /// equivalents). Handle them here; anything else falls through.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // AppKit offers key equivalents to the whole view tree, not just
        // the focused view — without this guard, ⌘A/C/X/V/Z pressed while
        // the search field holds focus would act on the note draft.
        guard window?.firstResponder === self else {
            return super.performKeyEquivalent(with: event)
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command), !flags.contains(.option), !flags.contains(.control),
              let key = event.charactersIgnoringModifiers?.lowercased()
        else { return super.performKeyEquivalent(with: event) }
        switch (key, flags.contains(.shift)) {
        case ("a", false): selectAll(nil)
        case ("c", false): copy(nil)
        case ("x", false): cut(nil)
        case ("v", false): paste(nil)
        case ("z", false): undoManager?.undo()
        case ("z", true): undoManager?.redo()
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }
}
