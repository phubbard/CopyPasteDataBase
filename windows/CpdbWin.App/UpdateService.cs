using System.Runtime.InteropServices;
using Velopack;
using Velopack.Sources;

namespace CpdbWin.App;

/// <summary>
/// Client-side auto-update over the Velopack feed we already publish
/// to GitHub Releases. Functional parity with the macOS Sparkle
/// contract (docs/parity.md § Auto-update): a background check on
/// startup + once a day, plus an on-demand "Check for Updates…" tray
/// item, and the update is <b>prompted, not silent</b> — we download
/// in the background but never restart without the user saying yes.
///
/// <para>
/// Velopack's <see cref="GithubSource"/> enumerates published GitHub
/// releases (drafts are invisible to the unauthenticated API — that's
/// the desired behavior, testers don't auto-update to an unpublished
/// draft), reads the channel manifest for the running architecture
/// (<c>releases.win-x64.json</c> / <c>releases.win-arm64.json</c> —
/// selected via <see cref="UpdateOptions.ExplicitChannel"/>), and
/// downloads the matching <c>.nupkg</c>. <c>build-installer.ps1</c>
/// packs each arch with <c>--channel win-&lt;arch&gt;</c> and
/// <c>release-installer.ps1</c> uploads both arches' feeds, so x64 and
/// arm64 installs each update against their own packages off one
/// shared GitHub release.
/// </para>
///
/// <para>
/// All failure is swallowed + logged to
/// <c>%LOCALAPPDATA%\cpdb\update.log</c>; a user-initiated check also
/// surfaces the outcome (up-to-date / error) in a message box so the
/// menu item never looks dead.
/// </para>
/// </summary>
public sealed class UpdateService
{
    private const string RepoUrl = "https://github.com/phubbard/CopyPasteDataBase";

    // Coalesce startup / daily-timer / manual triggers so two checks
    // never run concurrently (Velopack takes its own lock, but a
    // second prompt stacking on the first is bad UX).
    private readonly SemaphoreSlim _gate = new(1, 1);
    private System.Threading.Timer? _dailyTimer;

    /// <summary>
    /// Start the once-a-day background cadence. The first tick fires
    /// shortly after launch (not instantly — let the app settle), then
    /// every 24h. Idempotent triggers; safe alongside the manual item.
    /// </summary>
    public void StartBackgroundChecks()
    {
        if (_dailyTimer is not null) return;
        _dailyTimer = new System.Threading.Timer(
            _ => _ = CheckAsync(userInitiated: false),
            state: null,
            dueTime: TimeSpan.FromSeconds(30),
            period: TimeSpan.FromHours(24));
    }

    public void Dispose() => _dailyTimer?.Dispose();

    /// <summary>
    /// Run one check. <paramref name="userInitiated"/> controls
    /// chattiness: a manual check always reports its result; the
    /// background cadence stays silent unless there's an update to
    /// offer.
    /// </summary>
    public async Task CheckAsync(bool userInitiated)
    {
        if (!await _gate.WaitAsync(0).ConfigureAwait(false))
        {
            if (userInitiated) Info("An update check is already running.");
            return;
        }
        try
        {
            // Each architecture has its own Velopack channel
            // (build-installer.ps1 packs with `--channel win-<arch>`),
            // so an arm64 install only ever sees arm64 packages and
            // vice-versa. Map the running process arch → channel.
            // We only build x64 + arm64; anything else has no feed.
            var channel = RuntimeInformation.ProcessArchitecture switch
            {
                Architecture.X64   => "win-x64",
                Architecture.Arm64 => "win-arm64",
                _                  => null,
            };
            if (channel is null)
            {
                Log($"arch {RuntimeInformation.ProcessArchitecture} — no feed built for this arch, skipping");
                if (userInitiated)
                {
                    Info("Automatic updates aren't available for the "
                       + $"{RuntimeInformation.ProcessArchitecture} build. "
                       + "Download the latest from the GitHub releases page.");
                }
                return;
            }

            var mgr = new UpdateManager(
                new GithubSource(RepoUrl, null, false, null),
                new UpdateOptions { ExplicitChannel = channel });

            // Dev / debug / portable runs aren't Velopack-installed —
            // there's nothing to update in place. Don't nag the
            // background cadence about it; only answer a manual check.
            if (!mgr.IsInstalled)
            {
                Log("not a Velopack install — skipping");
                if (userInitiated)
                {
                    Info("This build isn't installed via the updater "
                       + "(developer / portable build). Download releases "
                       + "from the GitHub releases page.");
                }
                return;
            }

            Log($"checking (current {mgr.CurrentVersion}, userInitiated={userInitiated})");
            UpdateInfo? info;
            try
            {
                info = await mgr.CheckForUpdatesAsync().ConfigureAwait(false);
            }
            catch (Exception ex)
            {
                Log($"check failed: {ex.Message}");
                if (userInitiated) Info($"Couldn't check for updates:\n{ex.Message}");
                return;
            }

            if (info is null)
            {
                Log("up to date");
                if (userInitiated) Info($"You're up to date (cpdb-win {mgr.CurrentVersion}).");
                return;
            }

            var newVersion = info.TargetFullRelease.Version;
            Log($"update available: {newVersion}");

            // Download in the background BEFORE prompting so "yes" is
            // instant — prompt-not-silent means we never restart
            // unasked, not that we make the user wait on a download
            // after they say yes.
            try
            {
                await mgr.DownloadUpdatesAsync(info).ConfigureAwait(false);
            }
            catch (Exception ex)
            {
                Log($"download failed: {ex.Message}");
                if (userInitiated) Info($"Couldn't download the update:\n{ex.Message}");
                return;
            }

            var answer = AskYesNo(
                "cpdb-win update available",
                $"cpdb-win {newVersion} is available "
                + $"(you have {mgr.CurrentVersion}).\n\n"
                + "The update has been downloaded. Restart cpdb-win now "
                + "to apply it?");
            if (answer)
            {
                Log($"applying {newVersion} + restart");
                mgr.ApplyUpdatesAndRestart(info.TargetFullRelease);
            }
            else
            {
                Log("user deferred");
            }
        }
        catch (Exception ex)
        {
            Log($"unexpected: {ex}");
            if (userInitiated) Info($"Update check failed:\n{ex.Message}");
        }
        finally
        {
            try { _gate.Release(); } catch (ObjectDisposedException) { }
        }
    }

    // ─── User-facing prompts (Win32; the window is usually hidden) ───────

    private static bool AskYesNo(string title, string text)
    {
        // MB_YESNO | MB_ICONQUESTION | MB_SETFOREGROUND | MB_TOPMOST.
        const uint flags = 0x4 | 0x20 | 0x10000 | 0x40000;
        return MessageBoxW(IntPtr.Zero, text, title, flags) == 6 /* IDYES */;
    }

    private static void Info(string text)
    {
        const uint flags = 0x0 | 0x40 | 0x10000 | 0x40000; // OK | INFO | SETFG | TOPMOST
        MessageBoxW(IntPtr.Zero, text, "cpdb-win", flags);
    }

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern int MessageBoxW(IntPtr hWnd, string text, string caption, uint type);

    // ─── Diagnostics ─────────────────────────────────────────────────────

    private static void Log(string message)
    {
        try
        {
            var path = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "cpdb", "update.log");
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            if (File.Exists(path) && new FileInfo(path).Length > 1_000_000)
                File.WriteAllText(path, $"[{DateTime.Now:yyyy-MM-dd HH:mm:ss}] (rotated)\n");
            File.AppendAllText(path, $"[{DateTime.Now:yyyy-MM-dd HH:mm:ss.fff}] {message}\n");
        }
        catch { }
    }
}
