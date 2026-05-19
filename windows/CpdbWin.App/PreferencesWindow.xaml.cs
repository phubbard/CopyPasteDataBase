using System.Runtime.InteropServices;
using CpdbWin.Core;
using CpdbWin.Core.Identity;
using CpdbWin.Core.Maintenance;
using CpdbWin.Core.Portability;
using CpdbWin.Core.Service;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Windows.Storage.Pickers;
using Windows.System;
using WinRT.Interop;

namespace CpdbWin.App;

public sealed partial class PreferencesWindow : Window
{
    private readonly UserSettings _settings;
    private readonly string _settingsPath;
    private readonly Action<HotkeyConfig> _onHotkeyChanged;
    private readonly AppHost _host;
    private readonly Action? _onStoreChanged;
    private readonly Action? _onCheckUpdates;
    private HotkeyConfig _pending;
    private bool _recording;

    public PreferencesWindow(
        UserSettings settings,
        string settingsPath,
        Action<HotkeyConfig> onHotkeyChanged,
        AppHost host,
        Action? onStoreChanged = null,
        Action? onCheckUpdates = null)
    {
        InitializeComponent();
        Title = $"{CpdbVersion.Description} preferences";
        _settings = settings;
        _settingsPath = settingsPath;
        _onHotkeyChanged = onHotkeyChanged;
        _host = host;
        _onStoreChanged = onStoreChanged;
        _onCheckUpdates = onCheckUpdates;
        _pending = settings.Hotkey;
        HotkeyBox.Text = HotkeyFormatter.Format(_pending);

        // Use AddHandler with handledEventsToo so we still see KeyDown for
        // keys like Tab that TextBox would otherwise consume internally.
        HotkeyBox.AddHandler(UIElement.KeyDownEvent,
            new KeyEventHandler(HotkeyBox_KeyDown), handledEventsToo: true);

        // Startup section reflects the live Run-key state. A non-Velopack
        // build can't legally write it (AutoLaunch refuses to let a dev
        // build hijack the shared key), so disable the toggle + explain.
        StartupCheck.IsChecked = AutoLaunch.IsEnabled();
        if (!AutoLaunch.IsManagedInstall())
        {
            StartupCheck.IsEnabled = false;
            StartupHint.Text = "Autostart is only configurable from an installed "
                             + "build (this looks like a dev / portable run).";
        }

        UpdatesInfo.Text = $"Current version: {CpdbVersion.Full}. "
                         + "Updates are checked automatically ~30s after launch "
                         + "and once a day; you're prompted before anything restarts.";

        _ = LoadStorageInfoAsync();
    }

    private void HotkeyBox_GotFocus(object sender, RoutedEventArgs e)
    {
        _recording = true;
        HotkeyBox.Text = "Press a key combo…";
        HotkeyHint.Text = "Hold modifiers, then press the key.";
    }

    private void HotkeyBox_LostFocus(object sender, RoutedEventArgs e)
    {
        _recording = false;
        HotkeyBox.Text = HotkeyFormatter.Format(_pending);
    }

    private void HotkeyBox_KeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (!_recording) return;

        if (IsModifierKey(e.Key))
        {
            // Wait for the actual key.
            e.Handled = true;
            return;
        }

        // We always swallow the key while recording so it doesn't leak to
        // text-edit logic.
        e.Handled = true;

        uint mods = 0;
        if (IsKeyDown(VK_CONTROL)) mods |= HotkeyModifiers.Control;
        if (IsKeyDown(VK_MENU))    mods |= HotkeyModifiers.Alt;
        if (IsKeyDown(VK_SHIFT))   mods |= HotkeyModifiers.Shift;
        if (IsKeyDown(VK_LWIN) || IsKeyDown(VK_RWIN)) mods |= HotkeyModifiers.Win;

        if (mods == 0)
        {
            HotkeyHint.Text = "That's missing a modifier — try Ctrl/Alt/Shift/Win + key.";
            return;
        }

        var candidate = new HotkeyConfig(mods, (uint)e.Key);
        // Soft-warn the user about the OS-owned Win+V; we'll still let them
        // pick it because RegisterHotKey rejects it explicitly anyway.
        if (mods == HotkeyModifiers.Win && (uint)e.Key == 0x56)
            HotkeyHint.Text = "Win+V is owned by the OS clipboard history — pick something else.";
        else
            HotkeyHint.Text = $"Will register: {HotkeyFormatter.Format(candidate)}";

        _pending = candidate;
        HotkeyBox.Text = HotkeyFormatter.Format(_pending);
    }

    private void Reset_Click(object sender, RoutedEventArgs e)
    {
        _pending = HotkeyConfig.Default;
        HotkeyBox.Text = HotkeyFormatter.Format(_pending);
        HotkeyHint.Text = "Reset to default. Save to apply.";
    }

    private void Save_Click(object sender, RoutedEventArgs e)
    {
        _settings.Hotkey = _pending;
        _settings.Save(_settingsPath);
        try { _onHotkeyChanged(_pending); }
        catch
        {
            // Surface failure but still close — settings are saved; the
            // user can try another combo if registration failed.
        }
        this.Close();
    }

    private void Cancel_Click(object sender, RoutedEventArgs e) => this.Close();

    // ─── Import / Export (docs/parity.md § Data portability) ─────────────
    //
    // Both buttons call the same engine helpers the CLI uses
    // (CpdbWin.Core.Portability.UrlImporter / HistoryExporter) — one
    // implementation, not two. The store work runs on a background
    // thread (Task.Run) so a big import / export doesn't freeze the
    // window; the status line is updated back on the UI thread.

    private async void ImportUrls_Click(object sender, RoutedEventArgs e)
    {
        var picker = new FileOpenPicker
        {
            SuggestedStartLocation = PickerLocationId.DocumentsLibrary,
        };
        picker.FileTypeFilter.Add(".txt");
        picker.FileTypeFilter.Add(".md");
        picker.FileTypeFilter.Add("*");
        // Unpackaged WinUI 3: pickers need an owner HWND or they throw.
        InitializeWithWindow.Initialize(picker, WindowNative.GetWindowHandle(this));

        var file = await picker.PickSingleFileAsync();
        if (file is null) return;

        SetPortabilityBusy(true, $"Importing {file.Name}…");
        try
        {
            var raw = await Windows.Storage.FileIO.ReadTextAsync(file);
            // Contract: the GUI uses a 1-hour spread so a bulk import
            // doesn't collapse to a single timestamp + scramble order.
            //
            // Open a private SqliteConnection on the worker thread rather
            // than reusing _host.Database / _host.Ingestor — a
            // SqliteConnection isn't safe to touch from a thread other
            // than the one driving the capture pipeline. WAL mode lets
            // this second connection coexist with the live one. Same
            // shape the CLI uses.
            var paths = _host.Paths;
            var result = await Task.Run(() =>
            {
                using var db = CpdbWin.Core.Store.Database.Open(paths.Database);
                var blobs = new CpdbWin.Core.Store.BlobStore(paths.Blobs);
                var ingestor = new CpdbWin.Core.Ingest.Ingestor(db, blobs);
                var device = DeviceIdentity.Read();
                return UrlImporter.Run(raw, ingestor, device, spreadSeconds: 3600);
            });

            var msg = $"Imported {result.AcceptedCount} URL(s): "
                    + $"{result.Inserted} new, {result.Bumped} re-copied, "
                    + $"{result.Skipped} skipped";
            if (result.Rejected.Count > 0)
                msg += $"; {result.Rejected.Count} line(s) rejected";
            SetPortabilityBusy(false, msg);

            // The import wrote via its own worker-thread connection, so
            // the main window's capture-event refresh never fired — poke
            // it to re-query or the freshly-imported rows stay invisible
            // until the next capture / backfill settle.
            if (result.Inserted > 0 || result.Bumped > 0)
                _onStoreChanged?.Invoke();
        }
        catch (Exception ex)
        {
            SetPortabilityBusy(false, $"Import failed: {ex.Message}");
        }
    }

    private async void ExportHistory_Click(object sender, RoutedEventArgs e)
    {
        var tag = (ExportFormatBox.SelectedItem as ComboBoxItem)?.Tag as string ?? "md";
        if (!HistoryExporter.TryParseFormat(tag, out var format)) format = HistoryExporter.Format.Md;
        var ext = HistoryExporter.FileExtension(format);

        var picker = new FileSavePicker
        {
            SuggestedStartLocation = PickerLocationId.DocumentsLibrary,
            SuggestedFileName = $"cpdb-export-{DateTime.Now:yyyy-MM-dd}",
        };
        picker.FileTypeChoices.Add(
            format switch
            {
                HistoryExporter.Format.Md   => "Markdown",
                HistoryExporter.Format.Csv  => "CSV",
                HistoryExporter.Format.Html => "HTML",
                _                           => "Text",
            },
            new List<string> { "." + ext });
        InitializeWithWindow.Initialize(picker, WindowNative.GetWindowHandle(this));

        var file = await picker.PickSaveFileAsync();
        if (file is null) return;

        SetPortabilityBusy(true, "Exporting…");
        try
        {
            var paths = _host.Paths;
            var (doc, count) = await Task.Run(() =>
            {
                using var db = CpdbWin.Core.Store.Database.Open(paths.Database);
                return HistoryExporter.Export(db, format);
            });
            await Windows.Storage.FileIO.WriteTextAsync(file, doc);
            SetPortabilityBusy(false, $"Exported {count} entries to {file.Name}");
        }
        catch (Exception ex)
        {
            SetPortabilityBusy(false, $"Export failed: {ex.Message}");
        }
    }

    private void SetPortabilityBusy(bool busy, string status)
    {
        ImportButton.IsEnabled = !busy;
        ExportButton.IsEnabled = !busy;
        ExportFormatBox.IsEnabled = !busy;
        PortabilityStatus.Text = status;
    }

    // ─── Startup (parity: macOS Preferences → Startup) ───────────────────

    private void StartupCheck_Click(object sender, RoutedEventArgs e)
    {
        AutoLaunch.SetEnabled(StartupCheck.IsChecked == true);
        // Re-read: SetEnabled is a no-op on a non-managed build, so the
        // checkbox must reflect what actually stuck, not what was clicked.
        StartupCheck.IsChecked = AutoLaunch.IsEnabled();
    }

    // ─── Library maintenance (parity: macOS → Link metadata buttons) ─────
    //
    // Same engine the CLI uses (CpdbWin.Core.Maintenance) — one
    // implementation. Runs on a worker with its own SqliteConnection
    // (never touch the capture connection cross-thread; WAL +
    // busy_timeout coexist with the live app). After mutating link
    // state we poke the main window so the now-candidate rows show, and
    // the running LinkBackfillService picks them up on its next cycle.

    private void Reclassify_Click(object sender, RoutedEventArgs e) =>
        _ = RunMaintenanceAsync("reclassify", db =>
        {
            var r = MaintenanceCommands.ReclassifyKinds(db);
            return $"Reclassified {r.Reclassified} of {r.Scanned} "
                 + $"(link state reset on {r.LinkStateReset}).";
        });

    private void RetryEmpty_Click(object sender, RoutedEventArgs e) =>
        _ = RunMaintenanceAsync("retry-empty", db =>
        {
            var r = MaintenanceCommands.RetryEmptyLinks(db);
            return $"Queued {r.LinkStateReset} title-less link(s) for refetch.";
        });

    private void ReOcr_Click(object sender, RoutedEventArgs e) =>
        _ = RunMaintenanceAsync("re-OCR images", db =>
        {
            var r = MaintenanceCommands.ResetImageAnalysis(db);
            return r.LinkStateReset == 0
                ? "No image entries to OCR."
                : $"Re-armed {r.LinkStateReset} image(s); OCR runs in the "
                  + "background and folds the text into search.";
        });

    private void ReEnrich_Click(object sender, RoutedEventArgs e) =>
        _ = RunMaintenanceAsync("re-enrich", db =>
        {
            var rc = MaintenanceCommands.ReclassifyKinds(db);
            var re = MaintenanceCommands.RetryEmptyLinks(db);
            return $"Reclassified {rc.Reclassified} → link; queued "
                 + $"{rc.LinkStateReset + re.LinkStateReset} link(s) for "
                 + "title/thumbnail refetch. Fetching in the background…";
        });

    private async Task RunMaintenanceAsync(string label, Func<Microsoft.Data.Sqlite.SqliteConnection, string> work)
    {
        SetMaintenanceBusy(true, $"Running {label}…");
        try
        {
            var dbPath = _host.Paths.Database;
            var msg = await Task.Run(() =>
            {
                using var db = CpdbWin.Core.Store.Database.Open(dbPath);
                return work(db);
            });
            SetMaintenanceBusy(false, msg);
            // Link state changed on a side connection — refresh the main
            // window and let the backfill loop notice the candidates.
            _onStoreChanged?.Invoke();
        }
        catch (Exception ex)
        {
            SetMaintenanceBusy(false, $"{label} failed: {ex.Message}");
        }
    }

    private void SetMaintenanceBusy(bool busy, string status)
    {
        ReEnrichButton.IsEnabled    = !busy;
        ReclassifyButton.IsEnabled  = !busy;
        RetryEmptyButton.IsEnabled  = !busy;
        ReOcrButton.IsEnabled       = !busy;
        MaintenanceStatus.Text = status;
    }

    // ─── Storage diagnostic (parity: macOS → Storage) ────────────────────

    private async Task LoadStorageInfoAsync()
    {
        try
        {
            var paths = _host.Paths;
            var text = await Task.Run(() =>
            {
                static long Len(string p)
                {
                    try { return new FileInfo(p).Exists ? new FileInfo(p).Length : 0; }
                    catch { return 0; }
                }
                static long DirSize(string d)
                {
                    try
                    {
                        return Directory.Exists(d)
                            ? Directory.EnumerateFiles(d, "*", SearchOption.AllDirectories)
                                       .Sum(f => { try { return new FileInfo(f).Length; } catch { return 0L; } })
                            : 0;
                    }
                    catch { return 0; }
                }
                static string MB(long b) => $"{b / 1024.0 / 1024.0:N1} MB";

                long db   = Len(paths.Database);
                long wal  = Len(paths.Database + "-wal");
                long shm  = Len(paths.Database + "-shm");
                long blob = DirSize(paths.Blobs);

                long total = 0, live = 0, pinned = 0;
                try
                {
                    using var c = CpdbWin.Core.Store.Database.Open(paths.Database);
                    long Scalar(string sql)
                    {
                        using var cmd = c.CreateCommand();
                        cmd.CommandText = sql;
                        return Convert.ToInt64(cmd.ExecuteScalar());
                    }
                    total  = Scalar("SELECT COUNT(*) FROM entries");
                    live   = Scalar("SELECT COUNT(*) FROM entries WHERE deleted_at IS NULL");
                    pinned = Scalar("SELECT COUNT(*) FROM entries WHERE pinned = 1 AND deleted_at IS NULL");
                }
                catch { /* counts best-effort */ }

                return
                    $"Database : {paths.Database}\n"
                  + $"DB size  : {MB(db)}  (+wal {MB(wal)}  +shm {MB(shm)})\n"
                  + $"Blobs    : {MB(blob)}  ({paths.Blobs})\n"
                  + $"Entries  : {live:N0} live · {pinned:N0} pinned · {total:N0} total (incl. tombstoned)";
            });
            StorageInfo.Text = text;
        }
        catch (Exception ex)
        {
            StorageInfo.Text = $"(couldn't read storage info: {ex.Message})";
        }
    }

    // ─── Updates (parity: macOS surfaces update state in-window) ─────────

    private void CheckUpdates_Click(object sender, RoutedEventArgs e)
    {
        if (_onCheckUpdates is null)
        {
            UpdatesInfo.Text = "Update check isn't available from this build.";
            return;
        }
        UpdatesInfo.Text = "Checking for updates… (you'll get a prompt if one's available)";
        _onCheckUpdates.Invoke();
    }

    private static bool IsModifierKey(VirtualKey k) => k is
        VirtualKey.Control or VirtualKey.LeftControl or VirtualKey.RightControl
        or VirtualKey.Shift or VirtualKey.LeftShift or VirtualKey.RightShift
        or VirtualKey.Menu or VirtualKey.LeftMenu or VirtualKey.RightMenu
        or VirtualKey.LeftWindows or VirtualKey.RightWindows;

    private const int VK_SHIFT   = 0x10;
    private const int VK_CONTROL = 0x11;
    private const int VK_MENU    = 0x12;
    private const int VK_LWIN    = 0x5B;
    private const int VK_RWIN    = 0x5C;

    [DllImport("user32.dll")] private static extern short GetKeyState(int vKey);
    private static bool IsKeyDown(int vk) => (GetKeyState(vk) & 0x8000) != 0;
}
