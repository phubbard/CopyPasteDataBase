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
    @State private var showPushSheet: Bool = false

    struct Loaded {
        var entry: Entry
        var thumbLarge: Data?
        var appName: String?
        var deviceName: String?
        var flavorCount: Int
        /// For link-kind entries: the URL string resolved from the
        /// title / textPreview / public.url / public.utf8-plain-text
        /// flavor chain. Nil for non-link kinds.
        var linkURL: String?
        /// Pre-resolved payload for the toolbar's ShareLink. Uses
        /// a per-entry temp file for image and text data so the
        /// share sheet receives a typed UTI, not a generic string.
        /// Nil while we're still deciding / nothing shareable.
        var sharePayload: SharePayload?
    }

    /// Discriminated union of what we can hand to `ShareLink`.
    /// Swift's Transferable requires a concrete type per share
    /// item; this enum lets the view pick the right `ShareLink`
    /// variant at render time.
    ///
    /// Image payloads used to be a file URL in /tmp, but iOS's
    /// Launch Services can't resolve file URLs without a
    /// file-provider domain — AirDrop and most share extensions
    /// bailed with OSStatus -10814. Carrying the raw Data and
    /// rendering a SwiftUI Image into ShareLink's Transferable
    /// path routes through the image-data pipeline instead and
    /// works everywhere.
    enum SharePayload {
        case text(String)
        case url(URL)
        case image(Data)
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
                HStack(spacing: 16) {
                    Button {
                        showPushSheet = true
                    } label: {
                        Image(systemName: "desktopcomputer.and.arrow.down")
                    }
                    .disabled(loaded == nil)
                    .accessibilityLabel("Push to Mac")

                    if let payload = loaded?.sharePayload {
                        shareButton(payload)
                    }
                    Button {
                        copyToClipboard()
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .disabled(loaded == nil)
                    .accessibilityLabel("Copy to clipboard")
                }
            }
        }
        .sheet(isPresented: $showPushSheet) {
            if let entry = loaded?.entry {
                DevicePickerSheet(entry: entry)
                    .presentationDetents([.medium, .large])
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
        case .link:
            linkBody(l)
        default:
            // Text-like entries. Some apps (Zen, some browsers,
            // shell output with URLs pasted) ship URLs as plain
            // text with no `public.url` flavor — the Mac classifies
            // these as kind=text. Detect the case and upgrade the
            // display:
            //   1. Entire preview IS a single URL → use the
            //      boxed-link UI (same as kind=.link).
            //   2. Preview CONTAINS URLs → AttributedString with
            //      NSDataDetector-marked ranges, tappable inline.
            if let preview = l.entry.textPreview,
               let single = Self.cleanURL(from: preview.trimmingCharacters(in: .whitespacesAndNewlines)),
               Self.isWholeStringAURL(preview)
            {
                linkBody(l, overrideURL: single)
            } else {
                richTextBody(l)
            }
        }
    }

    /// Link-kind body. Renders the URL as a tappable `Link` that
    /// opens in Safari/default handler. Falls back to text if the
    /// URL didn't resolve. `overrideURL` is used when a text-kind
    /// entry turned out to be a bare URL (Zen et al.), so the
    /// caller can pass the already-parsed URL and skip the
    /// `l.linkURL` lookup (which is nil for non-link kinds).
    @ViewBuilder
    private func linkBody(_ l: Loaded, overrideURL: URL? = nil) -> some View {
        let url: URL? = overrideURL ?? l.linkURL.flatMap(Self.cleanURL(from:))
        let urlString: String? = overrideURL?.absoluteString ?? l.linkURL
        if let url = url, let urlString = urlString {
            VStack(alignment: .leading, spacing: 10) {
                Link(destination: url) {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "safari")
                            .foregroundStyle(.tint)
                            .font(.system(size: 15))
                            .padding(.top, 2)
                        Text(urlString)
                            .font(.system(size: 14))
                            .foregroundStyle(.tint)
                            .underline()
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(.thinMaterial)
                    )
                }
                .buttonStyle(.plain)
                if let preview = l.entry.textPreview,
                   !preview.isEmpty,
                   preview != urlString,
                   preview.trimmingCharacters(in: .whitespacesAndNewlines) != urlString
                {
                    Text(preview)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
            }
        } else {
            placeholderText(l)
        }
    }

    /// Text body with inline URL autolinking. Runs NSDataDetector
    /// over the preview and marks any matched URL ranges as
    /// Attributed `.link` — `Text(AttributedString)` renders those
    /// as tappable. Falls back to plain text when no preview.
    @ViewBuilder
    private func richTextBody(_ l: Loaded) -> some View {
        if let preview = l.entry.textPreview, !preview.isEmpty {
            Text(Self.linkify(preview))
                .font(.system(size: 14, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text("(no preview)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Returns true when the trimmed string is exactly one URL
    /// (no trailing/leading text). Used by body(of:) to decide
    /// whether to promote a text-kind entry to the boxed-link UI.
    private static func isWholeStringAURL(_ s: String) -> Bool {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.contains(where: { $0.isWhitespace || $0.isNewline })
        else {
            return false
        }
        return cleanURL(from: trimmed) != nil
    }

    /// Wrap raw text in an AttributedString with URL ranges marked
    /// so SwiftUI's `Text` renders them as tappable links. Non-URL
    /// content passes through as plain attributed text.
    private static func linkify(_ s: String) -> AttributedString {
        var attr = AttributedString(s)
        guard let detector = try? NSDataDetector(
            types: NSTextCheckingResult.CheckingType.link.rawValue
        ) else { return attr }
        let ns = s as NSString
        let full = NSRange(location: 0, length: ns.length)
        detector.enumerateMatches(in: s, options: [], range: full) { match, _, _ in
            guard let match = match,
                  let url = match.url,
                  let stringRange = Range(match.range, in: s),
                  let attrRange = Range(stringRange, in: attr)
            else { return }
            attr[attrRange].link = url
            attr[attrRange].foregroundColor = .accentColor
            attr[attrRange].underlineStyle = .single
        }
        return attr
    }

    /// ShareLink variant chosen per payload kind. Using `ShareLink`
    /// (iOS 16+) instead of `UIActivityViewController` keeps us
    /// inside SwiftUI and gets us the native share-sheet layout
    /// for free.
    @ViewBuilder
    private func shareButton(_ payload: SharePayload) -> some View {
        switch payload {
        case .text(let s):
            ShareLink(item: s) {
                Image(systemName: "square.and.arrow.up")
            }
            .accessibilityLabel("Share")
        case .url(let u):
            ShareLink(item: u) {
                Image(systemName: "square.and.arrow.up")
            }
            .accessibilityLabel("Share")
        case .image(let data):
            #if canImport(UIKit)
            if let uiImage = UIImage(data: data) {
                let swiftUIImage = Image(uiImage: uiImage)
                ShareLink(
                    item: swiftUIImage,
                    preview: SharePreview("Image", image: swiftUIImage)
                ) {
                    Image(systemName: "square.and.arrow.up")
                }
                .accessibilityLabel("Share")
            } else {
                EmptyView()
            }
            #else
            EmptyView()
            #endif
        }
    }

    /// Best-effort URL parse. Accepts trailing whitespace, trims
    /// zero-width chars, adds a scheme if missing (so `example.com`
    /// becomes `https://example.com`). Returns nil for garbage.
    private static func cleanURL(from raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let url = URL(string: trimmed), url.scheme != nil { return url }
        // Schemeless common case — prepend https and try again.
        if let url = URL(string: "https://\(trimmed)"), url.host != nil {
            return url
        }
        return nil
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
            var result = try await store.dbQueue.read { db -> Loaded? in
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

                // Resolve a link URL for link-kind entries. Same
                // lookup chain as SearchView's list-row path.
                var linkURL: String? = nil
                if entry.kind == .link {
                    linkURL = entry.title?.isEmpty == false ? entry.title : nil
                    if linkURL == nil || linkURL?.isEmpty == true {
                        linkURL = entry.textPreview?.isEmpty == false ? entry.textPreview : nil
                    }
                    if linkURL == nil {
                        for uti in ["public.url", "public.utf8-plain-text"] {
                            if let data = try Data.fetchOne(
                                db,
                                sql: "SELECT data FROM entry_flavors WHERE entry_id = ? AND uti = ? LIMIT 1",
                                arguments: [id, uti]
                            ) {
                                linkURL = String(data: data, encoding: .utf8)?
                                    .trimmingCharacters(in: .whitespacesAndNewlines)
                                if linkURL != nil { break }
                            }
                        }
                    }
                }

                return Loaded(
                    entry: entry,
                    thumbLarge: thumbLarge,
                    appName: appName,
                    deviceName: deviceName,
                    flavorCount: flavorCount,
                    linkURL: linkURL,
                    sharePayload: nil
                )
            }

            // Resolve share payload AFTER the main load so the UI
            // can show the detail immediately — the share button
            // fades in when the payload is ready.
            if let load = result {
                result?.sharePayload = await resolveSharePayload(for: load, store: store)
            }
            self.loaded = result
        } catch {
            // Silent — the parent list view already handles the
            // "nothing to show" case with ContentUnavailableView.
        }
    }

    /// Build the most app-meaningful share item we can for this
    /// entry. Text entries share their text; link entries share
    /// their URL; image entries share a temp JPEG so receiving
    /// apps recognize it as an image. Fallback: the entry's
    /// text_preview as a string.
    private func resolveSharePayload(
        for l: Loaded, store: Store
    ) async -> SharePayload? {
        switch l.entry.kind {
        case .link:
            if let s = l.linkURL, let u = Self.cleanURL(from: s) {
                return .url(u)
            }
            return l.entry.textPreview.map { .text($0) }
        case .image:
            #if canImport(UIKit)
            // Prefer the original image flavor so we share full
            // resolution, not the 640px thumbnail. Return the raw
            // bytes — the ShareLink branch renders a SwiftUI
            // Image from them so Launch Services doesn't need to
            // resolve a file URL.
            let id = l.entry.id!
            let data: Data? = try? await store.dbQueue.read { db in
                for uti in ["public.png", "public.jpeg", "public.heic", "public.tiff"] {
                    let row = try Flavor
                        .filter(Column("entry_id") == id)
                        .filter(Column("uti") == uti)
                        .fetchOne(db)
                    if let row = row {
                        if let inline = row.data { return inline }
                        if let key = row.blobKey {
                            return try Data(contentsOf: Paths.blobPath(forSHA256Hex: key))
                        }
                    }
                }
                return nil
            }
            if let bytes = data ?? l.thumbLarge {
                return .image(bytes)
            }
            return nil
            #else
            return nil
            #endif
        default:
            // Text / file / color / other → share textPreview.
            // File kinds carrying a file:// URL in text would
            // naturally open the file-share panel on the receiver.
            if let s = l.entry.textPreview, !s.isEmpty {
                return .text(s)
            }
            return nil
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
