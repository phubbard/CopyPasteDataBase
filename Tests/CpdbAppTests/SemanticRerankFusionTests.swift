#if os(macOS)
import Testing
@testable import CpdbApp

/// Determinism + correctness tests for `PopupState.fuseByReciprocalRank`
/// — the pure Reciprocal Rank Fusion merge behind the popup's semantic
/// re-rank. Pure and static, so no `Store`, no loaded embedding model,
/// no `@MainActor` hop needed.
@Suite("Semantic re-rank RRF fusion")
struct SemanticRerankFusionTests {

    @Test("an id appearing in both lists outranks one appearing in only one")
    func idInBothListsOutranksSingleList() {
        // id 1 is #1 in both lists; id 2 is #1 in FTS only; id 3 is #1
        // in semantic only. 1 should win.
        let fused = PopupState.fuseByReciprocalRank([1, 2], [1, 3])
        #expect(fused.first == 1)
    }

    @Test("a #1 rank in one list outranks a mid-pack rank in the other, all else equal")
    func topRankInOneListBeatsMidPackInOther() {
        // id 1: rank 1 in FTS, absent from semantic.
        // id 2: rank 5 in FTS, absent from semantic.
        // 1/(k+1) > 1/(k+5) for any k >= 0, so 1 must rank first.
        let fused = PopupState.fuseByReciprocalRank([1, 91, 92, 93, 2], [])
        #expect(fused.first == 1)
    }

    @Test("union includes ids present in only the semantic list")
    func unionIncludesSemanticOnlyIds() {
        let fused = PopupState.fuseByReciprocalRank([1, 2], [3, 4])
        #expect(Set(fused) == Set([1, 2, 3, 4]))
    }

    @Test("empty semantic list preserves FTS order")
    func emptySemanticListPreservesFtsOrder() {
        let fused = PopupState.fuseByReciprocalRank([10, 20, 30], [])
        #expect(fused == [10, 20, 30])
    }

    @Test("empty FTS list preserves semantic order")
    func emptyFtsListPreservesSemanticOrder() {
        let fused = PopupState.fuseByReciprocalRank([], [10, 20, 30])
        #expect(fused == [10, 20, 30])
    }

    @Test("both lists empty produces an empty result")
    func bothEmptyProducesEmpty() {
        #expect(PopupState.fuseByReciprocalRank([], []).isEmpty)
    }

    @Test("result is deterministic across repeated calls with the same input")
    func deterministicAcrossRepeatedCalls() {
        let ftsIds: [Int64] = [5, 1, 9, 3]
        let semanticIds: [Int64] = [9, 2, 5, 7]
        let first = PopupState.fuseByReciprocalRank(ftsIds, semanticIds)
        for _ in 0..<20 {
            #expect(PopupState.fuseByReciprocalRank(ftsIds, semanticIds) == first)
        }
    }

    @Test("a tie in fused score breaks deterministically on id, not iteration order")
    func tieBreaksDeterministicallyOnId() {
        // Two ids that appear in neither list together and at identical
        // ranks in disjoint single-list appearances tie exactly — both
        // score 1/(k+1). Higher id wins the tie by construction.
        let fused = PopupState.fuseByReciprocalRank([100], [42])
        #expect(fused == [100, 42])
    }

    @Test("changing k does not change relative order for a single-list id")
    func differentKPreservesSingleListOrder() {
        let fusedDefaultK = PopupState.fuseByReciprocalRank([1, 2, 3], [])
        let fusedSmallK = PopupState.fuseByReciprocalRank([1, 2, 3], [], k: 1)
        #expect(fusedDefaultK == [1, 2, 3])
        #expect(fusedSmallK == [1, 2, 3])
    }
}
#endif
