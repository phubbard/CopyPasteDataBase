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
            // Real SearchField lands in step 10; for now use a SwiftUI
            // TextField so we have a placeholder + binding to exercise.
            TextField("Search clipboard history…", text: $state.query)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
            Spacer()
            Text("\(state.totalLive) items")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.tertiary)
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
