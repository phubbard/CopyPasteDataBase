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

# Collect the artifacts to upload.
$artifacts = @()
foreach ($rid in $Rids) {
    $ridDir = Join-Path $releasesRoot $rid
    $setup = Join-Path $ridDir "$rid-Setup.exe"
    $portable = Join-Path $ridDir "$rid-Portable.zip"
    # Velopack names files as "<channel>-Setup.exe"; the channel default is 'win'.
    if (-not (Test-Path $setup)) {
        $setup = Join-Path $ridDir "win-Setup.exe"
        $portable = Join-Path $ridDir "win-Portable.zip"
    }
    # Try the actual filename layout vpk emits.
    Get-ChildItem $ridDir -Filter '*Setup.exe' | ForEach-Object {
        # Rename to include the rid so beta testers know which to grab.
        $renamed = Join-Path $ridDir ("CpdbWin-$Version-$rid-Setup.exe")
        Copy-Item -LiteralPath $_.FullName -Destination $renamed -Force
        $artifacts += $renamed
    }
    Get-ChildItem $ridDir -Filter '*Portable.zip' | ForEach-Object {
        $renamed = Join-Path $ridDir ("CpdbWin-$Version-$rid-Portable.zip")
        Copy-Item -LiteralPath $_.FullName -Destination $renamed -Force
        $artifacts += $renamed
    }
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
    Write-Host "  (draft — open https://github.com/phubbard/CopyPasteDataBase/releases to publish)"
}
