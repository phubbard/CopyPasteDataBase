import SwiftUI
import CpdbCore

/// Top-level SwiftUI view hosted inside `PopupPanel`.
struct PopupRootView: View {
    @Bindable var state: PopupState
    let onPaste: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
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
                Text("\(state.totalLive) items")
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
