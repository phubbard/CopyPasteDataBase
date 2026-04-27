import XCTest
@testable import CpdbShared

final class HashVectors: XCTestCase {
    func testPinnedVectors() {
        let v1: [[CanonicalHash.Flavor]] = [[
            .init(uti: "public.utf8-plain-text", data: Data("hello".utf8))
        ]]
        XCTAssertEqual(CanonicalHash.hex(CanonicalHash.hash(items: v1)),
            "b22187611777c1e9c84c3fdd054ed311a47d12f33cba6d1e7761bd3a7314073a")

        let v2: [[CanonicalHash.Flavor]] = [[
            .init(uti: "public.utf8-plain-text", data: Data("hello".utf8)),
            .init(uti: "public.html", data: Data("<b>hello</b>".utf8)),
        ]]
        XCTAssertEqual(CanonicalHash.hex(CanonicalHash.hash(items: v2)),
            "17a95cac0686665cfe5342a3a041d7afedfa4c14a59d6d3c6b7b53a4bf0ad85a")
    }
}
