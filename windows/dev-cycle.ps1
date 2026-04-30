# Build → stop → install → restart cycle for fast local testing.
#
# Pipeline:
#   1. dotnet test                          (skip with -NoTest)
#   2. build-installer.ps1 -Rid <host-arch> (vpk pack — Setup.exe + Portable.zip)
#   3. Stop any running CpdbWin.App.exe
#   4. Run the freshly built Setup.exe — Velopack auto-launches the new copy
#
# The intent is one command between an edit and a real-world test against
# live clipboard content, without going through the full GitHub release
# dance. Default arch is the host's, so on an arm64 dev box you only build
# arm64 — release-installer.ps1 still ships both.
#
# Usage:
#   pwsh ./windows/dev-cycle.ps1
#   pwsh ./windows/dev-cycle.ps1 -NoTest          # skip xUnit run
#   pwsh ./windows/dev-cycle.ps1 -Rid win-x64     # override host-arch detection
#   pwsh ./windows/dev-cycle.ps1 -SkipBuild       # use the last build artifacts

[CmdletBinding()]
param(
    [string] $Rid,
    [switch] $NoTest,
    [switch] $SkipBuild
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSCommandPath

if (-not $Rid) {
    $Rid = switch ($env:PROCESSOR_ARCHITECTURE) {
        'ARM64' { 'win-arm64' }
        'AMD64' { 'win-x64' }
        default { throw "Unsupported PROCESSOR_ARCHITECTURE: $env:PROCESSOR_ARCHITECTURE. Pass -Rid explicitly." }
    }
}

if (-not $NoTest) {
    Write-Host "==> Running unit tests" -ForegroundColor Cyan
    & dotnet test (Join-Path $repoRoot 'CpdbWin.Core.Tests\CpdbWin.Core.Tests.csproj') -c Debug --nologo
    if ($LASTEXITCODE -ne 0) {
        throw "Tests failed (exit $LASTEXITCODE) — install skipped. Pass -NoTest to bypass."
    }
}

if (-not $SkipBuild) {
    Write-Host "==> Building installer for $Rid" -ForegroundColor Cyan
    & pwsh (Join-Path $repoRoot 'build-installer.ps1') -Rid $Rid
    if ($LASTEXITCODE -ne 0) { throw "build-installer.ps1 failed (exit $LASTEXITCODE)" }
}

# ─── Stop the running app ─────────────────────────────────────────────────
# Velopack puts the binary at %LOCALAPPDATA%\CpdbWin\current\CpdbWin.App.exe
# and spawns an Update.exe alongside it. Killing CpdbWin.App is enough — the
# Update.exe goes idle when its child exits, and Setup.exe handles its own
# locks. We swallow "no such process" errors so the script still works on
# a fresh box that's never had the app installed.
Write-Host "==> Stopping any running CpdbWin.App" -ForegroundColor Cyan
$running = Get-Process -Name CpdbWin.App -ErrorAction SilentlyContinue
if ($running) {
    foreach ($p in $running) {
        Write-Host "    killing PID $($p.Id) ($($p.Path))"
        try { $p | Stop-Process -Force -ErrorAction Stop } catch {
            Write-Warning "    could not stop $($p.Id): $_"
        }
    }
    # Brief wait so Velopack's update.exe releases its locks on the install
    # directory before Setup.exe tries to write there.
    Start-Sleep -Milliseconds 500
} else {
    Write-Host "    none running"
}

# ─── Install the freshly built bits ──────────────────────────────────────
$setup = Join-Path $repoRoot "Releases\$Rid\CpdbWin-win-Setup.exe"
if (-not (Test-Path $setup)) {
    throw "Setup.exe missing at $setup. Run without -SkipBuild or check build-installer.ps1 output."
}
$size = [math]::Round((Get-Item $setup).Length / 1MB, 1)
Write-Host "==> Launching $setup ($size MB)" -ForegroundColor Cyan
Write-Host "    Velopack will install + auto-launch the new copy."

# Setup.exe forks and exits; Velopack itself relaunches CpdbWin.App after
# the extract finishes. We don't want to block the dev session waiting on it.
& $setup
# &-invocation returns the child's exit code via $LASTEXITCODE — Setup.exe
# returns 0 on a successful kick-off even though it backgrounds the install.

if ($LASTEXITCODE -ne 0) {
    throw "Setup.exe returned exit $LASTEXITCODE"
}

Write-Host ""
Write-Host "Done. cpdb-win is reinstalling and should appear in the system tray shortly." -ForegroundColor Green
Write-Host "  Hotkey: Ctrl+Shift+V (or whatever you've set in Preferences)"
Write-Host "  Run-at-boot: enabled by default on first install — toggle from the tray menu."
