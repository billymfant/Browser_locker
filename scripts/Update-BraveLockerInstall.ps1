#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
    Refreshes the installed copy under Program Files and re-registers the mount
    task, without touching the vault, the profile inside it, or your config.

    Use this after the tool's code changes. Setup itself refuses to run twice,
    because it would try to create a vault that already exists.
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

if (Test-BraveLockerVaultMounted -VhdxPath $config.VhdxPath) {
    throw 'The vault is currently open. Close Brave and let the launcher seal it before updating.'
}

Write-Host ''
Write-Host "Updating $InstallRoot ..." -ForegroundColor Cyan

foreach ($sub in 'src', 'scripts') {
    $target = Join-Path $InstallRoot $sub
    if (Test-Path $target) { Remove-Item -Path $target -Recurse -Force }
    New-Item -ItemType Directory -Path $target -Force | Out-Null
    Copy-Item -Path (Join-Path $repoRoot "$sub\*") -Destination $target -Recurse -Force
}

Set-BraveLockerScriptAcl -Path $InstallRoot
Write-Host 'Verified: the installed copy is writable only by administrators.'

Register-BraveLockerMountTask -ScriptPath (Join-Path $InstallRoot 'scripts\Invoke-BraveLockerVaultTask.ps1')
Write-Host 'Mount task re-registered.'

if (Get-BraveLockerPropertyValue -InputObject $config -Name 'AppLocked') {
    # The lock is on Brave's own shortcuts. Recreating "Brave (Private)" here
    # would put back the second browser the app lock exists to remove, so
    # instead re-apply the takeover - which also catches any fresh Brave
    # shortcut a browser update has dropped since the lock was applied.
    $vbs = Join-Path $InstallRoot 'scripts\BraveLockerLauncher.vbs'
    $backupDir = Join-Path $paths.StateRoot 'shortcut-backup'
    $unlocked = @(Get-BraveLockerBraveShortcut -BraveExe $config.BraveExe)

    if ($unlocked.Count -eq 0) {
        Write-Host 'Brave shortcuts are all still locked; nothing to re-point.'
    } else {
        foreach ($shortcut in $unlocked) {
            Set-BraveLockerShortcutToLauncher -ShortcutPath $shortcut -VbsPath $vbs `
                -BraveExe $config.BraveExe -BackupDir $backupDir
            Write-Host "  locked: $shortcut"
        }
    }
} else {
    New-BraveLockerShortcut -InstallRoot $InstallRoot -BraveExe $config.BraveExe -AlsoStartMenu | Out-Null
    Write-Host 'Shortcut refreshed - desktop and Start menu, no console window.'
}

Write-Host ''
Write-Host 'Update complete. Your vault, profile and passphrase are unchanged.' -ForegroundColor Green
