import Testing
@testable import CpdbCore

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
        #expect(Paths.databaseURL.lastPathComponent == "cpdb.db")
        #expect(Paths.databaseURL.deletingLastPathComponent() == Paths.supportDirectory)
    }
}
