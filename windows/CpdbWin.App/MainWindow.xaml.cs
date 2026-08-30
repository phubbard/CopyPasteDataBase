using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Text;
using CpdbWin.Core;
using CpdbWin.Core.Analysis;
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

    /// <summary>
    /// Raised when the user clicks the gear button in the top bar. App
    /// wires this to the same OpenPreferences path the tray menu uses —
    /// the in-window button is just a discoverable second entry point so
    /// Preferences isn't hidden behind a tray right-click.
    /// </summary>
    public event Action? SettingsRequested;

    private void SettingsButton_Click(object sender, RoutedEventArgs e)
        => SettingsRequested?.Invoke();

    [DllImport("user32.dll")] private static extern short GetKeyState(int vKey);
    private const int VK_SHIFT = 0x10;
    private static bool IsShiftDown() => (GetKeyState(VK_SHIFT) & 0x8000) != 0;

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
        // OCR settle → re-query so the screenshot is now findable by its
        // recognised text (and any active search re-runs against it).
        _host.ImageAnalysis.RowSettled += OnImageAnalyzed;

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

    private void OnImageAnalyzed(object? sender, CpdbWin.Core.Analysis.ImageAnalyzedEventArgs e)
    {
        DispatcherQueue.TryEnqueue(() =>
        {
            if (!string.IsNullOrEmpty(e.OcrText))
                StatusText.Text = $"OCR'd #{e.EntryId}";
            Refresh();
        });
    }

    /// <summary>
    /// Re-query the list in response to a store change that did NOT go
    /// through the capture pipeline — specifically a GUI URL-import,
    /// which writes via its own worker-thread connection and therefore
    /// never raises <see cref="CaptureService.Ingested"/>. Safe to call
    /// from any thread; marshals onto the UI dispatcher.
    /// </summary>
    public void RequestRefresh() => DispatcherQueue.TryEnqueue(Refresh);

    /// <summary>Monotonic search-generation counter. Every
    /// <see cref="Refresh"/> increments it; async semantic re-rank
    /// tasks captured a value at spawn time and bail if it no longer
    /// matches — protects against a slow embedding query overwriting
    /// a fresher search's results. Mirrors macOS's
    /// <c>spawnSemanticRerank</c> generation guard.</summary>
    private long _searchGeneration;

    private void Refresh()
    {
        // Guard against the InitializeComponent firing path: when XAML
        // applies SelectedIndex="0" to the KindFilter ComboBox during
        // base ctor, SelectionChanged runs before _host has been assigned
        // by our constructor. Without this null check we'd dereference
        // _host and bubble a NullReferenceException out through XAML
        // parsing as a XamlParseException 0x802B000A.
        if (_host is null) return;
        var thisGeneration = Interlocked.Increment(ref _searchGeneration);

        // Standalone refresh-cost measurement, always on (Refresh() runs
        // on ingest, filter change, search typing, and post-mutation — not
        // just summon — so the summon perf line doesn't cover it). Per
        // docs/handoffs/windows-popup-perf.md: keep the instrumentation
        // forever; future regressions surface in log grep instead of a hunch.
        var refreshSw = System.Diagnostics.Stopwatch.StartNew();
        int thumbLoadsBefore = PopupPerf.GlobalThumbLoads;
        long thumbMsBefore   = PopupPerf.GlobalThumbMs;

        // Preserve multi-selection across refreshes — clipboard events can
        // fire between user keystrokes; without this, Down → capture-Refresh
        // → Delete would no-op because the selection reset to empty.
        var prevSelectedIds = EntryList.SelectedItems
            .OfType<EntryViewModel>()
            .Select(v => v.EntryId)
            .ToHashSet();

        var query = SearchBox.Text;
        var kind = CurrentKindFilter();
        var querySw = System.Diagnostics.Stopwatch.StartNew();
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
        querySw.Stop();
        var vmSw = System.Diagnostics.Stopwatch.StartNew();
        var vms = rows.Select(EntryViewModel.From).ToList();
        vmSw.Stop();
        var assignSw = System.Diagnostics.Stopwatch.StartNew();
        EntryList.ItemsSource = vms;
        assignSw.Stop();
        // Independent refresh-perf line — one per Refresh() invocation
        // regardless of trigger, so we can see the constructor-time
        // populate cost, ingest-refresh cost, and filter-change cost
        // separately from the summon path.
        PopupPerf.LogRefresh(
            rows: vms.Count,
            queryMs: querySw.ElapsedMilliseconds,
            vmMs:    vmSw.ElapsedMilliseconds,
            assignMs: assignSw.ElapsedMilliseconds,
            totalMs: refreshSw.ElapsedMilliseconds,
            thumbLoads: PopupPerf.GlobalThumbLoads - thumbLoadsBefore,
            thumbMs:    PopupPerf.GlobalThumbMs    - thumbMsBefore);
        // Attribute this refresh's row count + any thumbnail work to
        // the in-flight summon session (per docs/handoffs/windows-
        // popup-perf.md). No-op when Refresh runs outside a summon
        // (e.g. Ingest events, filter change, search-box typing).
        if (PopupPerf.Current is { } perf)
        {
            perf.RowsShown = vms.Count;
            perf.Stage("refresh");
        }

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

        // Fire the semantic re-rank after FTS has settled. Non-empty
        // query only — an empty search bar shows Recent() and there's
        // nothing to add. Fire-and-forget; the async body marshals
        // back to the UI dispatcher and re-checks the generation
        // counter before touching ItemsSource so a slow embed can't
        // overwrite a fresher search's results. Per
        // docs/handoffs/windows-v33-features.md.
        if (!string.IsNullOrWhiteSpace(query))
        {
            var ftsIds = rows.Select(r => r.Id).ToList();
            _ = SpawnSemanticRerankAsync(query, ftsIds, kind, thisGeneration);
        }
    }

    /// <summary>
    /// Async partner to <see cref="Refresh"/>: embed the query text,
    /// pull the top-K semantic neighbours from
    /// <c>_host.EmbeddingIndex</c>, fuse with the FTS result via
    /// <see cref="HybridRank.Fuse"/>, hydrate any semantic-only
    /// hits, and re-assign <c>ItemsSource</c> in the fused order.
    /// Bails at every await boundary if the generation counter has
    /// moved on (user typed more, cleared the box, changed kind).
    /// </summary>
    private async Task SpawnSemanticRerankAsync(
        string query, List<long> ftsIds, string? kind, long generation)
    {
        if (_host is null) return;
        if (!EmbeddingService.IsAvailable) return;

        // Embed the query on a worker — MiniLM inference isn't fast
        // enough to run on the UI thread and we don't want to jank
        // the SearchBox on every keystroke.
        var queryVector = await Task.Run(() => EmbeddingService.Compute(query)).ConfigureAwait(false);
        if (queryVector is null) return;
        if (Interlocked.Read(ref _searchGeneration) != generation) return;

        var semResults = await _host.EmbeddingIndex.SearchAsync(
            queryVector,
            topK: HybridRank.DefaultSemanticTopK,
            scoreFloor: HybridRank.DefaultSemanticFloor).ConfigureAwait(false);
        if (Interlocked.Read(ref _searchGeneration) != generation) return;

        var semanticIds = semResults.Select(r => r.EntryId).ToList();
        if (semanticIds.Count == 0) return;  // nothing worth adding

        // Identify ids present ONLY on the semantic side — those need
        // hydration to appear in the list.
        var ftsSet = ftsIds.ToHashSet();
        var missingIds = semanticIds.Where(id => !ftsSet.Contains(id)).ToList();

        IReadOnlyList<EntryRow> newRows;
        if (missingIds.Count > 0)
        {
            newRows = await Task.Run(() =>
                _host.Entries.RowsByIds(missingIds, kind)).ConfigureAwait(false);
            if (Interlocked.Read(ref _searchGeneration) != generation) return;
        }
        else
        {
            newRows = Array.Empty<EntryRow>();
        }

        // Fuse via RRF, cap at the popup page size, re-assemble.
        var fusedOrder = HybridRank.Fuse(ftsIds, semanticIds);

        // Marshal back to the UI thread to touch ItemsSource. Final
        // generation check on the UI side — the search box could have
        // moved between the Task.Run above and the dispatcher
        // callback landing.
        DispatcherQueue.TryEnqueue(() =>
        {
            if (_host is null) return;
            if (Interlocked.Read(ref _searchGeneration) != generation) return;

            // Rebuild an id→VM map from the current ItemsSource plus
            // the newly-hydrated semantic-only rows. Reading
            // ItemsSource here (rather than the local `vms`) means we
            // pick up any late clip-ingest that raced with the
            // semantic query — cheap consistency win.
            var currentVms = (EntryList.ItemsSource as IEnumerable<EntryViewModel>)
                             ?? Array.Empty<EntryViewModel>();
            var byId = new Dictionary<long, EntryViewModel>();
            foreach (var vm in currentVms) byId[vm.EntryId] = vm;
            foreach (var row in newRows)
            {
                if (!byId.ContainsKey(row.Id))
                    byId[row.Id] = EntryViewModel.From(row);
            }

            // Preserve current selection so re-ranking doesn't drop the
            // user's highlighted entry.
            var prevSelectedIds = EntryList.SelectedItems
                .OfType<EntryViewModel>()
                .Select(v => v.EntryId)
                .ToHashSet();

            var reordered = fusedOrder
                .Where(id => byId.ContainsKey(id))
                .Select(id => byId[id])
                .Take(100)  // popup page cap — matches Recent()'s default limit
                .ToList();

            // Only reassign when the order actually changed —
            // ItemsSource=... triggers ListView layout + selection
            // churn even when the content is the same.
            if (!SequenceEqualsById(reordered, currentVms))
            {
                EntryList.ItemsSource = reordered;
                if (prevSelectedIds.Count > 0)
                {
                    foreach (var vm in reordered)
                        if (prevSelectedIds.Contains(vm.EntryId))
                            EntryList.SelectedItems.Add(vm);
                }
            }
        });
    }

    private static bool SequenceEqualsById(IReadOnlyList<EntryViewModel> a, IEnumerable<EntryViewModel> b)
    {
        var bList = b as IReadOnlyList<EntryViewModel> ?? b.ToList();
        if (a.Count != bList.Count) return false;
        for (int i = 0; i < a.Count; i++)
            if (a[i].EntryId != bList[i].EntryId) return false;
        return true;
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

    /// <summary>
    /// Double-click = activate (copy to clipboard + hide window +
    /// paste-back to the previously-foreground app). A single click only
    /// selects — the framework's native Extended selection handles plain
    /// / Shift / Ctrl clicks, and <see cref="EntryList_SelectionChanged"/>
    /// drives the preview pane. Enter does the same as double-click (see
    /// the keyboard handlers).
    /// </summary>
    private void EntryList_DoubleTapped(object sender, DoubleTappedRoutedEventArgs e)
    {
        // Resolve the row actually under the pointer so double-clicking
        // an unselected row activates that row, not a stale selection.
        var vm = (e.OriginalSource as FrameworkElement)?.DataContext as EntryViewModel
                 ?? EntryList.SelectedItem as EntryViewModel;
        if (vm is null) return;
        int idx = EntryList.Items.IndexOf(vm);
        if (idx >= 0) { _shiftAnchor = idx; _cursorIndex = idx; }
        ActivateEntry(vm);
    }

    private void EntryList_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        var n = EntryList.SelectedItems.Count;
        if (n == 0)                                                     ShowDetailEmpty();
        else if (n == 1 && EntryList.SelectedItem is EntryViewModel vm) ShowDetail(vm);
        else                                                            ShowDetailMulti(n);
    }

    /// <summary>
    /// Entry id whose OCR text the "Show OCR text" button will fetch on
    /// click. Set in <see cref="ShowImagePreview"/>; cleared by
    /// <see cref="HideImagePreview"/>. We resolve the text lazily so the
    /// list-row projection doesn't carry full OCR strings around.
    /// </summary>
    private long _ocrEntryId = -1;

    /// <summary>
    /// Entry id whose thumb is currently feeding <c>DetailImage</c>.
    /// Stashed by <see cref="ShowImagePreview"/> so the ImageOpened /
    /// ImageFailed handlers can name the row in the diagnostic log.
    /// </summary>
    private long _currentPreviewId = -1;

    private void HideImagePreview()
    {
        DetailImageScroll.Visibility = Visibility.Collapsed;
        DetailImage.Source           = null;
        DetailTagsList.ItemsSource   = null;
        DetailTagsList.Visibility    = Visibility.Collapsed;
        DetailOcrButton.Visibility   = Visibility.Collapsed;
        DetailOcrPanel.Visibility    = Visibility.Collapsed;
        DetailOcrText.Text           = string.Empty;
        _ocrEntryId = -1;
    }

    private void ShowDetailMulti(int count)
    {
        DetailEmpty.Text = $"{count} entries selected · press Delete to remove";
        DetailEmpty.Visibility       = Visibility.Visible;
        DetailTextScroll.Visibility  = Visibility.Collapsed;
        HideImagePreview();
        DetailLinkScroll.Visibility  = Visibility.Collapsed;
        DetailLinkImage.Source       = null;
        ResetMeta();
    }

    private void ShowDetailEmpty()
    {
        DetailEmpty.Text             = "Select an entry to preview";
        DetailEmpty.Visibility       = Visibility.Visible;
        DetailTextScroll.Visibility  = Visibility.Collapsed;
        HideImagePreview();
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

        // Comprehensive reset of every preview layout up front; each
        // branch below only flips its own piece back on. Without this,
        // selecting an image entry (image + OCR button + tag chips
        // visible) then a link entry left those image elements on
        // screen *underneath* the link layout — observed as the link
        // title, the leftover "Show OCR text" button, and stray tag
        // chips all overlapping in the right pane. The other entry
        // points (ShowDetailEmpty / ShowDetailMulti) already do this;
        // this is the missing call site.
        DetailLinkScroll.Visibility = Visibility.Collapsed;
        DetailLinkImage.Source      = null;
        DetailTextScroll.Visibility = Visibility.Collapsed;
        HideImagePreview();

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

        // Image entries — show the larger preview if we have one AND it
        // actually decodes. Decoding upfront (instead of inside
        // ShowImagePreview) lets a corrupt/unsupported thumb_large
        // fall through to the text-flavor branch cleanly: previously a
        // failed decode left DetailImage with a null Source so the
        // right-hand pane went blank above the metadata bar.
        var thumb  = _host.Entries.GetThumbLarge(vm.EntryId);
        bool isImageKind = row?.Kind == "image";
        if (isImageKind)
            LogImagePreview(
                $"ShowDetail   entry={vm.EntryId}  "
              + $"thumb={(thumb is null ? "null" : thumb.Length.ToString())}  "
              + $"hdr={HexHeader(thumb)}");
        var bitmap = thumb is null ? null : LoadBitmap(thumb, vm.EntryId);

        if (bitmap is not null)
        {
            ShowImagePreview(vm, bitmap);
            // Browsers ride a source URL + HTML snippet alongside the
            // image bytes — surface them so the user can chase the
            // original.
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
            HideImagePreview();
            // For an image-kind entry that fell through (no decodable
            // thumb), still show the image-metadata bar so source URL
            // + HTML snippet stay visible — otherwise the previous
            // selection's metadata was the only useful content and
            // even that was misaligned with the now-showing URL above.
            if (isImageKind)
                ShowMetadata(vm.EntryId, includeImageMetadata: true);
            return;
        }

        DetailText.Text = "(no preview available)";
        DetailTextScroll.Visibility = Visibility.Visible;
        HideImagePreview();
        if (isImageKind)
            ShowMetadata(vm.EntryId, includeImageMetadata: true);
    }

    private void ShowImagePreview(EntryViewModel vm, BitmapImage bitmap)
    {
        // Order matters: make the parent visible BEFORE assigning Source.
        // BitmapImage decoding is deferred until the consuming Image is
        // in a visible visual tree; flipping Visibility after assignment
        // races against stream lifetime (see ConditionalWeakTable pin in
        // LoadBitmap — belt-and-braces alongside that fix).
        DetailImageScroll.Visibility = Visibility.Visible;
        // Also restore DetailImage itself — ShowLinkDetail collapses it
        // (to hide the image-kind UI when previewing a link), and never
        // sets it back. Without this, selecting an image entry AFTER a
        // link entry decodes the bitmap (PixelWidth > 0, ImageOpened
        // fires) but the Image control stays Collapsed — silently
        // blank preview. The v1.34.0 healthcheck log caught this:
        // px=400x400 vis=Collapsed/Visible.
        DetailImage.Visibility       = Visibility.Visible;
        DetailTextScroll.Visibility  = Visibility.Collapsed;

        // Diagnostic instrumentation — log the actual ImageOpened /
        // ImageFailed events to image-preview.log. Re-subscribe each
        // selection (- before + so we don't stack handlers when the
        // user clicks through many image rows). Track the current
        // entry id so the log entry says which row.
        _currentPreviewId = vm.EntryId;
        DetailImage.ImageOpened -= OnDetailImageOpened;
        DetailImage.ImageFailed -= OnDetailImageFailed;
        DetailImage.ImageOpened += OnDetailImageOpened;
        DetailImage.ImageFailed += OnDetailImageFailed;

        LogImagePreview($"SetSource    entry={vm.EntryId}  bitmap.PixelWidth-pre={bitmap.PixelWidth}");
        DetailImage.Source = bitmap;

        // Health check: WinUI BitmapImage decode is async; if it never
        // completes (no ImageOpened, no ImageFailed) the preview pane
        // stays blank forever and there's no error to log. Schedule a
        // delayed check that records the bitmap's PixelWidth — if it's
        // still 0 we know decode is stuck. Bail if the user has
        // navigated to a different entry by the time we fire.
        long checkId = vm.EntryId;
        DispatcherQueue.TryEnqueue(
            Microsoft.UI.Dispatching.DispatcherQueuePriority.Low,
            async () =>
            {
                try
                {
                    await System.Threading.Tasks.Task.Delay(750);
                    if (_currentPreviewId != checkId) return;
                    var bi = DetailImage.Source as BitmapImage;
                    int pw = bi?.PixelWidth  ?? -1;
                    int ph = bi?.PixelHeight ?? -1;
                    LogImagePreview(
                        $"healthcheck entry={checkId}  px={pw}x{ph}  "
                      + $"vis={DetailImage.Visibility}/{DetailImageScroll.Visibility}");
                }
                catch (Exception ex)
                {
                    LogImagePreview($"healthcheck entry={checkId}  EXN: {ex.GetType().Name}: {ex.Message}");
                }
            });

        // Classifier tag chips — one Button per top-K label, each
        // wired to filter the list by that tag (TagButton_Click).
        if (vm.Tags.Count > 0)
        {
            DetailTagsList.ItemsSource = vm.Tags;
            DetailTagsList.Visibility  = Visibility.Visible;
        }
        else
        {
            DetailTagsList.ItemsSource = null;
            DetailTagsList.Visibility  = Visibility.Collapsed;
        }

        // OCR button surfaces only when there's actually text to show.
        // Start with the panel collapsed — the user clicks the button to
        // reveal the selectable text (so they can highlight + Ctrl+C a
        // subset of the recognised text).
        DetailOcrPanel.Visibility = Visibility.Collapsed;
        DetailOcrText.Text        = string.Empty;
        if (vm.HasOcr)
        {
            _ocrEntryId = vm.EntryId;
            DetailOcrButton.Content    = "Show OCR text";
            DetailOcrButton.Visibility = Visibility.Visible;
        }
        else
        {
            _ocrEntryId = -1;
            DetailOcrButton.Visibility = Visibility.Collapsed;
        }
    }

    private void OnDetailImageOpened(object sender, RoutedEventArgs e)
    {
        var bi = DetailImage.Source as BitmapImage;
        LogImagePreview(
            $"opened  entry={_currentPreviewId}  "
          + $"px={bi?.PixelWidth ?? 0}x{bi?.PixelHeight ?? 0}");
    }

    private void OnDetailImageFailed(object sender, ExceptionRoutedEventArgs e)
    {
        // Surface but don't propagate — async decode failures fire
        // here AFTER ShowDetail returned, so a sync exception would
        // bubble up to the dispatcher with nothing meaningful to do.
        // The log line is what makes the next blank report
        // diagnosable. Could trigger a retroactive URL fallback in a
        // follow-up if logs show this firing on real entries.
        LogImagePreview(
            $"FAILED  entry={_currentPreviewId}  msg=\"{e.ErrorMessage}\"");
    }

    /// <summary>
    /// A classifier-tag chip was clicked under the image preview —
    /// filter the whole history by that tag. Reset the kind filter to
    /// "All" first so the match isn't accidentally narrowed (the user
    /// asked for "across history", not "across kind=image"). Setting
    /// the search box triggers SearchBox_TextChanged → Refresh; FTS5
    /// matches against text + ocr_text + image_tags + link_title so the
    /// tag word lands every entry it appears in regardless of kind.
    /// </summary>
    private void TagButton_Click(object sender, RoutedEventArgs e)
    {
        if (sender is not Button b || b.Content is not string tag) return;
        if (string.IsNullOrWhiteSpace(tag)) return;
        KindFilter.SelectedIndex = 0;            // "All"
        SearchBox.Text = tag;
        SearchBox.Focus(FocusState.Programmatic);
    }

    /// <summary>
    /// Toggle the OCR text panel under an image preview. Lazy-fetches
    /// the text the first time it's shown for this entry; the
    /// <c>TextBlock</c> has <c>IsTextSelectionEnabled=true</c> so the
    /// user can mouse-select a subset and Ctrl+C it to the clipboard.
    /// </summary>
    private void DetailOcrButton_Click(object sender, RoutedEventArgs e)
    {
        if (_ocrEntryId < 0) return;
        if (DetailOcrPanel.Visibility == Visibility.Visible)
        {
            DetailOcrPanel.Visibility = Visibility.Collapsed;
            DetailOcrButton.Content   = "Show OCR text";
            return;
        }

        if (string.IsNullOrEmpty(DetailOcrText.Text))
        {
            var text = _host.Entries.GetOcrText(_ocrEntryId);
            DetailOcrText.Text = text ?? "(no OCR text)";
        }
        DetailOcrPanel.Visibility = Visibility.Visible;
        DetailOcrButton.Content   = "Hide OCR text";
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

    /// <summary>
    /// Decode <paramref name="bytes"/> into a <see cref="BitmapImage"/>.
    /// Returns <c>null</c> on any synchronous decode failure (corrupt
    /// stream construction, etc.); a deferred decode failure inside
    /// the framework's async pipeline fires <c>ImageFailed</c>
    /// downstream — we deliberately do <b>not</b> await it.
    ///
    /// <para>
    /// <b>Never sync-wait on <c>SetSourceAsync</c> from the UI thread.</b>
    /// v1.28.0 tried <c>SetSourceAsync(...).GetAwaiter().GetResult()</c>
    /// to surface decode failures synchronously; the WinRT
    /// <c>IAsyncAction</c>'s completion callback is marshalled back to
    /// the UI thread, which is blocked in <c>GetResult()</c> — classic
    /// sync-over-async deadlock, observed as a permanently-spinning
    /// mouse cursor the moment any image entry was selected. v1.29.0
    /// reverts to <see cref="BitmapImage.SetSource"/> (synchronous
    /// return, no UI-thread block) and pins the
    /// <see cref="InMemoryRandomAccessStream"/> on the
    /// <see cref="DependencyObject.Tag"/> so it can't be GC'd before
    /// the framework finishes reading it.
    /// </para>
    /// </summary>
    /// <summary>
    /// Pins the backing <see cref="InMemoryRandomAccessStream"/> for
    /// each <see cref="BitmapImage"/> we create. WinUI's
    /// <c>BitmapImage.SetSource</c> returns synchronously but the
    /// actual decode runs later (often deferred until the consuming
    /// <c>Image</c> element enters a visible visual tree). A
    /// method-local stream is eligible for GC the moment
    /// <see cref="LoadBitmap"/> returns — for thumbs whose
    /// <c>Image</c> is inside a <c>Collapsed</c> parent (the preview
    /// pane), the decode trigger fires too late and the stream is
    /// already gone, producing a silently-empty image. Row-card
    /// thumbs were unaffected because their <c>Image</c> is already
    /// in a visible tree and decode runs before GC. Using a
    /// <see cref="ConditionalWeakTable{TKey,TValue}"/> so the stream
    /// is freed automatically when its <c>BitmapImage</c> is collected
    /// — no leak.
    /// </summary>
    private static readonly ConditionalWeakTable<BitmapImage, IRandomAccessStream> _bitmapStreams = new();

    private static BitmapImage? LoadBitmap(byte[] bytes, long entryId = -1)
    {
        try
        {
            var stream = new InMemoryRandomAccessStream();
            using (var writer = new DataWriter(stream))
            {
                writer.WriteBytes(bytes);
                writer.StoreAsync().AsTask().GetAwaiter().GetResult();
                writer.DetachStream();
            }
            stream.Seek(0);
            var img = new BitmapImage();
            _bitmapStreams.AddOrUpdate(img, stream);  // pin for img's lifetime
            img.SetSource(stream);
            if (entryId >= 0)
                LogImagePreview($"LoadBitmap   entry={entryId}  stream.Size={stream.Size}  ok");
            return img;
        }
        catch (Exception ex)
        {
            if (entryId >= 0)
                LogImagePreview($"LoadBitmap   entry={entryId}  EXN: {ex.GetType().Name}: {ex.Message}");
            return null;
        }
    }

    /// <summary>
    /// First 16 bytes of <paramref name="bytes"/> as space-separated hex,
    /// for spotting image magic numbers in the diagnostic log. PNG starts
    /// with <c>89 50 4E 47</c>; JPEG with <c>FF D8 FF</c>; GIF with
    /// <c>47 49 46 38</c>; WEBP has <c>52 49 46 46 .. .. .. .. 57 45 42 50</c>.
    /// If the header doesn't match a format BitmapImage supports, that's
    /// the explanation for a silently-blank preview.
    /// </summary>
    private static string HexHeader(byte[]? bytes)
    {
        if (bytes is null || bytes.Length == 0) return "(empty)";
        int n = Math.Min(16, bytes.Length);
        var sb = new StringBuilder(n * 3);
        for (int i = 0; i < n; i++) sb.Append(bytes[i].ToString("X2")).Append(' ');
        return sb.ToString().TrimEnd();
    }

    /// <summary>
    /// Diagnostic log for the image-preview decode path. v1.27–v1.32
    /// went through several wrong theories about why some thumbs
    /// previewed blank; v1.33 wires the actual answer in. Every
    /// preview now subscribes <c>ImageOpened</c> / <c>ImageFailed</c>
    /// on <c>DetailImage</c> and appends a line here, so the next
    /// blank report has the underlying WinUI error message instead
    /// of needing another guess. Path matches the other diagnostic
    /// logs (<c>update.log</c>, <c>paste-back.log</c>, <c>gc.log</c>).
    /// Self-rotates at 1 MB.
    /// </summary>
    private static void LogImagePreview(string message)
    {
        try
        {
            var path = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "cpdb", "image-preview.log");
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            if (File.Exists(path) && new FileInfo(path).Length > 1_000_000)
                File.WriteAllText(path, $"[{DateTime.Now:yyyy-MM-dd HH:mm:ss}] (rotated)\n");
            File.AppendAllText(path,
                $"[{DateTime.Now:yyyy-MM-dd HH:mm:ss.fff}] {message}\n");
        }
        catch { /* never break the UI for a diag log */ }
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

        // Was the user driving from the search box (type-to-filter +
        // arrow nav, focus stays in the TextBox by design) or directly
        // on the list (clicked a row / used the context menu)? Capture
        // it BEFORE Refresh() — Refresh() replaces ItemsSource, which
        // destroys the focused ListViewItem and bounces keyboard focus
        // back to the search box. If the delete came from the list we
        // must put focus back on the list afterwards, or "press Delete
        // repeatedly to clear rows" dies after the first one.
        bool searchHadFocus = SearchBox.FocusState != FocusState.Unfocused;

        // Where to land after the list shrinks: the position of the
        // topmost deleted row. The row that slides up into that slot
        // becomes the new selection, so repeatedly pressing Delete
        // walks down the list instead of snapping the cursor back to
        // the top every time.
        var deletedIds = vms.Select(v => v.EntryId).ToHashSet();
        int landIndex = EntryList.Items
            .OfType<EntryViewModel>()
            .Select((v, i) => (v, i))
            .Where(t => deletedIds.Contains(t.v.EntryId))
            .Select(t => t.i)
            .DefaultIfEmpty(0)
            .Min();

        _host.Entries.TombstoneMany(vms.Select(v => v.EntryId));
        StatusText.Text = vms.Count == 1
            ? $"Deleted #{vms[0].EntryId}"
            : $"Deleted {vms.Count} entries";
        _shiftAnchor = -1;
        _cursorIndex = -1;
        Refresh();

        // Re-anchor on the row now occupying the deleted slot (or the
        // new last row if the tail was deleted). SelectedIndex raises
        // SelectionChanged, which refreshes the preview pane.
        int count = EntryList.Items.Count;
        if (count == 0)
        {
            ShowDetailEmpty();
            return;
        }
        int newSel = Math.Clamp(landIndex, 0, count - 1);
        EntryList.SelectedIndex = newSel;
        _cursorIndex = newSel;
        EntryList.ScrollIntoView(EntryList.Items[newSel]);

        // List-driven delete: hand keyboard focus back to the freshly
        // selected row so the next Delete keystroke lands on the list,
        // not the search box. Deferred (Low) so the virtualized
        // container for newSel is realized after ScrollIntoView.
        // Search-box-driven delete: leave focus alone — the selection is
        // preserved and SearchBox_KeyDown drives the next Delete, so
        // stealing focus to the list would break type-to-filter.
        if (!searchHadFocus)
        {
            DispatcherQueue.TryEnqueue(
                Microsoft.UI.Dispatching.DispatcherQueuePriority.Low,
                () =>
                {
                    if (EntryList.ContainerFromIndex(newSel) is Control c)
                        c.Focus(FocusState.Keyboard);
                    else
                        EntryList.Focus(FocusState.Keyboard);
                });
        }
    }

    private void ActivateEntry(EntryViewModel vm)
    {
        App.WritePasteLog($"ActivateEntry: id={vm.EntryId}");
        var wrote = TryWriteFlavorByPriority(vm.EntryId);
        App.WritePasteLog($"  TryWriteFlavorByPriority → {wrote}");
        if (wrote)
        {
            StatusText.Text = $"Copied #{vm.EntryId} to clipboard";
            // Hide our window AND send Ctrl+V to the app that held the
            // foreground when we were summoned, so the user gets a single-
            // gesture experience: hotkey → arrow → Enter → text appears in
            // the original app. App layer owns the foreground capture/restore
            // because that's where the show-window event also lives.
            App.HideAndPasteToPreviousForeground(this);
        }
        else
        {
            // Flavor-mismatch is silent otherwise — the user picks an
            // entry, the window doesn't budge, no idea why. Surface it.
            StatusText.Text = $"#{vm.EntryId} has no pasteable flavor";
        }
    }

    /// <summary>
    /// Chip pill clicked in a row's action-chip strip. Resolves the
    /// chip to a URI per its type (see <see cref="ChipActionResolver"/>)
    /// and hands off to the OS via
    /// <see cref="Windows.System.Launcher"/>. Fire-and-forget: a
    /// blocked / unhandled scheme surfaces as a status-bar note
    /// rather than crashing the popup.
    /// </summary>
    private async void ChipButton_Click(object sender, RoutedEventArgs e)
    {
        if (sender is not FrameworkElement fe || fe.Tag is not Chip chip) return;
        var uri = ChipActionResolver.ToUri(chip);
        if (uri is null)
        {
            StatusText.Text = $"No action for chip type '{chip.T}'";
            return;
        }
        try
        {
            var ok = await Windows.System.Launcher.LaunchUriAsync(uri);
            if (!ok) StatusText.Text = $"Could not open {uri.Host}";
        }
        catch (Exception ex)
        {
            StatusText.Text = $"Chip launch failed: {ex.Message}";
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
    public string Tooltip { get; init; } = "";
    public ImageSource? Thumbnail { get; init; }
    public bool Pinned { get; init; }
    /// <summary>True when the entry is a kind=image row whose OCR pass found
    /// text — drives the "OCR" chip on the list row.</summary>
    public bool HasOcr { get; init; }

    /// <summary>
    /// Image-classifier labels for the entry, as a list of individual
    /// tag strings. Empty (not null) for non-image rows or images the
    /// classifier hasn't tagged yet. The preview pane renders each as a
    /// clickable chip that filters the list by that tag.
    /// </summary>
    public IReadOnlyList<string> Tags { get; init; } = Array.Empty<string>();

    /// <summary>
    /// Detected action chips for the entry (dates, phones, tracking
    /// numbers, URLs — see <see cref="Chip"/>). Populated by the
    /// v1.43 <c>ChipBackfillService</c> + capture-wake path; empty
    /// when the row hasn't been scanned yet OR was scanned and no
    /// chips were found (both cases surface as an empty list —
    /// callers checking presence should use <see cref="Chips"/>
    /// count, not null).
    /// </summary>
    public IReadOnlyList<Chip> Chips { get; init; } = Array.Empty<Chip>();

    /// <summary>Chip row visibility — collapsed when we have nothing
    /// to render so the row doesn't reserve empty vertical space.</summary>
    public Visibility ChipsVisibility => Chips.Count > 0 ? Visibility.Visible : Visibility.Collapsed;

    /// <summary>Visible when the entry is pinned — drives the row glyph.</summary>
    public Visibility PinGlyphVisibility => Pinned ? Visibility.Visible : Visibility.Collapsed;

    /// <summary>Visible when there's selectable OCR text to view.</summary>
    public Visibility OcrBadgeVisibility => HasOcr ? Visibility.Visible : Visibility.Collapsed;

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
        Tooltip   = BuildTooltip(row),
        Thumbnail = ThumbnailFrom(row.ThumbSmall),
        Pinned    = row.Pinned,
        HasOcr    = row.HasOcr,
        Tags      = CpdbWin.Core.Analysis.ImageTags.Parse(row.ImageTags),
        Chips     = Chip.DecodeArray(row.ChipsJson),
    };

    /// <summary>
    /// Multi-line hover tooltip for the row card. Surfaces the kind, the
    /// originating app's display name (when known), and the capture
    /// timestamp in absolute form. Mirrors macOS v2.7.12 hover tooltips.
    /// Skips the "originating device" line — Windows is standalone in v1
    /// (no sync substrate yet).
    /// </summary>
    private static string BuildTooltip(EntryRow row)
    {
        var lines = new List<string>(4)
        {
            // Type comes first; matches the macOS layout where it's the
            // most-glanced datum.
            $"Type: {KindDisplayName(row.Kind)}",
        };
        if (!string.IsNullOrEmpty(row.AppName))
        {
            lines.Add($"From: {row.AppName}");
        }
        else if (!string.IsNullOrEmpty(row.AppBundleId))
        {
            // Fall back to bundle id when we never resolved a display name —
            // better breadcrumb than just "From: ?".
            lines.Add($"From: {row.AppBundleId}");
        }
        lines.Add($"Captured: {FormatAbsoluteTime(row.CapturedAt)}");
        return string.Join('\n', lines);
    }

    private static string KindDisplayName(string kind) => kind switch
    {
        "text"  => "Text",
        "link"  => "Link",
        "image" => "Image",
        "file"  => "File",
        "color" => "Color",
        _       => kind,
    };

    private static string FormatAbsoluteTime(double unix)
    {
        // "Wed, 30 Apr 2026 09:39:19 PM" — readable + month abbreviation
        // disambiguates "5/4" (US/EU date order ambiguity).
        var dt = DateTimeOffset.FromUnixTimeSeconds((long)unix).LocalDateTime;
        return dt.ToString("ddd, dd MMM yyyy hh:mm:ss tt");
    }

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
        var sw = System.Diagnostics.Stopwatch.StartNew();
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
        finally
        {
            // Per-item attribution: how much of the calling refresh's
            // (and, if in flight, summon's) wall-clock was spent decoding
            // row-card thumbs. Global counters so Refresh() can measure
            // itself even when running outside a summon (ingest, filter
            // change); session mirrors when one is in flight.
            sw.Stop();
            PopupPerf.GlobalThumbLoads++;
            PopupPerf.GlobalThumbMs += sw.ElapsedMilliseconds;
            if (PopupPerf.Current is { } perf)
            {
                perf.ThumbLoads++;
                perf.ThumbMs += sw.ElapsedMilliseconds;
            }
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
