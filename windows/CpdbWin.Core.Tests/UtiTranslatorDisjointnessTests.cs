using CpdbWin.Core.Capture;
using Xunit;

namespace CpdbWin.Core.Tests;

/// <summary>
/// Pins the structural invariant the v2 fallback rung relies on: no UTI the
/// Windows clipboard translator can ever emit appears in
/// <see cref="ContentIdentity.VolatileExact"/> or matches any
/// <see cref="ContentIdentity.VolatilePrefixes"/>. Mac enforces the same
/// invariant via its pasteboard-format allowlist; Windows enforces it here.
///
/// <para>
/// If this test ever fires, two things have diverged: a new emission was
/// added to <see cref="UtiTranslator"/> without updating its
/// <see cref="UtiTranslator.EmittedUtis"/> set, OR the volatile denylist
/// grew to include something the translator already produces. Both are
/// design conversations, not auto-fixable.
/// </para>
/// </summary>
public class UtiTranslatorDisjointnessTests
{
    [Fact]
    public void EmittedUtisAreDisjointFromVolatileDenylist()
    {
        var collisions = new List<string>();
        foreach (var uti in UtiTranslator.EmittedUtis)
        {
            if (ContentIdentity.IsVolatile(uti))
                collisions.Add(uti);
        }
        Assert.True(collisions.Count == 0,
            "UtiTranslator emits a UTI listed in ContentIdentity.VolatileExact "
          + "or matching VolatilePrefixes: " + string.Join(", ", collisions));
    }

    [Theory]
    [InlineData("public.utf8-plain-text")]
    [InlineData("public.png")]
    [InlineData("public.jpeg")]
    [InlineData("public.url")]
    [InlineData("public.html")]
    [InlineData("public.file-url")]
    public void EachEmittedUtiIsExplicitlyAllowed(string uti)
    {
        Assert.Contains(uti, UtiTranslator.EmittedUtis);
        Assert.False(ContentIdentity.IsVolatile(uti),
            $"{uti} would be filtered out of the fallback rung — denylist hit.");
    }
}
