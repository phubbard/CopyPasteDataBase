#if os(iOS)
import SwiftUI
import GRDB
import CpdbShared

/// iOS counterpart of the Mac app's About window. Presented as a
/// sheet when the user taps the brand header at the top of
/// SearchView. Shows:
///   - App icon + name + version (marketing + git sha)
///   - One-line tagline
///   - Link to the GitHub repo
///   - Library stats: total live entries + per-kind breakdown
///   - Last-sync timestamp
///
/// Read-only view; polling is a one-shot on appearance (stats don't
/// change meaningfully between appearances during normal use).
struct AboutSheet: View {
    @Environment(AppContainer.self) private var container
    @Environment(\.dismiss) private var dismiss
    @State private var totalEntries: Int = 0
    @State private var kindCounts: [String: Int] = [:]
    @State private var lastSyncText: String = "—"

    private static let repoURL = URL(string: "https://github.com/phubbard/CopyPasteDataBase")!

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    Image(systemName: "list.clipboard.fill")
                        .font(.system(size: 64))
                        .foregroundStyle(.tint)
                        .padding(.top, 12)

                    Text("cpdb")
                        .font(.system(size: 30, weight: .bold, design: .rounded))

                    Text("v\(CpdbVersion.current)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.tertiary)

                    Text("A local-first clipboard history for macOS, with on-device OCR and image search. iOS read-only client.")
                        .font(.system(size: 13))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 24)

                    Link(destination: Self.repoURL) {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left.forwardslash.chevron.right")
                            Text("github.com/phubbard/CopyPasteDataBase")
                        }
                        .font(.system(size: 13))
                    }

                    Divider()
                        .padding(.horizontal, 24)

                    statsBlock
                        .padding(.horizontal, 24)

                    Spacer(minLength: 24)
                }
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("About")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task {
            await loadStats()
        }
    }

    @ViewBuilder
    private var statsBlock: some View {
        VStack(spacing: 6) {
            aboutRow("Last sync", value: lastSyncText)
            aboutRow("Library", value: "\(totalEntries) entries")

            // Per-kind breakdown. Hidden when zero for that kind.
            let rows: [(String, Int)] = [
                ("Text",   kindCounts["text"]  ?? 0),
                ("Links",  kindCounts["link"]  ?? 0),
                ("Images", kindCounts["image"] ?? 0),
                ("Files",  kindCounts["file"]  ?? 0),
                ("Colors", kindCounts["color"] ?? 0),
                ("Other",  kindCounts["other"] ?? 0),
            ]
            ForEach(rows, id: \.0) { label, count in
                if count > 0 {
                    HStack {
                        Text(label)
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                            .padding(.leading, 10)
                        Spacer()
                        Text("\(count)")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func aboutRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 13, design: .monospaced))
        }
    }

    @MainActor
    private func loadStats() async {
        lastSyncText = Self.formattedLastSync()
        guard let store = container.store else { return }
        do {
            let (total, counts) = try await store.dbQueue.read { db -> (Int, [String: Int]) in
                let t = try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM entries WHERE deleted_at IS NULL"
                ) ?? 0
                var k: [String: Int] = [:]
                let rows = try Row.fetchAll(
                    db,
                    sql: "SELECT kind, COUNT(*) as n FROM entries WHERE deleted_at IS NULL GROUP BY kind"
                )
                for row in rows {
                    let kind: String = row["kind"]
                    let n: Int = row["n"]
                    k[kind] = n
                }
                return (t, k)
            }
            totalEntries = total
            kindCounts = counts
        } catch {
            // Silent — the sheet is informational and keeps the
            // defaults (0 / empty) if the DB read fails.
        }
    }

    private static func formattedLastSync() -> String {
        let raw = UserDefaults.standard.double(forKey: CloudKitSyncer.lastSyncSuccessKey)
        guard raw > 0 else { return "Never" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(
            for: Date(timeIntervalSince1970: raw),
            relativeTo: Date()
        )
    }
}
#endif
