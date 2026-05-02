# Cut a GitHub release with the Velopack installer attached.
#
# Two-step pipeline:
#   1. build-installer.ps1 produces Setup.exe + Portable.zip in
#      windows/Releases/<rid>/.
#   2. gh release create tags + uploads them under a draft (or live)
#      GitHub release.
#
# Beta testers visit the release page and download Setup.exe. First run
# prompts SmartScreen ("Unknown publisher"); they click "More info →
# Run anyway" once and the app is installed under %LOCALAPPDATA%\CpdbWin.
#
# Requires: gh CLI authenticated (`gh auth status`) with repo + workflow
# scopes. Reuse the same token as the rest of the workflow.
#
# Usage:
#   pwsh ./windows/release-installer.ps1                            # uses Directory.Build.props version
#   pwsh ./windows/release-installer.ps1 -Version 1.0.0-beta.1
#   pwsh ./windows/release-installer.ps1 -Tag v1.0.0 -Live          # publishes immediately (default is draft)
#   pwsh ./windows/release-installer.ps1 -SkipBuild                 # skip rebuilding; just upload existing artifacts

[CmdletBinding()]
param(
    [string] $Version,
    [string] $Tag,
    [string] $Title,
    [string[]] $Rids = @('win-arm64', 'win-x64'),  # ship both by default
    [switch] $Live,    # default is --draft
    [switch] $SkipBuild
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSCommandPath
$releasesRoot = Join-Path $repoRoot 'Releases'

if (-not $Version) {
    $propsFile = Join-Path $repoRoot 'Directory.Build.props'
    $match = Select-String -Path $propsFile -Pattern '<Version>([^<]+)</Version>' -List
    if ($match) { $Version = $match.Matches[0].Groups[1].Value }
}
if (-not $Version) { throw "Could not determine version. Pass -Version 1.0.0-beta.1." }
if (-not $Tag)     { $Tag = "v$Version" }
if (-not $Title)   { $Title = "cpdb-win $Version" }

if (-not $SkipBuild) {
    foreach ($rid in $Rids) {
        Write-Host "==> Building installer for $rid" -ForegroundColor Cyan
        & pwsh (Join-Path $repoRoot 'build-installer.ps1') -Rid $rid -Version $Version
        if ($LASTEXITCODE -ne 0) { throw "build-installer.ps1 failed for $rid" }
    }
}

# Refuse to clobber an existing tag: gh release create would otherwise
# create the release first and *then* fail on upload, leaving an empty
# published release behind. Better to abort up front.
#
# Note on PowerShell 5.1 native-command stderr handling: with
# $ErrorActionPreference='Stop', any line a native exe writes to stderr
# becomes an ErrorRecord that aborts the script -- even with `2>$null`
# or `2>&1 | Out-Null` (the redirection layer fires after the wrapping).
# Ducking under it via try/catch with a local 'Continue' policy is the
# only reliable way to ask "does this release exist?" without the
# script blowing up when it does NOT.
$tagExists = $false
try {
    $prevPref = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $null = & gh release view $Tag --json url 2>$null
    $tagExists = ($LASTEXITCODE -eq 0)
} finally {
    $ErrorActionPreference = $prevPref
}
if ($tagExists) {
    throw "Release $Tag already exists. Delete it first: gh release delete $Tag --cleanup-tag --yes"
}

# Collect the artifacts to upload. Match Velopack's exact emit names —
# 'CpdbWin-win-Setup.exe' and 'CpdbWin-win-Portable.zip' — instead of a
# wildcard. A wildcard caught stale renamed artifacts from prior version
# cuts (e.g. 'CpdbWin-1.0.0-beta.1-win-x64-Setup.exe' lingering in the
# rid dir) and rewrote them to the same target path, producing duplicate
# entries that 404'd on the second upload.
$artifacts = @()
foreach ($rid in $Rids) {
    $ridDir = Join-Path $releasesRoot $rid
    $emittedSetup    = Join-Path $ridDir 'CpdbWin-win-Setup.exe'
    $emittedPortable = Join-Path $ridDir 'CpdbWin-win-Portable.zip'
    foreach ($p in @($emittedSetup, $emittedPortable)) {
        if (-not (Test-Path $p)) {
            throw "Expected Velopack artifact missing: $p. Re-run without -SkipBuild."
        }
    }

    # Rename so the version + rid are baked into the filename testers see.
    $renamedSetup    = Join-Path $ridDir ("CpdbWin-$Version-$rid-Setup.exe")
    $renamedPortable = Join-Path $ridDir ("CpdbWin-$Version-$rid-Portable.zip")
    Copy-Item -LiteralPath $emittedSetup    -Destination $renamedSetup    -Force
    Copy-Item -LiteralPath $emittedPortable -Destination $renamedPortable -Force
    $artifacts += $renamedSetup
    $artifacts += $renamedPortable
}

if ($artifacts.Count -eq 0) {
    throw "No installer artifacts found under $releasesRoot. Run with -SkipBuild:false (default) or build them via build-installer.ps1 first."
}

Write-Host "==> Uploading $($artifacts.Count) artifact(s) to GitHub" -ForegroundColor Cyan
$ghArgs = @(
    'release', 'create', $Tag,
    '--title', $Title,
    '--generate-notes'
)
if (-not $Live) { $ghArgs += '--draft' }
$ghArgs += $artifacts

& gh @ghArgs
if ($LASTEXITCODE -ne 0) { throw "gh release create failed (exit $LASTEXITCODE)" }

Write-Host ""
Write-Host "Release created: $Tag" -ForegroundColor Green
if (-not $Live) {
    Write-Host "  (draft -- open https://github.com/phubbard/CopyPasteDataBase/releases to publish)"
}
