import Testing
import Foundation
@testable import CpdbCore
@testable import CpdbShared

@Suite("Canonical hash")
struct CanonicalHashTests {
    typealias F = CanonicalHash.Flavor

    @Test("Identical payloads hash equal")
    func identical() {
        let a = CanonicalHash.hash(items: [[F(uti: "public.utf8-plain-text", data: Data("hello".utf8))]])
        let b = CanonicalHash.hash(items: [[F(uti: "public.utf8-plain-text", data: Data("hello".utf8))]])
        #expect(a == b)
    }

    @Test("Different payloads hash differently")
    func different() {
        let a = CanonicalHash.hash(items: [[F(uti: "public.utf8-plain-text", data: Data("hello".utf8))]])
        let b = CanonicalHash.hash(items: [[F(uti: "public.utf8-plain-text", data: Data("world".utf8))]])
        #expect(a != b)
    }

    @Test("Flavor UTI order inside an item is irrelevant")
    func utiOrderIrrelevant() {
        let a = CanonicalHash.hash(items: [[
            F(uti: "public.utf8-plain-text", data: Data("x".utf8)),
            F(uti: "public.rtf",             data: Data("y".utf8)),
        ]])
        let b = CanonicalHash.hash(items: [[
            F(uti: "public.rtf",             data: Data("y".utf8)),
            F(uti: "public.utf8-plain-text", data: Data("x".utf8)),
        ]])
        #expect(a == b)
    }

    @Test("Item order IS relevant (two-item pasteboards are rare but must not collide on shuffle)")
    func itemOrderRelevant() {
        let a = CanonicalHash.hash(items: [
            [F(uti: "public.utf8-plain-text", data: Data("one".utf8))],
            [F(uti: "public.utf8-plain-text", data: Data("two".utf8))],
        ])
        let b = CanonicalHash.hash(items: [
            [F(uti: "public.utf8-plain-text", data: Data("two".utf8))],
            [F(uti: "public.utf8-plain-text", data: Data("one".utf8))],
        ])
        #expect(a != b)
    }

    @Test("Merged item vs split items must not collide ({A,B} vs [{A},{B}])")
    func mergedVsSplitNoCollision() {
        let merged = CanonicalHash.hash(items: [[
            F(uti: "public.a", data: Data([0x01])),
            F(uti: "public.b", data: Data([0x02])),
        ]])
        let split = CanonicalHash.hash(items: [
            [F(uti: "public.a", data: Data([0x01]))],
            [F(uti: "public.b", data: Data([0x02]))],
        ])
        #expect(merged != split)
    }

    @Test("Length prefix prevents boundary collisions")
    func lengthPrefix() {
        // If we didn't length-prefix, these would collide: both produce the same
        // concatenation of UTI bytes + data bytes.
        let a = CanonicalHash.hash(items: [[
            F(uti: "public.text", data: Data("abcdef".utf8)),
        ]])
        let b = CanonicalHash.hash(items: [[
            F(uti: "public.text", data: Data("abc".utf8)),
            F(uti: "public.u",    data: Data("def".utf8)),
        ]])
        #expect(a != b)
    }

    @Test("Output is 32 bytes (SHA-256)")
    func sha256Length() {
        let h = CanonicalHash.hash(items: [[F(uti: "x", data: Data())]])
        #expect(h.count == 32)
    }
}
