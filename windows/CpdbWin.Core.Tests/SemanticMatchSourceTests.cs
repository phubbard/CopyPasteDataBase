using CpdbWin.Core.Store;
using Xunit;

namespace CpdbWin.Core.Tests;

/// <summary>
/// Unit-level coverage for the <see cref="MatchSource.Semantic"/> enum
/// value that v1.52 adds. The wiring itself lives in
/// <c>MainWindow.SpawnSemanticRerankAsync</c> (stamps <c>.Semantic</c>
/// on the ViewModel of any row hydrated for the missing-from-FTS
/// set) — a WinUI integration test that touched the dispatcher would
/// need a UI harness we don't ship, so this file pins the pieces the
/// unit layer can hold:
/// <list type="bullet">
///   <item><description>The enum value exists and is distinct from
///     the other four (drift-catcher for a naming-collision or an
///     accidental value-reorder in a future compact).</description></item>
///   <item><description>The SQL classifier never assigns
///     <c>.Semantic</c> — it can only come from the render-layer
///     re-rank path. This mirrors Mac's contract:
///     <c>FtsIndex.MatchSource</c>'s <c>.semantic</c> case is
///     assigned only by <c>AppState</c>, never by the SQL search.</description></item>
///   <item><description>The <see cref="EntryRow.MatchSource"/>
///     field accepts <c>.Semantic</c> via <c>record with</c>
///     mutation — the render-layer stamp uses exactly this shape.</description></item>
/// </list>
/// </summary>
public class SemanticMatchSourceTests
{
    [Fact]
    public void EnumValue_Exists_AndIsDistinct()
    {
        // Belt-and-braces: enum values are recognised by the switch
        // expressions in EntryViewModel.MatchBadge*. If someone
        // reordered the enum for compactness (or removed .Semantic
        // as "unused"), those switches would silently fall through
        // to the default arm and the badge would disappear. This
        // pins the identity of the value; the presence checks below
        // pin its distinctness from Ocr/Tag/Multiple.
        var s = MatchSource.Semantic;
        Assert.NotEqual(MatchSource.Text,     s);
        Assert.NotEqual(MatchSource.Ocr,      s);
        Assert.NotEqual(MatchSource.Tag,      s);
        Assert.NotEqual(MatchSource.Multiple, s);
    }

    [Fact]
    public void ClassifyMatchSource_NeverReturnsSemantic()
    {
        // Contract: the SQL-side classifier can only produce
        // Text/Ocr/Tag/Multiple. .Semantic is reserved for the
        // render-layer semantic re-rank path — an SQL classifier
        // that started returning it would silently reclassify a
        // real OCR hit as "semantic", breaking the UX invariant
        // that .Semantic means "found ONLY by embedding cosine".
        // We spot-check the two branches most likely to have the
        // bug (all-empty and multi-column-hit).

        // Sentinels used are the U+0001/U+0002 pair that highlight()
        // wraps around each matched token.
        const string S = "", E = "";

        // Empty-columns edge (no match anywhere) → Text.
        Assert.NotEqual(MatchSource.Semantic,
            EntryRepository.ClassifyMatchSource("", "", ""));

        // Both OCR + tag hit → Multiple.
        Assert.NotEqual(MatchSource.Semantic,
            EntryRepository.ClassifyMatchSource("", $"{S}x{E}", $"{S}y{E}"));

        // Text-only → Text.
        Assert.NotEqual(MatchSource.Semantic,
            EntryRepository.ClassifyMatchSource($"{S}z{E}", "", ""));
    }

    [Fact]
    public void EntryRow_AcceptsSemanticViaWithMutation()
    {
        // The render-layer wiring uses exactly this shape:
        //   byId[row.Id] = EntryViewModel.From(row with { MatchSource = MatchSource.Semantic });
        // Compilation guarantees the record has the positional
        // init-only property, but runtime pinning here catches a
        // future refactor that swaps the property to a computed one
        // (which `with` would silently no-op on).
        var row = new EntryRow(
            Id: 42,
            Kind: "text",
            Title: "hello",
            TextPreview: "hello world",
            CreatedAt: 1_780_000_000,
            CapturedAt: 1_780_000_000,
            TotalSize: 11,
            AppBundleId: null,
            AppName: null,
            ThumbSmall: null,
            Pinned: false,
            LinkTitle: null,
            HasOcr: false,
            ImageTags: null,
            ChipsJson: null);

        Assert.Null(row.MatchSource);

        var stamped = row with { MatchSource = MatchSource.Semantic };
        Assert.Equal(MatchSource.Semantic, stamped.MatchSource);
        // Original untouched — record semantics preserved.
        Assert.Null(row.MatchSource);
    }
}
