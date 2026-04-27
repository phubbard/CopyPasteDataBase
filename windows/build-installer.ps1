# Build a Velopack-style Setup.exe for beta-tester distribution.
#
# Pipeline:
#   1. dotnet publish CpdbWin.App as a self-contained, multi-file folder
#      (Velopack needs separate files to compute delta updates).
#   2. vpk pack — wraps the folder into Setup.exe + RELEASES + .nupkg.
#
# Output lands in `windows/Releases/<rid>/`. Email the Setup.exe to
# testers. They double-click; it installs into %LOCALAPPDATA%\CpdbWin
# without admin, registers a Start menu shortcut, and shows up in
# Settings → Apps for clean uninstall.
#
# First-run requires the `vpk` global tool:
#   dotnet tool install --global vpk
#
# Usage:
#   pwsh ./windows/build-installer.ps1                       # win-arm64 by default
#   pwsh ./windows/build-installer.ps1 -Rid win-x64
#   pwsh ./windows/build-installer.ps1 -Version 1.0.1
#   pwsh ./windows/build-installer.ps1 -Clean                # wipe outputs first

[CmdletBinding()]
param(
    [string] $Rid = 'win-arm64',
    [string] $Version,
    [switch] $Clean
)

$ErrorActionPreference = 'Stop'
$repoRoot      = Split-Path -Parent $PSCommandPath
$projectFile   = Join-Path $repoRoot 'CpdbWin.App\CpdbWin.App.csproj'
$publishRoot   = Join-Path $repoRoot 'publish'
$releasesRoot  = Join-Path $repoRoot 'Releases'
$publishDir    = Join-Path $publishRoot $Rid
$releaseDir    = Join-Path $releasesRoot $Rid

# Map RID -> MSBuild Platform (WindowsAppSDK self-contained refuses AnyCPU).
$platform = switch ($Rid) {
    'win-x64'   { 'x64' }
    'win-arm64' { 'ARM64' }
    'win-x86'   { 'x86' }
    default     { throw "Unsupported RID: $Rid" }
}

# Resolve version: param > Directory.Build.props's <Version>.
if (-not $Version) {
    $propsFile = Join-Path $repoRoot 'Directory.Build.props'
    $match = Select-String -Path $propsFile -Pattern '<Version>([^<]+)</Version>' -List
    if ($match) { $Version = $match.Matches[0].Groups[1].Value }
}
if (-not $Version) { throw "Could not determine version. Pass -Version 1.0.0." }

if ($Clean) {
    foreach ($d in @($publishRoot, $releasesRoot)) {
        if (Test-Path $d) {
            Write-Host "Wiping $d" -ForegroundColor Yellow
            Remove-Item -Recurse -Force $d
        }
    }
}

Write-Host "==> Publishing $Rid ($platform), version $Version" -ForegroundColor Cyan
& dotnet publish $projectFile `
    -c Release `
    -r $Rid `
    -p:Platform=$platform `
    -p:PublishSingleFile=false `
    -o $publishDir
if ($LASTEXITCODE -ne 0) { throw "dotnet publish failed (exit $LASTEXITCODE)" }

Write-Host "==> Packing Setup.exe with Velopack" -ForegroundColor Cyan
& vpk pack `
    --packId       CpdbWin `
    --packTitle    'cpdb-win' `
    --packVersion  $Version `
    --packAuthors  'Paul Hubbard' `
    --packDir      $publishDir `
    --mainExe      CpdbWin.App.exe `
    --runtime      $Rid `
    --outputDir    $releaseDir
if ($LASTEXITCODE -ne 0) { throw "vpk pack failed (exit $LASTEXITCODE)" }

Write-Host ""
Write-Host "Done." -ForegroundColor Green
$setup = Join-Path $releaseDir "$Rid-Setup.exe"
if (Test-Path $setup) {
    $size = [math]::Round((Get-Item $setup).Length / 1MB, 1)
    Write-Host "  Installer: $setup  ($size MB)"
}
Get-ChildItem $releaseDir -File | ForEach-Object {
    Write-Host ("  {0}  {1:N1} MB" -f $_.Name, ($_.Length / 1MB))
}
