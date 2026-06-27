#if os(macOS)
import Testing
import Foundation
import AppKit
import GRDB
@testable import CpdbCore
@testable import CpdbShared

/// Tests for `PasteboardWriter.loadItems` — rebuilding an entry onto the
/// pasteboard. Regression: a URL-only entry (e.g. a Universal Clipboard
/// echo captured as bare `public.url`) wouldn't paste into a text field
/// because there was no `public.utf8-plain-text` flavor.
@Suite("PasteboardWriter — URL-only paste")
struct PasteboardWriterTests {

    private func store() throws -> (Store, Int64) {
        let s = try Store.inMemory()
        let dev = try s.dbQueue.write { db -> Int64 in
            var d = Device(identifier: "d", name: "D", kind: "mac"); try d.insert(db); return d.id!
        }
        return (s, dev)
    }

    @discardableResult
    private func insert(_ store: Store, dev: Int64, byte: UInt8, flavors: [(String, Data)]) throws -> Int64 {
        try store.dbQueue.write { db in
            var e = Entry(uuid: Data(repeating: byte, count: 16), createdAt: 1, capturedAt: 1,
                          kind: .link, sourceDeviceId: dev, textPreview: "x",
                          contentHash: Data(repeating: byte, count: 32),
                          totalSize: Int64(flavors.reduce(0) { $0 + $1.1.count }))
            try e.insert(db)
            for (uti, data) in flavors {
                var f = Flavor(entryId: e.id!, uti: uti, size: Int64(data.count), data: data, blobKey: nil)
                try f.insert(db)
            }
            return e.id!
        }
    }

    @Test("URL-only entry gains a synthesized plain-text flavor")
    func urlOnlySynthesizesText() throws {
        let (store, dev) = try store()
        let url = "https://ultracrepidarian.phfactor.net/2019/09"
        let id = try insert(store, dev: dev, byte: 1, flavors: [("public.url", Data(url.utf8))])
        let writer = PasteboardWriter(store: store)
        let items = try writer.loadItems(entryId: id)
        #expect(items.count == 1)
        let item = items[0]
        // The original URL flavor is still there...
        #expect(item.string(forType: .init("public.url")) == url)
        // ...and a plain-text flavor was synthesized so text fields accept it.
        #expect(item.string(forType: .init("public.utf8-plain-text")) == url)
    }

    @Test("Entry that already has plain text is left untouched (no overwrite)")
    func existingTextPreserved() throws {
        let (store, dev) = try store()
        let id = try insert(store, dev: dev, byte: 2, flavors: [
            ("public.url", Data("https://x.com".utf8)),
            ("public.utf8-plain-text", Data("the link text".utf8)),
        ])
        let writer = PasteboardWriter(store: store)
        let item = try writer.loadItems(entryId: id)[0]
        // The original text is preserved — we don't clobber it with the URL.
        #expect(item.string(forType: .init("public.utf8-plain-text")) == "the link text")
    }

    @Test("Plain-text-only entry is unchanged (no spurious URL synthesis)")
    func plainTextOnlyUnchanged() throws {
        let (store, dev) = try store()
        let id = try insert(store, dev: dev, byte: 3, flavors: [("public.utf8-plain-text", Data("just text".utf8))])
        let writer = PasteboardWriter(store: store)
        let item = try writer.loadItems(entryId: id)[0]
        #expect(item.string(forType: .init("public.utf8-plain-text")) == "just text")
        #expect(item.string(forType: .init("public.url")) == nil)
    }
}
#endif
