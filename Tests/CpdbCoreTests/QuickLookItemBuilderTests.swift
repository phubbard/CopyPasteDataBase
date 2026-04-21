import Testing
import Foundation
@testable import CpdbCore

@Suite("Quick Look item builder")
struct QuickLookItemBuilderTests {

    /// Minimal 1×1 PNG. Decodes via Image I/O / Vision / Quick Look.
    private static let minimalPNG: Data = {
        // Standard "smallest transparent 1×1 PNG" bytes.
        let base64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII="
        return Data(base64Encoded: base64)!
    }()

    /// Temp dir per test so no cross-contamination.
    private func freshTempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cpdb-qltest-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func seedEntry(
        store: Store,
        kind: EntryKind,
        flavors: [(uti: String, data: Data)],
        title: String? = nil
    ) throws -> Int64 {
        try store.dbQueue.write { db in
            var device = Device(identifier: "TEST", name: "Test", kind: "mac")
            try device.insert(db, onConflict: .ignore)
            let deviceId: Int64
            if let id = device.id {
                deviceId = id
            } else {
                deviceId = try Int64.fetchOne(
                    db,
                    sql: "SELECT id FROM devices WHERE identifier = 'TEST'"
                ) ?? 0
            }
            var uuid = UUID().uuid
            let uuidData = withUnsafeBytes(of: &uuid) { Data($0) }
            var entry = Entry(
                uuid: uuidData,
                createdAt: 1_000_000,
                capturedAt: 1_000_000,
                kind: kind,
                sourceDeviceId: deviceId,
                title: title,
                contentHash: Data((0..<32).map { _ in UInt8.random(in: 0...255) }),
                totalSize: Int64(flavors.reduce(0) { $0 + $1.data.count })
            )
            try entry.insert(db)
            for (uti, data) in flavors {
                var row = Flavor(
                    entryId: entry.id!, uti: uti, size: Int64(data.count),
                    data: data, blobKey: nil
                )
                try row.insert(db)
            }
            return entry.id!
        }
    }

    @Test("text entry → .txt file with exact content")
    func textEntry() throws {
        let store = try Store.inMemory()
        let text = "hello quicklook\nsecond line"
        let id = try seedEntry(
            store: store, kind: .text,
            flavors: [("public.utf8-plain-text", Data(text.utf8))],
            title: "hello quicklook"
        )
        let builder = QuickLookItemBuilder(store: store, tempDir: freshTempDir())
        let url = try #require(try builder.build(entryId: id))
        #expect(url.pathExtension == "txt")
        let written = try String(contentsOf: url, encoding: .utf8)
        #expect(written == text)
    }

    @Test("image entry → file with PNG magic bytes")
    func imageEntry() throws {
        let store = try Store.inMemory()
        let id = try seedEntry(
            store: store, kind: .image,
            flavors: [("public.png", Self.minimalPNG)]
        )
        let builder = QuickLookItemBuilder(store: store, tempDir: freshTempDir())
        let url = try #require(try builder.build(entryId: id))
        #expect(url.pathExtension == "png")
        let head = try Data(contentsOf: url).prefix(8)
        // PNG magic: 89 50 4E 47 0D 0A 1A 0A
        #expect(Array(head) == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    }

    @Test("file entry pointing at an existing file → returns the original URL")
    func fileEntryExists() throws {
        let store = try Store.inMemory()
        // /usr/bin/true exists on every macOS install.
        let fileURL = URL(fileURLWithPath: "/usr/bin/true")
        let id = try seedEntry(
            store: store, kind: .file,
            flavors: [("public.file-url", Data(fileURL.absoluteString.utf8))]
        )
        let builder = QuickLookItemBuilder(store: store, tempDir: freshTempDir())
        let url = try #require(try builder.build(entryId: id))
        #expect(url == fileURL)
    }

    @Test("file entry pointing at a missing file with no fallback → nil")
    func fileEntryMissing() throws {
        let store = try Store.inMemory()
        let gone = URL(fileURLWithPath: "/tmp/cpdb-ql-definitely-not-there-\(UUID().uuidString)")
        let id = try seedEntry(
            store: store, kind: .file,
            flavors: [("public.file-url", Data(gone.absoluteString.utf8))]
        )
        let builder = QuickLookItemBuilder(store: store, tempDir: freshTempDir())
        let url = try builder.build(entryId: id)
        #expect(url == nil)
    }

    @Test("file entry missing + image flavor present → falls back to a PNG temp file")
    func fileEntryImageFallback() throws {
        let store = try Store.inMemory()
        let gone = URL(fileURLWithPath: "/tmp/cpdb-ql-also-gone-\(UUID().uuidString)")
        let id = try seedEntry(
            store: store, kind: .file,
            flavors: [
                ("public.file-url", Data(gone.absoluteString.utf8)),
                ("public.png",      Self.minimalPNG),
            ]
        )
        let builder = QuickLookItemBuilder(store: store, tempDir: freshTempDir())
        let url = try #require(try builder.build(entryId: id))
        #expect(url.pathExtension == "png")
    }

    @Test("link entry → nil (deferred to a later release)")
    func linkReturnsNil() throws {
        let store = try Store.inMemory()
        let id = try seedEntry(
            store: store, kind: .link,
            flavors: [("public.utf8-plain-text", Data("https://example.com".utf8))]
        )
        let builder = QuickLookItemBuilder(store: store, tempDir: freshTempDir())
        #expect(try builder.build(entryId: id) == nil)
    }

    @Test("color entry → nil")
    func colorReturnsNil() throws {
        let store = try Store.inMemory()
        let id = try seedEntry(
            store: store, kind: .color,
            flavors: [("public.utf8-plain-text", Data("#FF3300".utf8))]
        )
        let builder = QuickLookItemBuilder(store: store, tempDir: freshTempDir())
        #expect(try builder.build(entryId: id) == nil)
    }

    @Test("missing entry id throws entryNotFound")
    func missingEntry() throws {
        let store = try Store.inMemory()
        let builder = QuickLookItemBuilder(store: store, tempDir: freshTempDir())
        #expect(throws: QuickLookItemBuilder.BuildError.self) {
            _ = try builder.build(entryId: 999_999)
        }
    }
}
