import AppKit

/// Non-activating popup window that floats above other apps without stealing
/// focus from them.
///
/// The `.nonactivatingPanel` style mask is what makes this work: clicking
/// the panel doesn't deactivate the app that was frontmost, so when the user
/// picks an entry and we synthesise ⌘V, the keystroke lands in the right
/// place.
///
/// Important: the style mask MUST be set at construction time. AppKit has a
/// long-standing bug where toggling `.nonactivatingPanel` on an existing
/// panel does nothing — you have to instantiate with it up front.
final class PopupPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [
                .nonactivatingPanel,
                .titled,
                .fullSizeContentView,
                .resizable,
            ],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        hasShadow = true
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        // Show on every Space / over fullscreen apps.
        collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .transient,
        ]
        isReleasedWhenClosed = false
    }

    // These two overrides make the panel keyboard-focusable (so the search
    // field and arrow keys work) without the panel being considered a "main"
    // window — which would fight with the app it's floating over.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
