using System.Text;
using CpdbWin.Core.Capture;
using CpdbWin.Core.Ingest;
using CpdbWin.Core.Store;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

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
        if (e.ClickedItem is not EntryViewModel vm) return;
        if (TryWriteFlavorByPriority(vm.EntryId))
            StatusText.Text = $"Copied #{vm.EntryId} to clipboard";
    }

    private bool TryWriteFlavorByPriority(long entryId)
    {
        // Priority order matches what users typically want to paste.
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

    public static EntryViewModel From(EntryRow row) => new()
    {
        EntryId = row.Id,
        Title   = row.Title ?? KindLabel(row.Kind),
        Subtitle = $"{row.AppName ?? "?"} · {FormatTime(row.CreatedAt)} · {row.Kind}",
    };

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
