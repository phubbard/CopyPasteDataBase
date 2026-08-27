#if os(macOS)
import AppIntents
import CpdbShared

/// Thrown by the intents below for the two ways they can fail in a
/// way worth explaining to the user (rather than just silently doing
/// nothing): the app isn't ready yet, or there's nothing at the
/// requested position. `CustomLocalizedStringResourceConvertible`
/// lets Shortcuts/Siri speak the message directly.
enum ClipIntentError: Error, CustomLocalizedStringResourceConvertible {
    case storeNotReady
    case positionOutOfRange(Int)
    case nothingToPaste

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .storeNotReady:
            return "cpdb is still starting up. Try again in a moment."
        case .positionOutOfRange(let n):
            return "There's no clip at position \(n)."
        case .nothingToPaste:
            return "Your clipboard history is empty."
        }
    }
}

/// Opens cpdb's popup with a search query pre-filled — the Shortcuts/
/// Siri equivalent of summoning the popup and typing into the search
/// field yourself.
struct SearchClipsIntent: AppIntent {
    static let title: LocalizedStringResource = "Search Clips"
    static let description = IntentDescription(
        "Opens cpdb with your search already typed in."
    )

    @Parameter(title: "Search text")
    var query: String

    static var parameterSummary: some ParameterSummary {
        Summary("Search my clipboard for \(\.$query)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        guard await AppReadiness.shared.waitForStore() != nil else {
            throw ClipIntentError.storeNotReady
        }
        PopupController.shared.searchAndShow(query: query)
        return .result()
    }
}

/// Pastes the single most recent clip into whatever app was frontmost
/// when the Shortcut/Siri request fired — no popup shown, matching
/// how ⌘V-from-the-popup itself never announces success visually.
struct PasteLatestIntent: AppIntent {
    static let title: LocalizedStringResource = "Paste Latest Clip"
    static let description = IntentDescription(
        "Pastes your most recent clipboard entry into the frontmost app."
    )

    static var parameterSummary: some ParameterSummary {
        Summary("Paste my last clip")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let store = await AppReadiness.shared.waitForStore() else {
            throw ClipIntentError.storeNotReady
        }
        guard try ClipIntentSupport.recentEntries(store: store, limit: 1).first != nil else {
            throw ClipIntentError.nothingToPaste
        }
        PopupController.shared.pasteRecent(atIndex: 1)
        return .result()
    }
}

/// Pastes the Nth-most-recent clip (1 = newest, matching card position
/// in the popup strip) into the frontmost app.
struct PasteNthIntent: AppIntent {
    static let title: LocalizedStringResource = "Paste Clip by Position"
    static let description = IntentDescription(
        "Pastes the Nth most recent clipboard entry (1 = newest) into the frontmost app."
    )

    @Parameter(title: "Position", description: "1 = newest, 2 = second most recent, and so on.")
    var n: Int

    static var parameterSummary: some ParameterSummary {
        Summary("Paste clip number \(\.$n)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let store = await AppReadiness.shared.waitForStore() else {
            throw ClipIntentError.storeNotReady
        }
        guard n >= 1, n <= 9 else {
            throw ClipIntentError.positionOutOfRange(n)
        }
        let rows = try ClipIntentSupport.recentEntries(store: store, limit: n)
        guard ClipIntentSupport.entry(atRecentIndex: n, in: rows) != nil else {
            throw ClipIntentError.positionOutOfRange(n)
        }
        PopupController.shared.pasteRecent(atIndex: n)
        return .result()
    }
}

/// Toggles the pin on the single most recent clip — "I just copied
/// something I don't want to lose" without opening the popup.
struct TogglePinLatestIntent: AppIntent {
    static let title: LocalizedStringResource = "Pin Latest Clip"
    static let description = IntentDescription(
        "Toggles the pin on your most recent clipboard entry."
    )

    static var parameterSummary: some ParameterSummary {
        Summary("Pin my last clip")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let store = await AppReadiness.shared.waitForStore() else {
            throw ClipIntentError.storeNotReady
        }
        guard try ClipIntentSupport.recentEntries(store: store, limit: 1).first != nil else {
            throw ClipIntentError.nothingToPaste
        }
        PopupController.shared.togglePinLatest()
        return .result()
    }
}

/// Registers the natural-language phrases Siri/Shortcuts recognize for
/// the intents above. Each phrase must include `\(.applicationName)`
/// per App Intents' requirement that the app name be discoverable in
/// speech.
struct ClipAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SearchClipsIntent(),
            phrases: [
                "Search my clipboard for \(\.$query) in \(.applicationName)",
                "Search \(.applicationName) for \(\.$query)",
            ],
            shortTitle: "Search Clips",
            systemImageName: "magnifyingglass"
        )
        AppShortcut(
            intent: PasteLatestIntent(),
            phrases: [
                "Paste my last clip with \(.applicationName)",
                "Paste my last copy in \(.applicationName)",
            ],
            shortTitle: "Paste Latest Clip",
            systemImageName: "doc.on.clipboard"
        )
        AppShortcut(
            intent: PasteNthIntent(),
            phrases: [
                "Paste clip number \(\.$n) with \(.applicationName)",
            ],
            shortTitle: "Paste Clip by Position",
            systemImageName: "doc.on.clipboard.fill"
        )
        AppShortcut(
            intent: TogglePinLatestIntent(),
            phrases: [
                "Pin my last clip in \(.applicationName)",
            ],
            shortTitle: "Pin Latest Clip",
            systemImageName: "pin"
        )
    }
}
#endif
