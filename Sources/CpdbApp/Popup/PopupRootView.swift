import SwiftUI
import CpdbCore
import CpdbShared

/// Top-level SwiftUI view hosted inside `PopupPanel`.
struct PopupRootView: View {
    @Bindable var state: PopupState
    let onPaste: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            kindFilterRow
            Divider()
            if state.rows.isEmpty {
                emptyState
            } else {
                EntryStripView(state: state, onPaste: onPaste)
            }
            if case .readOnly(let holder) = state.captureMode {
                readOnlyBanner(holder: holder)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThinMaterial)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search clipboard history…", text: $state.query)
                .textFieldStyle(.plain)
                .font(.system(size: 15))

            // Scope toggles. Persisted via `PopupState.searchScope`'s didSet.
            HStack(spacing: 4) {
                ScopeChip(label: "text",
                          isOn: $state.searchScope.text)
                ScopeChip(label: "OCR",
                          isOn: $state.searchScope.ocr)
                ScopeChip(label: "tags",
                          isOn: $state.searchScope.tags)
            }

            HStack(spacing: 8) {
                if state.isSearching {
                    // While searching, the useful count is how many rows
                    // currently match. When we've hit the fetch cap we
                    // suffix a `+` so the user knows there may be more.
                    let atCap = state.rows.count >= state.searchLimit
                    Text("\(state.rows.count)\(atCap ? "+" : "") matches")
                } else {
                    Text("\(state.totalLive) items")
                }
                Text("·")
                    .foregroundStyle(.quaternary)
                Text("v\(CpdbVersion.current)")
            }
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.tertiary)

            // Small gear opens Preferences — the status-bar menu is
            // non-obvious because the popup hijacks focus, so keep this
            // affordance reachable while the popup is up.
            Button {
                PopupController.shared.hide()
                PreferencesWindowController.shared.show()
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Open cpdb Preferences")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    /// Kind-filter chips below the search field. Mirrors iOS's
    /// FilterSheet but inline — the popup is a one-shot UI, a modal
    /// sheet would fight the "press ⌘V then dismiss" rhythm. Click
    /// a chip to toggle; "All" resets to every kind. Chip state is
    /// persisted by `PopupState.kindFilter`.
    private var kindFilterRow: some View {
        let all = Set(EntryKind.allCases)
        let isAll = state.kindFilter == all || state.kindFilter.isEmpty
        return HStack(spacing: 6) {
            Text("Kinds")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tertiary)

            KindChip(label: "All", systemImage: "square.grid.2x2", isOn: isAll) {
                state.kindFilter = all
            }
            ForEach(EntryKind.allCases, id: \.self) { kind in
                KindChip(
                    label: kind.rawValue.capitalized,
                    systemImage: Self.iconName(for: kind),
                    isOn: !isAll && state.kindFilter.contains(kind)
                ) {
                    // Click semantics: if currently "All", clicking a
                    // chip narrows to JUST that kind (the common case —
                    // "show me only images"). Otherwise toggle
                    // membership in the set.
                    if isAll {
                        state.kindFilter = [kind]
                    } else {
                        var next = state.kindFilter
                        if next.contains(kind) {
                            next.remove(kind)
                        } else {
                            next.insert(kind)
                        }
                        // Empty set = "nothing matches" would be
                        // confusing; snap back to "All" instead.
                        state.kindFilter = next.isEmpty ? all : next
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    /// SF Symbol mapping for each kind's chip glyph. Matches iOS
    /// EntryRow so the two platforms feel like the same app.
    private static func iconName(for kind: EntryKind) -> String {
        switch kind {
        case .text:  return "text.alignleft"
        case .link:  return "link"
        case .image: return "photo"
        case .file:  return "doc"
        case .color: return "paintpalette"
        case .other: return "questionmark.square"
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "clipboard")
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            if state.query.isEmpty {
                Text("No entries yet — copy something.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            } else {
                Text("No matches for \"\(state.query)\"")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func readOnlyBanner(holder: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text("Running read-only — capture daemon is held by \(holder). Stop it and restart the app to take over.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.1))
    }
}

/// Capsule toggle used for the kind-filter row. Compact icon+label
/// variant of `ScopeChip` — the same visual vocabulary so the header
/// reads as one instrument panel. Takes an `action` instead of a
/// `Binding<Bool>` because the "click 'All'" case and the
/// "click-to-narrow when currently All" case need to mutate the
/// whole set, not just this chip's membership.
private struct KindChip: View {
    let label: String
    let systemImage: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.system(size: 10, weight: .semibold))
                Text(label)
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(isOn ? .primary : .secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(isOn ? Color.accentColor.opacity(0.22) : Color.clear)
            )
            .overlay(
                Capsule()
                    .strokeBorder(
                        isOn ? Color.accentColor.opacity(0.45) : Color.secondary.opacity(0.25),
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(.plain)
        .help("Filter by \(label)")
    }
}

/// Small capsule toggle used in the popup header to gate FTS columns.
private struct ScopeChip: View {
    let label: String
    @Binding var isOn: Bool

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(isOn ? .primary : .secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    Capsule()
                        .fill(isOn ? Color.accentColor.opacity(0.22) : Color.clear)
                )
                .overlay(
                    Capsule()
                        .strokeBorder(
                            isOn ? Color.accentColor.opacity(0.45) : Color.secondary.opacity(0.25),
                            lineWidth: 1
                        )
                )
        }
        .buttonStyle(.plain)
        .help("Search the \(label) column")
    }
}
