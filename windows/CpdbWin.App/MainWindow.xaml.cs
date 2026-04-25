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

    public MainWindow(AppHost host)
    {
        InitializeComponent();
        Title = "cpdb-win";
        _host = host;
        _host.Capture.Ingested += OnCaptureIngested;
        _host.Capture.Errored += OnCaptureErrored;

        // Closing the X button hides the window instead of exiting the app
        // — capture must keep running. Use the tray menu's Quit to actually
        // shut down.
        this.Closed += (_, e) =>
        {
            e.Handled = true;
            AppWindow.Hide();
        };

        // Whenever the window is shown, focus the search box so keyboard
        // users can type-to-filter without grabbing the mouse.
        this.Activated += (_, _) =>
        {
            SearchBox.Focus(FocusState.Programmatic);
            SearchBox.SelectAll();
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
        EntryList.ItemsSource = rows.Select(EntryViewModel.From).ToList();
    }

    private void SearchBox_TextChanged(object sender, TextChangedEventArgs e) => Refresh();

    private void EntryList_ItemClick(object sender, ItemClickEventArgs e)
    {
        if (e.ClickedItem is EntryViewModel vm) ActivateEntry(vm);
    }

    private void EntryList_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (EntryList.SelectedItem is EntryViewModel vm) ShowDetail(vm);
        else                                             ShowDetailEmpty();
    }

    private void ShowDetailEmpty()
    {
        DetailEmpty.Visibility       = Visibility.Visible;
        DetailTextScroll.Visibility  = Visibility.Collapsed;
        DetailImage.Visibility       = Visibility.Collapsed;
        DetailImage.Source           = null;
    }

    private void ShowDetail(EntryViewModel vm)
    {
        DetailEmpty.Visibility = Visibility.Collapsed;

        // Image entries first — show the larger preview if we have one.
        var thumb = _host.Entries.GetThumbLarge(vm.EntryId);
        if (thumb is not null)
        {
            DetailImage.Source = LoadBitmap(thumb);
            DetailImage.Visibility      = Visibility.Visible;
            DetailTextScroll.Visibility = Visibility.Collapsed;
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

    private void SearchBox_KeyDown(object sender, KeyRoutedEventArgs e)
    {
        switch (e.Key)
        {
            case VirtualKey.Down:
                if (EntryList.Items.Count > 0)
                {
                    if (EntryList.SelectedIndex < 0) EntryList.SelectedIndex = 0;
                    ((ListViewItem?)EntryList.ContainerFromIndex(EntryList.SelectedIndex))?.Focus(FocusState.Keyboard);
                }
                e.Handled = true;
                break;
            case VirtualKey.Enter:
                var idx = EntryList.SelectedIndex >= 0 ? EntryList.SelectedIndex : 0;
                if (EntryList.Items.Count > idx && EntryList.Items[idx] is EntryViewModel vm)
                    ActivateEntry(vm);
                e.Handled = true;
                break;
            case VirtualKey.Escape:
                if (!string.IsNullOrEmpty(SearchBox.Text)) SearchBox.Text = "";
                else AppWindow.Hide();
                e.Handled = true;
                break;
        }
    }

    private void EntryList_KeyDown(object sender, KeyRoutedEventArgs e)
    {
        switch (e.Key)
        {
            case VirtualKey.Enter:
                if (EntryList.SelectedItem is EntryViewModel vm)
                {
                    ActivateEntry(vm);
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
