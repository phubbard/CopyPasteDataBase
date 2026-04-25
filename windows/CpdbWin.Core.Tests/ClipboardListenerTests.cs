using CpdbWin.Core.Capture;
using Xunit;

namespace CpdbWin.Core.Tests;

public class ClipboardListenerTests : IDisposable
{
    public void Dispose()
    {
        TestClipboardWriter.Empty();
        ProductionDbCleanup.TombstoneTestEntries();
    }

    [Fact]
    public void Lifecycle_StartAndDispose_IsClean()
    {
        using var listener = new ClipboardListener();
        listener.Start();
        // Dispose runs at end of using scope; the assertion is that the
        // message-loop thread exits without hanging.
    }

    [Fact]
    public void Start_TwiceThrows()
    {
        using var listener = new ClipboardListener();
        listener.Start();
        Assert.Throws<InvalidOperationException>(() => listener.Start());
    }

    [Fact]
    public void Fires_OnClipboardWrite()
    {
        using var listener = new ClipboardListener();
        using var fired = new ManualResetEventSlim(false);
        listener.ClipboardChanged += (_, _) => fired.Set();
        listener.Start();

        TestClipboardWriter.SetUnicodeText($"{ProductionDbCleanup.TestPrefix}listener-{Guid.NewGuid()}");

        Assert.True(fired.Wait(TimeSpan.FromSeconds(2)),
            "WM_CLIPBOARDUPDATE was not delivered within 2s of SetClipboardData.");
    }

    [Fact]
    public void Fires_RepeatedlyForSequentialWrites()
    {
        using var listener = new ClipboardListener();
        var hits = 0;
        using var firstHit = new ManualResetEventSlim(false);
        listener.ClipboardChanged += (_, _) =>
        {
            Interlocked.Increment(ref hits);
            firstHit.Set();
        };
        listener.Start();

        for (int i = 0; i < 3; i++)
        {
            TestClipboardWriter.SetUnicodeText($"{ProductionDbCleanup.TestPrefix}seq-{i}-{Guid.NewGuid()}");
            // Tiny gap so Windows coalesces nothing — back-to-back SetClipboardData
            // can sometimes collapse into a single WM_CLIPBOARDUPDATE.
            Thread.Sleep(50);
        }

        Assert.True(firstHit.Wait(TimeSpan.FromSeconds(2)));
        // Allow the pump a moment to drain the rest.
        Thread.Sleep(200);
        Assert.True(hits >= 3, $"expected at least 3 events, got {hits}");
    }
}
