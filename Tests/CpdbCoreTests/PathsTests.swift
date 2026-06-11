import Testing
@testable import CpdbCore
@testable import CpdbShared

@Suite("Paths")
struct PathsTests {
    @Test("Blob paths use two-level fanout")
    func blobPathFanout() {
        let hex = "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789"
        let url = Paths.blobPath(forSHA256Hex: hex)
        #expect(url.lastPathComponent == hex)
        #expect(url.deletingLastPathComponent().lastPathComponent == "cd")
        #expect(url.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == "ab")
    }

    @Test("databaseURL lives under supportDirectory")
    func databaseLocation() {
        // "-v3" is the canonical-hash-v2 binary-skew fence: pre-v10
        // binaries look for cpdb.db and find nothing. The rename is
        // performed once by Paths.migrateToV3DatabaseFilenameIfNeeded().
        #expect(Paths.databaseURL.lastPathComponent == "cpdb-v3.db")
        #expect(Paths.preV3DatabaseURL.lastPathComponent == "cpdb.db")
        #expect(Paths.databaseURL.deletingLastPathComponent() == Paths.supportDirectory)
    }
}
