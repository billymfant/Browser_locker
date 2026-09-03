#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
    Puts the lock on Brave itself: your real Brave shortcuts launch the locker
    instead, keeping their name and icon, and the extra "Brave (Private)"
    shortcuts are removed.

    This no longer has to hide a drive. The vault is mounted onto Brave's own
    profile folder and never gets a drive letter in normal use, so there is
    nothing to hide and no passphrase needed here.
#>
[CmdletBinding()]
param(
    [string]$InstallRoot = 'C:\Program Files\BraveLocker'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $repoRoot 'src\BraveLocker\BraveLocker.psd1') -Force

$paths = Get-BraveLockerPaths
if (-not (Test-Path $paths.ConfigPath)) {
    throw 'Brave Locker is not set up yet. Run Install-BraveLocker.ps1 first.'
}
$config = Get-Content -Path $paths.ConfigPath -Raw | ConvertFrom-Json

if (@(Get-Process -Name 'brave' -ErrorAction SilentlyContinue).Count -gt 0) {
    throw 'Close Brave completely before running this.'
}
if (Test-BraveLockerVaultMounted -VhdxPath $config.VhdxPath) {
    throw 'The vault is currently open. Let the launcher seal it, then run this again.'
}

Write-Host ''
Write-Host 'Brave Locker - lock your Brave app' -ForegroundColor Cyan
Write-Host '=================================='
Write-Host ''

# --- 1. Refresh the installed copy -----------------------------------------
Write-Host "Updating $InstallRoot ..."
foreach ($sub in 'src', 'scripts') {
    $target = Join-Path $InstallRoot $sub
    if (Test-Path $target) { Remove-Item -Path $target -Recurse -Force }
    New-Item -ItemType Directory -Path $target -Force | Out-Null
    Copy-Item -Path (Join-Path $repoRoot "$sub\*") -Destination $target -Recurse -Force
}
Set-BraveLockerScriptAcl -Path $InstallRoot
Register-BraveLockerMountTask -ScriptPath (Join-Path $InstallRoot 'scripts\Invoke-BraveLockerVaultTask.ps1')
# Browser updaters rewrite their own shortcuts and quietly undo the takeover
# below. This puts it back at each logon; without it the lock comes off the
# first time the browser updates itself and nobody is told.
Register-BraveLockerShortcutGuardTask -ScriptPath (Join-Path $InstallRoot 'scripts\Invoke-BraveLockerShortcutGuard.ps1')
Write-Host 'Installed copy refreshed and verified.'

# The way out, installed at the same time as the lock rather than left in a
# repo. Someone whose browser will not open has no browser to read a web page
# with, and no reason to know this folder exists.
$rescue = Install-BraveLockerRescueItems -InstallRoot $InstallRoot `
    -CardSourcePath (Join-Path $repoRoot 'docs\EMERGENCY-CARD.md')
Write-Host "Emergency card installed: $($rescue.CardPath)"
foreach ($link in $rescue.Shortcuts) { Write-Host "  Start menu: $link" }

# --- 2. Take over the real Brave shortcuts ---------------------------------
Write-Host ''
Write-Host 'Putting the lock on your Brave shortcuts...'

$vbs = Join-Path $InstallRoot 'scripts\BraveLockerLauncher.vbs'
$backupDir = Join-Path $paths.StateRoot 'shortcut-backup'
$shortcuts = @(Get-BraveLockerBraveShortcut -BraveExe $config.BraveExe)

if ($shortcuts.Count -eq 0) {
    Write-Host 'No Brave shortcuts found to take over.' -ForegroundColor Yellow
} else {
    foreach ($shortcut in $shortcuts) {
        Set-BraveLockerShortcutToLauncher -ShortcutPath $shortcut -VbsPath $vbs `
            -BraveExe $config.BraveExe -BackupDir $backupDir
        Write-Host "  locked: $shortcut"
    }
    Write-Host "Originals backed up to $backupDir"
}

# --- 3. Remove the separate private shortcuts ------------------------------
foreach ($folder in ([Environment]::GetFolderPath('Desktop')), ([Environment]::GetFolderPath('Programs'))) {
    $stale = Join-Path $folder 'Brave (Private).lnk'
    if (Test-Path $stale) {
        Remove-Item -Path $stale -Force
        Write-Host "  removed: $stale"
    }
}

# --- 4. Record that the lock is on -----------------------------------------
# Written last, once the takeover has actually happened, so the flag never
# claims a lock the script failed to apply. Update-BraveLockerInstall.ps1 reads
# it and stops itself putting the separate "Brave (Private)" shortcuts back.
$config | Add-Member -NotePropertyName 'AppLocked' -NotePropertyValue $true -Force
$config | ConvertTo-Json -Depth 5 | Set-Content -Path $paths.ConfigPath -Encoding utf8

Write-Host ''
Write-Host 'Done.' -ForegroundColor Green
Write-Host 'Click Brave the way you always do. It will ask for your passphrase first.'
Write-Host ''
Write-Host 'If you ever open Brave WITHOUT the passcode - by running brave.exe directly'
Write-Host '- it will start an empty profile instead of yours. Nothing is lost; the'
Write-Host 'locker moves that empty profile aside next time you open Brave properly.'
