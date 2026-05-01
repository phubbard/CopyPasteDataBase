# Create a Start-menu shortcut to the installed cpdb-win.
#
# Velopack normally writes one during Setup.exe install, but if it
# went missing (interrupted install, manually-deleted Start menu entry,
# pre-1.7.0 installer that didn't pass --shortcuts) this drops a fresh
# .lnk into the user's Start menu without reinstalling anything.
#
# Idempotent: re-running just rewrites the same .lnk.

[CmdletBinding()]
param(
    # Pin a specific exe. If unset, the script searches:
    #   1. %LOCALAPPDATA%\CpdbWin\current\CpdbWin.App.exe   (Velopack install)
    #   2. %LOCALAPPDATA%\CpdbWin\CpdbWin.App.exe           (older Velopack layout)
    #   3. <repo>\windows\CpdbWin.App\bin\Debug\...\CpdbWin.App.exe (dev build)
    #   4. <repo>\windows\CpdbWin.App\bin\ARM64\Release\...\CpdbWin.App.exe (release build)
    # …in that order.
    [string] $Exe,
    [string] $InstallRoot = (Join-Path $env:LOCALAPPDATA 'CpdbWin'),
    [switch] $DesktopAlso
)

$ErrorActionPreference = 'Stop'

if (-not $Exe) {
    $candidates = @(
        (Join-Path $InstallRoot 'current\CpdbWin.App.exe'),
        (Join-Path $InstallRoot 'CpdbWin.App.exe'),
        (Join-Path $PSScriptRoot 'CpdbWin.App\bin\Debug\net8.0-windows10.0.19041.0\CpdbWin.App.exe'),
        (Join-Path $PSScriptRoot 'CpdbWin.App\bin\ARM64\Release\net8.0-windows10.0.19041.0\win-arm64\CpdbWin.App.exe'),
        (Join-Path $PSScriptRoot 'CpdbWin.App\bin\x64\Release\net8.0-windows10.0.19041.0\win-x64\CpdbWin.App.exe')
    )
    $Exe = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $Exe) {
        throw "Could not find CpdbWin.App.exe at any of the usual paths.`n  " +
              ($candidates -join "`n  ") + "`n" +
              "Pass -Exe <path> to point at it explicitly."
    }
    Write-Host "Located: $Exe" -ForegroundColor DarkGray
}
elseif (-not (Test-Path $Exe)) {
    throw "Exe not found: $Exe"
}

$startMenu = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'
$lnkPath   = Join-Path $startMenu 'cpdb-win.lnk'

$shell    = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($lnkPath)
$shortcut.TargetPath       = $Exe
$shortcut.WorkingDirectory = Split-Path -Parent $Exe
$shortcut.IconLocation     = "$Exe,0"
$shortcut.Description      = 'cpdb-win — clipboard history search'
$shortcut.Save()
Write-Host "Start menu shortcut: $lnkPath" -ForegroundColor Green
Write-Host "  -> $Exe"

if ($DesktopAlso) {
    $desktop = [Environment]::GetFolderPath('Desktop')
    $deskLnk = Join-Path $desktop 'cpdb-win.lnk'
    $shortcutD = $shell.CreateShortcut($deskLnk)
    $shortcutD.TargetPath       = $Exe
    $shortcutD.WorkingDirectory = Split-Path -Parent $Exe
    $shortcutD.IconLocation     = "$Exe,0"
    $shortcutD.Description      = 'cpdb-win — clipboard history search'
    $shortcutD.Save()
    Write-Host "Desktop shortcut:    $deskLnk" -ForegroundColor Green
}
