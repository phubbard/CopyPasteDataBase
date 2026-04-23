#if os(iOS)
import SwiftUI
import CpdbShared
import GRDB
#if canImport(UIKit)
import UIKit
#endif

/// Full detail for one entry. Shows:
/// - Title + text body (text entries)
/// - Embedded thumbnail (image entries)
/// - Source device + source app + timestamps
/// - OCR text + image tags if present
/// - Copy-to-clipboard button
///
/// Push-to-Mac action (step 7) will add a second button here that
/// posts an `ActionRequest` CKRecord the Mac syncer consumes.
struct EntryDetailView: View {
    @Environment(AppContainer.self) private var container
    let entryId: Int64

    @State private var loaded: Loaded?
    @State private var copyToastVisible: Bool = false

    struct Loaded {
        var entry: Entry
        var thumbLarge: Data?
        var appName: String?
        var deviceName: String?
        var flavorCount: Int
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let l = loaded {
                    header(l)
                    Divider()
                    body(of: l)
                    Divider()
                    metadata(l)
                } else {
                    ProgressView().frame(maxWidth: .infinity)
                }
            }
            .padding()
        }
        .navigationTitle(loaded?.entry.title?.prefix(40).description ?? "Entry")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    copyToClipboard()
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .disabled(loaded == nil)
                .accessibilityLabel("Copy to clipboard")
            }
        }
        .overlay(alignment: .top) {
            if copyToastVisible {
                Text("Copied")
                    .font(.callout)
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .task(id: entryId) {
            await load()
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private func header(_ l: Loaded) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(l.entry.title ?? "(untitled)")
                .font(.title3)
                .lineLimit(3)
            HStack(spacing: 6) {
                Text(l.entry.kind.rawValue.capitalized)
                    .font(.caption2)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.thinMaterial, in: Capsule())
                Text(Self.formatDate(l.entry.createdAt))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func body(of l: Loaded) -> some View {
        switch l.entry.kind {
        case .image:
            #if canImport(UIKit)
            if let data = l.thumbLarge, let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            } else {
                placeholderText(l)
            }
            #else
            placeholderText(l)
            #endif
        default:
            placeholderText(l)
        }
    }

    @ViewBuilder
    private func placeholderText(_ l: Loaded) -> some View {
        if let preview = l.entry.textPreview, !preview.isEmpty {
            Text(preview)
                .font(.system(size: 14, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text("(no preview)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func metadata(_ l: Loaded) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let device = l.deviceName {
                metaRow("Captured on", device)
            }
            if let app = l.appName {
                metaRow("From app", app)
            }
            metaRow("Flavors", "\(l.flavorCount)")
            metaRow("Total size", formatBytes(l.entry.totalSize))
            if let ocr = l.entry.ocrText, !ocr.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("OCR").font(.caption).foregroundStyle(.secondary)
                    Text(ocr).font(.caption).textSelection(.enabled)
                }
            }
            if let tags = l.entry.imageTags, !tags.isEmpty {
                metaRow("Tags", tags)
            }
        }
    }

    private func metaRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 90, alignment: .leading)
            Text(value)
                .font(.caption)
                .textSelection(.enabled)
            Spacer()
        }
    }

    // MARK: - Actions

    private func load() async {
        guard let store = container.store else { return }
        let id = entryId
        do {
            let result = try await store.dbQueue.read { db -> Loaded? in
                guard let entry = try Entry.fetchOne(db, key: id) else { return nil }
                let appName = try entry.sourceAppId.flatMap { appId in
                    try AppRecord.fetchOne(db, key: appId)?.name
                }
                let deviceName = try Device.fetchOne(db, key: entry.sourceDeviceId)?.name
                let thumbLarge = try Data.fetchOne(
                    db,
                    sql: "SELECT thumb_large FROM previews WHERE entry_id = ?",
                    arguments: [id]
                )
                let flavorCount = try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM entry_flavors WHERE entry_id = ?",
                    arguments: [id]
                ) ?? 0
                return Loaded(
                    entry: entry,
                    thumbLarge: thumbLarge,
                    appName: appName,
                    deviceName: deviceName,
                    flavorCount: flavorCount
                )
            }
            self.loaded = result
        } catch {
            // Silent — the parent list view already handles the
            // "nothing to show" case with ContentUnavailableView.
        }
    }

    private func copyToClipboard() {
        #if canImport(UIKit)
        guard let store = container.store, let l = loaded else { return }
        let id = entryId
        Task {
            do {
                let text = try await store.dbQueue.read { db -> String? in
                    // Prefer plain-text flavor; fall back to
                    // textPreview for now. Full multi-flavor paste
                    // goes on UIPasteboard in a later pass — for
                    // iOS v1 a text copy is usually what the user
                    // wants.
                    let row = try Flavor
                        .filter(Column("entry_id") == id)
                        .filter(Column("uti") == "public.utf8-plain-text")
                        .fetchOne(db)
                    if let row = row {
                        if let inline = row.data {
                            return String(data: inline, encoding: .utf8)
                        }
                        if let key = row.blobKey {
                            let spilled = try Data(contentsOf: Paths.blobPath(forSHA256Hex: key))
                            return String(data: spilled, encoding: .utf8)
                        }
                    }
                    return l.entry.textPreview
                }
                if let text = text {
                    await MainActor.run {
                        UIPasteboard.general.string = text
                        showCopyToast()
                    }
                }
            } catch {
                // Fall through silently
            }
        }
        #endif
    }

    private func showCopyToast() {
        withAnimation(.easeOut(duration: 0.15)) {
            copyToastVisible = true
        }
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            withAnimation(.easeIn(duration: 0.2)) {
                copyToastVisible = false
            }
        }
    }

    // MARK: - Formatting

    private static func formatDate(_ t: Double) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: Date(timeIntervalSince1970: t))
    }

    private func formatBytes(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }
}
#endif
