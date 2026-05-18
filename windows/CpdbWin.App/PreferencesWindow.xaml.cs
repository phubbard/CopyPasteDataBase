using System.Runtime.InteropServices;
using CpdbWin.Core;
using CpdbWin.Core.Identity;
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
    private HotkeyConfig _pending;
    private bool _recording;

    public PreferencesWindow(
        UserSettings settings,
        string settingsPath,
        Action<HotkeyConfig> onHotkeyChanged,
        AppHost host)
    {
        InitializeComponent();
        Title = $"{CpdbVersion.Description} preferences";
        _settings = settings;
        _settingsPath = settingsPath;
        _onHotkeyChanged = onHotkeyChanged;
        _host = host;
        _pending = settings.Hotkey;
        HotkeyBox.Text = HotkeyFormatter.Format(_pending);

        // Use AddHandler with handledEventsToo so we still see KeyDown for
        // keys like Tab that TextBox would otherwise consume internally.
        HotkeyBox.AddHandler(UIElement.KeyDownEvent,
            new KeyEventHandler(HotkeyBox_KeyDown), handledEventsToo: true);
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
