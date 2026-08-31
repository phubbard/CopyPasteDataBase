using CpdbWin.Core;
using CpdbWin.Core.Store;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media.Imaging;
using Windows.System;

namespace CpdbWin.App;

/// <summary>
/// Windows analog of macOS's Quick Look preview (v1.3 <c>QLPreviewPanel</c>).
/// Floating full-size image window opened via <b>Space</b> (when the
/// search box is empty) or <b>Ctrl+Y</b> on a selected image row.
/// Escape or Space dismisses.
///
/// <para>
/// <b>v1 scope</b>: image entries only. Text / link / color / file
/// rows no-op (the right-hand detail pane in <see cref="MainWindow"/>
/// already renders text at reasonable size, and the popup shows
/// link + color previews natively). Mac's <c>QuickLookItemBuilder</c>
/// covers those too via temp-file handoff, but the actual UX value
/// on Windows is much lower — the inline pane already suffices.
/// </para>
///
/// <para>
/// <b>Byte source</b>: prefers <c>public.png</c>, falls back through
/// <c>public.jpeg</c>, then <c>public.tiff</c>. Falls back to the
/// row's thumbnail if the raw bytes were body-evicted (v1.50) — the
/// preview is degraded but non-empty, which beats an unexpected
/// black window. Loaded via <see cref="MainWindow.LoadBitmap"/> so
/// the streaming pattern (InMemoryRandomAccessStream +
/// ConditionalWeakTable pin) matches the inline preview path
/// byte-for-byte.
/// </para>
///
/// <para>
/// <b>Lifetime</b>: <see cref="MainWindow"/> caches one instance in
/// <c>_quickLook</c> and clears the reference on <see cref="Window.Closed"/>.
/// Space or Ctrl+Y with a preview already open closes it (toggle
/// semantics, matches Mac); a subsequent invocation on a different
/// row opens a fresh window.
/// </para>
/// </summary>
public sealed partial class QuickLookWindow : Window
{
    /// <summary>Preferred flavor UTIs in fall-off order. PNG first
    /// because that's what Windows capture writes; JPEG for browser
    /// drag-flavor payloads; TIFF for Photoshop / scanner output.</summary>
    private static readonly string[] ImageFlavors = new[]
    {
        "public.png", "public.jpeg", "public.tiff",
    };

    public QuickLookWindow(AppHost host, long entryId)
    {
        InitializeComponent();
        Title = $"{CpdbVersion.Description} — preview #{entryId}";

        // Load the largest flavor we have. If nothing works, fall
        // back to the row's thumbnail (body-evicted rows lose the
        // raw flavor but the thumbnail survives — see v1.50 body-
        // eviction contract).
        byte[]? bytes = null;
        foreach (var uti in ImageFlavors)
        {
            bytes = host.Entries.GetFlavorBytes(entryId, uti);
            if (bytes is { Length: > 0 }) break;
        }
        if (bytes is null || bytes.Length == 0)
            bytes = host.Entries.GetThumbLarge(entryId);

        if (bytes is not null)
            PreviewImage.Source = MainWindow.LoadBitmap(bytes, entryId);

        // Wire keyboard dismiss on the root grid. AddHandler with
        // handledEventsToo so scroller-consumed keys still bubble.
        Root.AddHandler(UIElement.KeyDownEvent,
            new KeyEventHandler(OnKeyDown), handledEventsToo: true);
    }

    private void OnKeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key == VirtualKey.Escape || e.Key == VirtualKey.Space)
        {
            this.Close();
            e.Handled = true;
        }
    }
}
