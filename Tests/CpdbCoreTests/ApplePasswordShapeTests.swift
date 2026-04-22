import Testing
import Foundation
@testable import CpdbCore
@testable import CpdbShared

@Suite("Apple Strong Password shape")
struct ApplePasswordShapeTests {

    /// Build a snapshot containing a single plain-text flavor.
    private func snapshotWithText(_ s: String) -> PasteboardSnapshot {
        let flavor = CanonicalHash.Flavor(
            uti: "public.utf8-plain-text",
            data: Data(s.utf8)
        )
        return PasteboardSnapshot(items: [.init(flavors: [flavor])])
    }

    @Test(
        "Real Apple-generated strong passwords match",
        arguments: [
            "jymzot-6nedto-Xyzcyz",
            "rYthup-suqvek-9jypqu",
            "vidre2-poKded-dotgix",
            "cuvfer-2cinho-wyHson",
            "gadjU5-zebsow-foqnyz",
            "hetzuc-menro2-qagCeh",
        ]
    )
    func realPasswordsMatch(_ password: String) {
        #expect(snapshotWithText(password).looksLikeApplePassword)
    }

    @Test(
        "Non-password strings that could be near the shape don't match",
        arguments: [
            "",                              // empty
            "hello",                         // too short
            "Mean Well LRS-350-5",           // has spaces
            "abcdef-ghijkl",                 // only 2 groups
            "abcdef-ghijkl-mnopqr-stuvwx",   // 4 groups
            "abcde-fghij-klmno",             // 5-char groups, not 6
            "abcdef_ghijkl_mnopqr",          // underscores
            "abcdef-ghijkl-mnopq",           // 6-6-5
            "4crazy_kangaroo_Margaret",      // Apple memorable format (intentionally not matched)
            "123e4567-e89b-12d3-a456-426614174000", // UUID
        ]
    )
    func nonPasswordsDoNotMatch(_ text: String) {
        #expect(!snapshotWithText(text).looksLikeApplePassword)
    }

    @Test("Password with surrounding whitespace still matches")
    func trimsWhitespace() {
        #expect(snapshotWithText("  jymzot-6nedto-Xyzcyz\n").looksLikeApplePassword)
    }

    @Test("Non-ASCII chars inside the groups don't match")
    func nonAsciiDoesNotMatch() {
        // Cyrillic 'а' looks like ASCII 'a' but isn't — must not match.
        #expect(!snapshotWithText("аymzot-6nedto-Xyzcyz").looksLikeApplePassword)
    }
}
