using System.Runtime.InteropServices;
using System.Text;
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
        Title = "cpdb-win";
        _host = host;
        _host.Capture.Ingested += OnCaptureIngested;
        _host.Capture.Errored += OnCaptureErrored;

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
        this.Activated += (_, _) =>
        {
            SearchBox.Focus(FocusState.Programmatic);
            SearchBox.SelectAll();
            _cursorIndex = -1;
            _shiftAnchor = -1;
        };

        Refresh();
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

    private void Refresh()
    {
        // Preserve multi-selection across refreshes — clipboard events can
        // fire between user keystrokes; without this, Down → capture-Refresh
        // → Delete would no-op because the selection reset to empty.
        var prevSelectedIds = EntryList.SelectedItems
            .OfType<EntryViewModel>()
            .Select(v => v.EntryId)
            .ToHashSet();

        var query = SearchBox.Text;
        IReadOnlyList<EntryRow> rows;
        try
        {
            rows = string.IsNullOrWhiteSpace(query)
                ? _host.Entries.Recent()
                : _host.Entries.Search(query.Trim() + "*");  // prefix match
        }
        catch
        {
            // Bad FTS5 query (e.g. unbalanced quotes) — fall back to Recent
            // rather than blanking the list.
            rows = _host.Entries.Recent();
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
        ResetMeta();
    }

    private void ShowDetailEmpty()
    {
        DetailEmpty.Text             = "Select an entry to preview";
        DetailEmpty.Visibility       = Visibility.Visible;
        DetailTextScroll.Visibility  = Visibility.Collapsed;
        DetailImage.Visibility       = Visibility.Collapsed;
        DetailImage.Source           = null;
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

        // Image entries first — show the larger preview if we have one.
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
            // Hide so the previous app reactivates and the user can paste
            // immediately. Re-show via tray click or Ctrl+Shift+V.
            AppWindow.Hide();
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

    public static EntryViewModel From(EntryRow row) => new()
    {
        EntryId   = row.Id,
        Title     = row.Title ?? KindLabel(row.Kind),
        Subtitle  = $"{row.AppName ?? "?"} · {FormatTime(row.CreatedAt)} · {row.Kind}",
        Thumbnail = ThumbnailFrom(row.ThumbSmall),
    };

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
