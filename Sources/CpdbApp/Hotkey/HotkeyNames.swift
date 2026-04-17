import Foundation
import KeyboardShortcuts

/// Strongly-typed names for every hotkey cpdb registers.
///
/// Using `KeyboardShortcuts.Name` with `default: nil` means:
///   - no opinionated default key combo
///   - the first launch shows an orange dot on the status item until the
///     user picks one in Preferences
///   - the choice is persisted to `UserDefaults` under the name string
extension KeyboardShortcuts.Name {
    static let summonPopup = Self("summonPopup")
}
