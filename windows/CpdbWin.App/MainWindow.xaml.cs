using System.Runtime.InteropServices;
using System.Text;
using CpdbWin.Core;
using CpdbWin.Core.Capture;
using CpdbWin.Core.Ingest;
using CpdbWin.Core.Store;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Windows.Storage.Streams;
using Windows.System;

namespace CpdbWin.App;

public sealed partial class MainWindow : Window
{
    private readonly AppHost _host;
    /// <summary>Anchor for Shift+arrow extension when typing in the search box.</summary>
    private int _shiftAnchor = -1;
    /// <summary>
    /// Keyboard-cursor position for nav from the search box. Decoupled from
    /// <see cref="ListView.SelectedIndex"/> because that property collapses
    /// to the first selected item once a range is selected, which would
    /// trap repeated Shift+Down at length 2.
    /// </summary>
    private int _cursorIndex = -1;

    [DllImport("user32.dll")] private static extern short GetKeyState(int vKey);
    private const int VK_SHIFT   = 0x10;
    private const int VK_CONTROL = 0x11;
    private static bool IsShiftDown() => (GetKeyState(VK_SHIFT)   & 0x8000) != 0;
    private static bool IsCtrlDown()  => (GetKeyState(VK_CONTROL) & 0x8000) != 0;

    public MainWindow(AppHost host)
    {
        InitializeComponent();
        Title = CpdbVersion.Full;
        _host = host;
        _host.Capture.Ingested += OnCaptureIngested;
        _host.Capture.Errored += OnCaptureErrored;
        // Live-refresh as the link-metadata backfill loop fills in titles.
        // Each Settle/Bump fires once per row; we coalesce by debouncing
        // on the dispatcher rather than re-querying per-row.
        _host.LinkBackfill.RowSettled += OnLinkBackfillSettled;

        // Use AddHandler with handledEventsToo so we still see KeyDown after
        // TextBox / ListView mark it handled internally (Delete in TextBox
        // is the immediate offender — its built-in handler can swallow it
        // before the routed XAML attribute path fires).
        SearchBox.AddHandler(UIElement.KeyDownEvent,
            new KeyEventHandler(SearchBox_KeyDown), handledEventsToo: true);
        EntryList.AddHandler(UIElement.KeyDownEvent,
            new KeyEventHandler(EntryList_KeyDown), handledEventsToo: true);

        // Closing the X button hides the window instead of exiting the app
        // — capture must keep running. Use the tray menu's Quit to actually
        // shut down.
        this.Closed += (_, e) =>
        {
            e.Handled = true;
            AppWindow.Hide();
        };

        // Whenever the window is shown, focus the search box so keyboard
        // users can type-to-filter without grabbing the mouse, and reset
        // the keyboard cursor / shift anchor so a stale state from a
        // previous session doesn't surface.
        //
        // Activated fires for both activation AND deactivation — gate on
        // WindowActivationState so we don't churn focus when the user
        // tabs away. Use FocusState.Keyboard rather than .Programmatic
        // so the OS-level focus actually takes (Programmatic doesn't
        // raise the focus visuals or always grab keyboard input on a
        // first show), and queue a second Focus() onto the dispatcher to
        // catch the case where the window's HWND focus transition hasn't
        // settled by the time Activated runs (typical when shown from
        // tray click / WM_HOTKEY).
        this.Activated += (_, args) =>
        {
            if (args.WindowActivationState == WindowActivationState.Deactivated) return;
            FocusSearchBox();
            DispatcherQueue.TryEnqueue(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low,
                FocusSearchBox);
            _cursorIndex = -1;
            _shiftAnchor = -1;
        };

        Refresh();
    }

    private void FocusSearchBox()
    {
        SearchBox.Focus(FocusState.Keyboard);
        SearchBox.SelectAll();
    }

    private void OnCaptureIngested(object? sender, IngestOutcome outcome)
    {
        DispatcherQueue.TryEnqueue(() =>
        {
            StatusText.Text = outcome.Kind switch
            {
                IngestKind.Inserted => $"Captured #{outcome.EntryId}",
                IngestKind.Bumped   => $"Re-copied #{outcome.EntryId}",
                IngestKind.Skipped  => $"Skipped — {outcome.Reason}",
                _                   => StatusText.Text,
            };
            if (outcome.Kind != IngestKind.Skipped) Refresh();
        });
    }

    private void OnCaptureErrored(object? sender, Exception ex)
    {
        DispatcherQueue.TryEnqueue(() =>
        {
            StatusText.Text = $"Capture error: {ex.Message}";
        });
    }

    private void OnLinkBackfillSettled(object? sender, CpdbWin.Core.Analysis.LinkBackfillSettledEventArgs e)
    {
        // Refresh the list whenever a row gets its title (or its retry
        // counter bumped — the kind=link badge stays the same but a fresh
        // status line helps diagnose the loop running). Marshalled onto
        // the dispatcher because the backfill cycle runs on a Timer /
        // ThreadPool thread.
        DispatcherQueue.TryEnqueue(() =>
        {
            if (!e.Transient && e.Title is not null)
            {
                StatusText.Text = $"Fetched title for #{e.EntryId}";
            }
            Refresh();
        });
    }

    private void Refresh()
    {
        // Guard against the InitializeComponent firing path: when XAML
        // applies SelectedIndex="0" to the KindFilter ComboBox during
        // base ctor, SelectionChanged runs before _host has been assigned
        // by our constructor. Without this null check we'd dereference
        // _host and bubble a NullReferenceException out through XAML
        // parsing as a XamlParseException 0x802B000A.
        if (_host is null) return;

        // Preserve multi-selection across refreshes — clipboard events can
        // fire between user keystrokes; without this, Down → capture-Refresh
        // → Delete would no-op because the selection reset to empty.
        var prevSelectedIds = EntryList.SelectedItems
            .OfType<EntryViewModel>()
            .Select(v => v.EntryId)
            .ToHashSet();

        var query = SearchBox.Text;
        var kind = CurrentKindFilter();
        IReadOnlyList<EntryRow> rows;
        try
        {
            rows = string.IsNullOrWhiteSpace(query)
                ? _host.Entries.Recent(kind: kind)
                : _host.Entries.Search(query.Trim() + "*", kind: kind);
        }
        catch
        {
            // Bad FTS5 query (e.g. unbalanced quotes) — fall back to Recent
            // rather than blanking the list.
            rows = _host.Entries.Recent(kind: kind);
        }
        var vms = rows.Select(EntryViewModel.From).ToList();
        EntryList.ItemsSource = vms;

        if (prevSelectedIds.Count > 0)
        {
            foreach (var vm in vms)
                if (prevSelectedIds.Contains(vm.EntryId))
                    EntryList.SelectedItems.Add(vm);
        }
        // Anchor the cursor on the most recent selection survivor so a
        // post-refresh Shift+arrow extends from a sensible spot.
        _cursorIndex = vms.Count == 0 ? -1 : EntryList.SelectedIndex;

        UpdateFooter(shown: vms.Count);
    }

    private void UpdateFooter(int shown)
    {
        if (_host is null) return;
        var kind = CurrentKindFilter();
        long total;
        try { total = _host.Entries.LiveCount(kind: kind); }
        catch { total = shown; }

        string countLabel = string.IsNullOrWhiteSpace(SearchBox.Text) || total == shown
            ? $"{total} {(total == 1 ? "entry" : "entries")}"
            : $"{shown} of {total}";

        FooterText.Text = $"{countLabel} · {CpdbVersion.Full}";
    }

    private string? CurrentKindFilter()
    {
        if (KindFilter is null) return null;
        if (KindFilter.SelectedItem is ComboBoxItem item
            && item.Tag is string s
            && !string.IsNullOrEmpty(s))
            return s;
        return null;
    }

    private void KindFilter_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        // Reset cursor / anchor on filter change — the rows are about to
        // change shape so any previously valid index is suspect.
        _cursorIndex = -1;
        _shiftAnchor = -1;
        Refresh();
    }

    private void SearchBox_TextChanged(object sender, TextChangedEventArgs e) => Refresh();

    private void EntryList_ItemClick(object sender, ItemClickEventArgs e)
    {
        if (e.ClickedItem is not EntryViewModel vm) return;
        int idx = EntryList.Items.IndexOf(vm);
        if (idx < 0) return;

        // IsItemClickEnabled fires ItemClick on every click — including
        // Shift- and Ctrl-modified ones — and suppresses the framework's
        // default selection-extension. Drive the multi-select gestures
        // ourselves, and only activate (paste-back + hide) on a plain click.
        if (IsShiftDown())
        {
            if (_shiftAnchor < 0) _shiftAnchor = idx;
            ExtendSelection(_shiftAnchor, idx);
            _cursorIndex = idx;
            return;
        }
        if (IsCtrlDown())
        {
            if (EntryList.SelectedItems.Contains(vm))
                EntryList.SelectedItems.Remove(vm);
            else
                EntryList.SelectedItems.Add(vm);
            _shiftAnchor = idx;
            _cursorIndex = idx;
            return;
        }

        _shiftAnchor = idx;
        _cursorIndex = idx;
        ActivateEntry(vm);
    }

    private void EntryList_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        var n = EntryList.SelectedItems.Count;
        if (n == 0)                                                     ShowDetailEmpty();
        else if (n == 1 && EntryList.SelectedItem is EntryViewModel vm) ShowDetail(vm);
        else                                                            ShowDetailMulti(n);
    }

    private void ShowDetailMulti(int count)
    {
        DetailEmpty.Text = $"{count} entries selected · press Delete to remove";
        DetailEmpty.Visibility       = Visibility.Visible;
        DetailTextScroll.Visibility  = Visibility.Collapsed;
        DetailImage.Visibility       = Visibility.Collapsed;
        DetailImage.Source           = null;
        DetailLinkScroll.Visibility  = Visibility.Collapsed;
        DetailLinkImage.Source       = null;
        ResetMeta();
    }

    private void ShowDetailEmpty()
    {
        DetailEmpty.Text             = "Select an entry to preview";
        DetailEmpty.Visibility       = Visibility.Visible;
        DetailTextScroll.Visibility  = Visibility.Collapsed;
        DetailImage.Visibility       = Visibility.Collapsed;
        DetailImage.Source           = null;
        DetailLinkScroll.Visibility  = Visibility.Collapsed;
        DetailLinkImage.Source       = null;
        ResetMeta();
    }

    private void ResetMeta()
    {
        DetailMeta.Visibility       = Visibility.Collapsed;
        DetailSourceUrl.Visibility  = Visibility.Collapsed;
        DetailPageUrl.Visibility    = Visibility.Collapsed;
        DetailHtmlNote.Visibility   = Visibility.Collapsed;
    }

    private void ShowDetail(EntryViewModel vm)
    {
        DetailEmpty.Visibility = Visibility.Collapsed;
        ResetMeta();

        // Always-collapse the layouts we're not using; the branches below
        // make the right one visible.
        DetailLinkScroll.Visibility = Visibility.Collapsed;
        DetailLinkImage.Source      = null;

        // Pull a fresh row so we can route on kind + read the fetched
        // link_title and the original URL (text_preview).
        var row = FindRow(vm.EntryId);

        // kind=link — title on top, thumbnail in the middle, URL at the
        // bottom (clickable HyperlinkButton). The thumbnail is the
        // og:image / favicon fetched by Stage D's TryAttachThumbnailAsync
        // and stored in the previews table.
        if (row is { Kind: "link" } linkRow)
        {
            ShowLinkDetail(linkRow);
            return;
        }

        // Image entries — show the larger preview if we have one.
        var thumb = _host.Entries.GetThumbLarge(vm.EntryId);
        if (thumb is not null)
        {
            DetailImage.Source = LoadBitmap(thumb);
            DetailImage.Visibility      = Visibility.Visible;
            DetailTextScroll.Visibility = Visibility.Collapsed;
            // Browsers ride a source URL + HTML snippet alongside the image
            // bytes — surface them so the user can chase the original.
            ShowMetadata(vm.EntryId, includeImageMetadata: true);
            return;
        }

        // Text-shaped flavors next.
        foreach (var uti in new[] { "public.utf8-plain-text", "public.url", "public.html" })
        {
            var bytes = _host.Entries.GetFlavorBytes(vm.EntryId, uti);
            if (bytes is null) continue;
            DetailText.Text = Encoding.UTF8.GetString(bytes);
            DetailTextScroll.Visibility = Visibility.Visible;
            DetailImage.Visibility      = Visibility.Collapsed;
            DetailImage.Source          = null;
            return;
        }

        DetailText.Text = "(no preview available)";
        DetailTextScroll.Visibility = Visibility.Visible;
        DetailImage.Visibility      = Visibility.Collapsed;
    }

    private void ShowLinkDetail(EntryRow row)
    {
        // Title — prefer the fetched link_title, fall back to the captured
        // first-line title (typically the URL itself when no fetch yet).
        var title = !string.IsNullOrWhiteSpace(row.LinkTitle)
            ? row.LinkTitle!
            : (row.Title ?? row.TextPreview ?? "(untitled link)");
        DetailLinkTitle.Text = title;

        // Thumbnail — fed by the Stage D fetcher (og:image → twitter:image
        // → Wikipedia REST API → favicon). May be null if the fetch hasn't
        // run yet, was 4xx-blocked, or returned no decodable bytes.
        var thumb = _host.Entries.GetThumbLarge(row.Id);
        if (thumb is not null)
        {
            DetailLinkImage.Source     = LoadBitmap(thumb);
            DetailLinkImage.Visibility = Visibility.Visible;
        }
        else
        {
            DetailLinkImage.Source     = null;
            DetailLinkImage.Visibility = Visibility.Collapsed;
        }

        // URL — clickable HyperlinkButton at the bottom.
        var url = row.TextPreview ?? row.Title ?? "";
        DetailLinkUrl.Content = url;
        if (Uri.TryCreate(url, UriKind.Absolute, out var u)
            && (u.Scheme == "http" || u.Scheme == "https"))
        {
            DetailLinkUrl.NavigateUri = u;
            DetailLinkUrl.Visibility  = Visibility.Visible;
        }
        else
        {
            DetailLinkUrl.NavigateUri = null;
            // Still show the text — non-clickable — so the URL string is
            // at least readable.
            DetailLinkUrl.Visibility  = string.IsNullOrEmpty(url)
                ? Visibility.Collapsed
                : Visibility.Visible;
        }

        DetailLinkScroll.Visibility = Visibility.Visible;
        DetailTextScroll.Visibility = Visibility.Collapsed;
        DetailImage.Visibility      = Visibility.Collapsed;
        DetailImage.Source          = null;
    }

    /// <summary>
    /// Pull the freshest <see cref="EntryRow"/> for an entry id from the
    /// repository. Used by the detail pane to read fields the
    /// <see cref="EntryViewModel"/> doesn't surface (kind, link_title,
    /// text_preview).
    /// </summary>
    private EntryRow? FindRow(long entryId)
    {
        // Repository doesn't expose a by-id getter; piggyback on Recent.
        // The list is small (capped at 100) and the lookup is rare (only
        // on selection change), so the linear scan is fine.
        foreach (var r in _host.Entries.Recent(limit: 200))
        {
            if (r.Id == entryId) return r;
        }
        return null;
    }

    private void ShowMetadata(long entryId, bool includeImageMetadata)
    {
        bool any = false;

        if (includeImageMetadata)
        {
            // public.url for image entries is the image's direct URL
            // (UniformResourceLocatorW from Chromium / Firefox).
            var url = _host.Entries.GetFlavorBytes(entryId, "public.url");
            if (url is not null)
            {
                var s = Encoding.UTF8.GetString(url).Trim();
                if (s.Length > 0)
                {
                    DetailSourceUrl.Content = "Image: " + s;
                    if (Uri.TryCreate(s, UriKind.Absolute, out var u)) DetailSourceUrl.NavigateUri = u;
                    DetailSourceUrl.Visibility = Visibility.Visible;
                    any = true;
                }
            }

            var html = _host.Entries.GetFlavorBytes(entryId, "public.html");
            if (html is not null)
            {
                var s = Encoding.UTF8.GetString(html).Trim();
                if (s.Length > 0)
                {
                    DetailHtmlNote.Text = s.Length > 200 ? s[..200] + "…" : s;
                    DetailHtmlNote.Visibility = Visibility.Visible;
                    any = true;
                }
            }
        }

        DetailMeta.Visibility = any ? Visibility.Visible : Visibility.Collapsed;
    }

    private static BitmapImage? LoadBitmap(byte[] bytes)
    {
        try
        {
            var img = new BitmapImage();
            var stream = new InMemoryRandomAccessStream();
            using (var writer = new DataWriter(stream))
            {
                writer.WriteBytes(bytes);
                writer.StoreAsync().AsTask().GetAwaiter().GetResult();
                writer.DetachStream();
            }
            stream.Seek(0);
            img.SetSource(stream);
            return img;
        }
        catch { return null; }
    }

    private const int KeyPageSize = 8;

    private void SearchBox_KeyDown(object sender, KeyRoutedEventArgs e)
    {
        int count = EntryList.Items.Count;
        // Read from our own cursor first; fall back to SelectedIndex for the
        // initial Down-from-no-selection case.
        int sel = _cursorIndex >= 0 ? _cursorIndex : EntryList.SelectedIndex;
        int newSel = sel;

        switch (e.Key)
        {
            case VirtualKey.Down:
                if (count == 0) { e.Handled = true; return; }
                newSel = sel < 0 ? 0 : Math.Min(sel + 1, count - 1);
                e.Handled = true;
                break;
            case VirtualKey.Up:
                if (count == 0) { e.Handled = true; return; }
                newSel = sel <= 0 ? 0 : sel - 1;
                e.Handled = true;
                break;
            case VirtualKey.PageDown:
                if (count == 0) { e.Handled = true; return; }
                newSel = sel < 0 ? 0 : Math.Min(sel + KeyPageSize, count - 1);
                e.Handled = true;
                break;
            case VirtualKey.PageUp:
                if (count == 0) { e.Handled = true; return; }
                newSel = sel <= 0 ? 0 : Math.Max(sel - KeyPageSize, 0);
                e.Handled = true;
                break;
            case VirtualKey.Home:
                if (count == 0) { e.Handled = true; return; }
                newSel = 0;
                e.Handled = true;
                break;
            case VirtualKey.End:
                if (count == 0) { e.Handled = true; return; }
                newSel = count - 1;
                e.Handled = true;
                break;
            case VirtualKey.Enter:
                if (EntryList.SelectedItems.Count == 1
                    && EntryList.SelectedItem is EntryViewModel vm)
                    ActivateEntry(vm);
                else if (sel < 0 && count > 0 && EntryList.Items[0] is EntryViewModel first)
                    ActivateEntry(first);
                e.Handled = true;
                return;
            case VirtualKey.Delete:
                if (EntryList.SelectedItems.Count > 0)
                {
                    DeleteSelectedEntries();
                    e.Handled = true;
                }
                return;
            case VirtualKey.Escape:
                if (!string.IsNullOrEmpty(SearchBox.Text)) SearchBox.Text = "";
                else AppWindow.Hide();
                e.Handled = true;
                return;
            default:
                _shiftAnchor = -1;  // any non-nav key resets the anchor
                return;
        }

        if (newSel < 0 || newSel >= count) return;

        if (IsShiftDown())
        {
            // Shift held — extend the selection from the anchor (set on the
            // first shift-arrow) to the new cursor.
            if (_shiftAnchor < 0) _shiftAnchor = sel < 0 ? newSel : sel;
            ExtendSelection(_shiftAnchor, newSel);
        }
        else
        {
            // Plain navigation — single-select and reset the anchor.
            _shiftAnchor = -1;
            EntryList.SelectedIndex = newSel;
        }
        _cursorIndex = newSel;
        EntryList.ScrollIntoView(EntryList.Items[newSel]);
    }

    private void ExtendSelection(int anchor, int cursor)
    {
        int min = Math.Min(anchor, cursor);
        int max = Math.Max(anchor, cursor);

        EntryList.SelectedItems.Clear();
        for (int i = min; i <= max; i++)
            EntryList.SelectedItems.Add(EntryList.Items[i]);
    }

    private void EntryList_KeyDown(object sender, KeyRoutedEventArgs e)
    {
        switch (e.Key)
        {
            case VirtualKey.Enter:
                // Only activate single selection — multi-select Enter is a
                // no-op (avoids accidentally pasting one of N).
                if (EntryList.SelectedItems.Count == 1
                    && EntryList.SelectedItem is EntryViewModel vm)
                {
                    ActivateEntry(vm);
                    e.Handled = true;
                }
                break;
            case VirtualKey.Delete:
                if (EntryList.SelectedItems.Count > 0)
                {
                    DeleteSelectedEntries();
                    e.Handled = true;
                }
                break;
            case VirtualKey.Escape:
                if (!string.IsNullOrEmpty(SearchBox.Text)) SearchBox.Text = "";
                SearchBox.Focus(FocusState.Keyboard);
                e.Handled = true;
                break;
        }
    }

    private void DeleteMenuItem_Click(object sender, RoutedEventArgs e)
    {
        // If the right-clicked row is part of a multi-selection, delete all
        // of them; otherwise just the row that was clicked. This matches
        // Explorer's behaviour for "Delete" on a contextual flyout.
        if (sender is FrameworkElement fe && fe.DataContext is EntryViewModel vm)
        {
            if (EntryList.SelectedItems.Contains(vm) && EntryList.SelectedItems.Count > 1)
                DeleteSelectedEntries();
            else
                DeleteEntries(new[] { vm });
        }
    }

    private void PinMenuItem_Click(object sender, RoutedEventArgs e)
    {
        if (sender is not FrameworkElement fe || fe.DataContext is not EntryViewModel vm) return;

        // If the row is part of a multi-selection, toggle every selected
        // row to the same target state (the inverse of the clicked row's
        // current state) — same shape as multi-delete.
        var newState = !vm.Pinned;
        IReadOnlyList<EntryViewModel> targets =
            EntryList.SelectedItems.Contains(vm) && EntryList.SelectedItems.Count > 1
                ? EntryList.SelectedItems.OfType<EntryViewModel>().ToList()
                : new[] { vm };

        foreach (var t in targets) _host.Entries.SetPinned(t.EntryId, newState);
        StatusText.Text = targets.Count == 1
            ? $"{(newState ? "Pinned" : "Unpinned")} #{targets[0].EntryId}"
            : $"{(newState ? "Pinned" : "Unpinned")} {targets.Count} entries";
        Refresh();
    }

    private void DeleteSelectedEntries()
    {
        var vms = EntryList.SelectedItems.OfType<EntryViewModel>().ToList();
        if (vms.Count == 0) return;
        DeleteEntries(vms);
    }

    private void DeleteEntries(IReadOnlyList<EntryViewModel> vms)
    {
        if (vms.Count == 0) return;
        _host.Entries.TombstoneMany(vms.Select(v => v.EntryId));
        StatusText.Text = vms.Count == 1
            ? $"Deleted #{vms[0].EntryId}"
            : $"Deleted {vms.Count} entries";
        ShowDetailEmpty();
        _shiftAnchor = -1;
        _cursorIndex = -1;
        Refresh();
    }

    private void ActivateEntry(EntryViewModel vm)
    {
        if (TryWriteFlavorByPriority(vm.EntryId))
        {
            StatusText.Text = $"Copied #{vm.EntryId} to clipboard";
            // Hide our window AND send Ctrl+V to the app that held the
            // foreground when we were summoned, so the user gets a single-
            // gesture experience: hotkey → arrow → Enter → text appears in
            // the original app. App layer owns the foreground capture/restore
            // because that's where the show-window event also lives.
            App.HideAndPasteToPreviousForeground(this);
        }
    }

    private bool TryWriteFlavorByPriority(long entryId)
    {
        var text = _host.Entries.GetFlavorBytes(entryId, "public.utf8-plain-text");
        if (text is not null)
        {
            ClipboardWriter.WriteText(Encoding.UTF8.GetString(text));
            return true;
        }
        foreach (var uti in new[] { "public.url", "public.png", "public.jpeg" })
        {
            var bytes = _host.Entries.GetFlavorBytes(entryId, uti);
            if (bytes is null) continue;
            ClipboardWriter.Write(new[] { (uti, bytes) });
            return true;
        }
        return false;
    }
}

public sealed class EntryViewModel
{
    public long EntryId { get; init; }
    public string Title { get; init; } = "";
    public string Subtitle { get; init; } = "";
    public ImageSource? Thumbnail { get; init; }
    public bool Pinned { get; init; }

    /// <summary>Visible when the entry is pinned — drives the row glyph.</summary>
    public Visibility PinGlyphVisibility => Pinned ? Visibility.Visible : Visibility.Collapsed;

    /// <summary>Label for the right-click toggle: "Pin" when unpinned, "Unpin" when pinned.</summary>
    public string PinMenuLabel => Pinned ? "Unpin" : "Pin";

    public static EntryViewModel From(EntryRow row) => new()
    {
        EntryId   = row.Id,
        // Title resolution preference for link rows:
        //   1. fetched link_title (e.g. "The New York Times - Breaking News…")
        //   2. the captured plain-text title (typically the URL itself)
        //   3. kind label as a last resort.
        // For non-link rows, link_title is always null so the chain
        // collapses to the original behavior.
        Title     = NonEmpty(row.LinkTitle) ?? row.Title ?? KindLabel(row.Kind),
        // Subtitle picks up the URL when we have a real fetched title,
        // so the row still surfaces "where it came from".
        Subtitle  = BuildSubtitle(row),
        Thumbnail = ThumbnailFrom(row.ThumbSmall),
        Pinned    = row.Pinned,
    };

    private static string BuildSubtitle(EntryRow row)
    {
        var meta = $"{row.AppName ?? "?"} · {FormatTime(row.CreatedAt)} · {row.Kind}";
        // Link row with a fetched title — show the URL as breadcrumb so
        // the user still knows where the title came from.
        if (row.Kind == "link"
            && !string.IsNullOrEmpty(row.LinkTitle)
            && !string.IsNullOrEmpty(row.TextPreview))
        {
            return $"{row.TextPreview} · {meta}";
        }
        return meta;
    }

    private static string? NonEmpty(string? s) =>
        string.IsNullOrWhiteSpace(s) ? null : s;

    private static ImageSource? ThumbnailFrom(byte[]? bytes)
    {
        if (bytes is null || bytes.Length == 0) return null;
        try
        {
            var img = new BitmapImage();
            var stream = new InMemoryRandomAccessStream();
            using (var writer = new DataWriter(stream))
            {
                writer.WriteBytes(bytes);
                writer.StoreAsync().AsTask().GetAwaiter().GetResult();
                writer.DetachStream();
            }
            stream.Seek(0);
            img.SetSource(stream);
            return img;
        }
        catch
        {
            return null;
        }
    }

    private static string KindLabel(string kind) => kind switch
    {
        "image" => "[image]",
        "file"  => "[file]",
        "color" => "[color]",
        _       => $"[{kind}]",
    };

    private static string FormatTime(double unix) =>
        DateTimeOffset.FromUnixTimeSeconds((long)unix).LocalDateTime.ToString("g");
}
