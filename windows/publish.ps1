# Publish CpdbWin.App as a self-contained single-file .exe for both
# Windows x64 and ARM64. Output lands in `windows/dist/<rid>/CpdbWin.App.exe`
# and is the only file you need to ship to a user — it bundles .NET 8
# runtime + WindowsAppSDK + cpdb itself.
#
# Usage:
#   pwsh ./windows/publish.ps1                # both architectures
#   pwsh ./windows/publish.ps1 -Rid win-x64   # one architecture
#   pwsh ./windows/publish.ps1 -Clean         # wipe dist/ first

[CmdletBinding()]
param(
    [string[]] $Rid = @('win-x64', 'win-arm64'),
    [switch]   $Clean
)

$ErrorActionPreference = 'Stop'
$repoRoot   = Split-Path -Parent $PSCommandPath
$projectDir = Join-Path $repoRoot 'CpdbWin.App'
$distRoot   = Join-Path $repoRoot 'dist'

if ($Clean -and (Test-Path $distRoot)) {
    Write-Host "Wiping $distRoot" -ForegroundColor Yellow
    Remove-Item -Recurse -Force $distRoot
}

foreach ($r in $Rid) {
    # WindowsAppSDK self-contained refuses to build with Platform=AnyCPU,
    # so map the RID to its native architecture.
    $platform = switch ($r) {
        'win-x64'   { 'x64' }
        'win-arm64' { 'ARM64' }
        'win-x86'   { 'x86' }
        default     { throw "Unsupported RID: $r" }
    }

    $outDir = Join-Path $distRoot $r
    Write-Host "Publishing $r ($platform) -> $outDir" -ForegroundColor Cyan
    & dotnet publish (Join-Path $projectDir 'CpdbWin.App.csproj') `
        -c Release `
        -r $r `
        -p:Platform=$platform `
        -o $outDir
    if ($LASTEXITCODE -ne 0) {
        throw "dotnet publish failed for $r (exit $LASTEXITCODE)"
    }
}

Write-Host ""
Write-Host "Done. Distributables:" -ForegroundColor Green
foreach ($r in $Rid) {
    $exe = Join-Path $distRoot $r 'CpdbWin.App.exe'
    if (Test-Path $exe) {
        $size = [math]::Round((Get-Item $exe).Length / 1MB, 1)
        Write-Host "  $exe  ($size MB)"
    }
}
