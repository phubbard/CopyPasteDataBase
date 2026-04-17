import Testing
import Foundation
@testable import CpdbCore

@Suite("Paste.db transformable decoder")
struct TransformableDecoderTests {
    /// Path to the user's Paste.db. The tests are skipped (not failed) if
    /// Paste isn't installed — useful for running the suite on a clean
    /// machine or in CI.
    static let pasteDbURL: URL = {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent("Library/Application Support/com.wiheads.paste", isDirectory: true)
            .appendingPathComponent("Paste.db", isDirectory: false)
    }()

    static var pasteInstalled: Bool {
        FileManager.default.fileExists(atPath: pasteDbURL.path)
    }

    static let externalDir = TransformablePasteboardDecoder
        .externalDataDirectory(forPasteDatabase: pasteDbURL)

    @Test("Inline rows (text/link/color) decode to at least one UTI and some bytes",
          .enabled(if: pasteInstalled))
    func decodesInlineRows() throws {
        let decoder = TransformablePasteboardDecoder(externalDataDirectory: Self.externalDir)
        let reader = try PasteCoreDataReader(databaseURL: Self.pasteDbURL)

        // Z_ENT: 7=Color, 10=Link, 11=Text — these are usually inline.
        for ent in [7, 10, 11] {
            let blobs = try reader.sampleBlobs(forEntity: ent, limit: 3)
            #expect(!blobs.isEmpty, "expected at least one blob for Z_ENT=\(ent)")
            for blob in blobs {
                let items = try decoder.decode(blob)
                #expect(!items.isEmpty)
                let totalFlavors = items.reduce(0) { $0 + $1.flavors.count }
                #expect(totalFlavors > 0)
                // Every flavor must have a non-empty UTI.
                for item in items {
                    for flavor in item.flavors {
                        #expect(!flavor.uti.isEmpty)
                    }
                }
            }
        }
    }

    @Test("Externally-stored rows resolve via .Paste_SUPPORT",
          .enabled(if: pasteInstalled))
    func decodesExternalRows() throws {
        let decoder = TransformablePasteboardDecoder(externalDataDirectory: Self.externalDir)
        let reader = try PasteCoreDataReader(databaseURL: Self.pasteDbURL)

        // Core Data's "Allows External Storage" writes a 0x02-prefixed row
        // regardless of the snippet kind — spills happen by size, not type.
        let blobs = try reader.sampleBlobs(withLeadingByte: 0x02, limit: 5)
        #expect(!blobs.isEmpty, "expected some external-storage rows in Paste.db")

        for blob in blobs {
            #expect(blob.first == 0x02)
            let items = try decoder.decode(blob)
            #expect(!items.isEmpty)
            let totalBytes = items.reduce(0) { sum, item in
                sum + item.flavors.reduce(0) { $0 + $1.data.count }
            }
            #expect(totalBytes > 0)
        }
    }

    @Test("Round-trip: decode → canonical hash is stable",
          .enabled(if: pasteInstalled))
    func canonicalHashIsStable() throws {
        let decoder = TransformablePasteboardDecoder(externalDataDirectory: Self.externalDir)
        let reader = try PasteCoreDataReader(databaseURL: Self.pasteDbURL)
        let blob = try reader.sampleBlobs(forEntity: 11, limit: 1).first!
        let items1 = try decoder.decode(blob)
        let items2 = try decoder.decode(blob)
        let h1 = CanonicalHash.hash(items: items1.map(\.flavors))
        let h2 = CanonicalHash.hash(items: items2.map(\.flavors))
        #expect(h1 == h2)
        #expect(h1.count == 32)
    }
}
