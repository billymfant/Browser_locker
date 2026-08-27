#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
    Removes Brave Locker completely and puts the machine back how it was:
    Brave's own shortcuts restored, the scheduled task gone, the vault deleted.

    It refuses to run if your original unencrypted profile is missing, because
    in that case the vault holds the only copy of your logins and cards and
    deleting it would be permanent. Override only if you truly mean it.
#>
[CmdletBinding()]
param(
    [string]$InstallRoot = 'C:\Program Files\BraveLocker',
    [string]$MountFolder = 'C:\ProgramData\BraveLocker',
    [switch]$Force,
    [switch]$IAcceptLosingTheVaultData
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $repoRoot 'src\BraveLocker\BraveLocker.psd1') -Force

$paths = Get-BraveLockerPaths
$config = $null
if (Test-Path $paths.ConfigPath) {
    $config = Get-Content -Path $paths.ConfigPath -Raw | ConvertFrom-Json
}

$vhdxPath = 'D:\apps\brave_locker\vault.vhdx'
$braveExe = 'C:\Program Files\BraveSoftware\Brave-Browser\Application\brave.exe'
$sourceProfile = Join-Path $env:LOCALAPPDATA 'BraveSoftware\Brave-Browser\User Data'
if ($config) {
    $vhdxPath = [string](Get-BraveLockerPropertyValue -InputObject $config -Name 'VhdxPath')
    $braveExe = [string](Get-BraveLockerPropertyValue -InputObject $config -Name 'BraveExe')
    $sourceProfile = [string](Get-BraveLockerPropertyValue -InputObject $config -Name 'SourceProfilePath')
}

Write-Host ''
Write-Host 'Brave Locker - uninstall' -ForegroundColor Cyan
Write-Host '========================'
Write-Host ''

if (@(Get-Process -Name 'brave' -ErrorAction SilentlyContinue).Count -gt 0) {
    throw 'Close Brave completely before uninstalling.'
}

# --- Safety: is the vault the only copy of the data? -----------------------
$safety = Test-BraveLockerSafeToRemoveVault -SourceProfilePath $sourceProfile

if ($safety.IsSafe) {
    Write-Host "Your original Brave profile is intact ($($safety.FileCount) files) at:"
    Write-Host "  $sourceProfile"
    Write-Host 'Deleting the vault therefore costs you nothing - that profile is your data.'
} else {
    Write-Host 'STOP - the vault may be the only copy of your Brave data.' -ForegroundColor Red
    Write-Host ''
    if ($safety.Reason -eq 'OriginalProfileMissing') {
        Write-Host "Your original profile at '$sourceProfile' is gone, which means the"
        Write-Host 'cleanup step was already run and everything lives inside the vault.'
    } else {
        Write-Host "Your original profile exists but holds only $($safety.FileCount) files,"
        Write-Host 'which does not look like a real Brave profile.'
    }
    Write-Host ''
    Write-Host 'Deleting the vault now would permanently destroy your logins, saved'
    Write-Host 'passwords and cards. Copy them out of the vault first: open Brave with'
    Write-Host 'your passphrase, then export what you need.'
    Write-Host ''

    if (-not $IAcceptLosingTheVaultData) {
        throw 'Refusing to uninstall. Re-run with -IAcceptLosingTheVaultData only if you accept losing everything in the vault.'
    }
    Write-Host 'Continuing anyway, because -IAcceptLosingTheVaultData was given.' -ForegroundColor Yellow
}

if (-not $Force) {
    Write-Host ''
    $answer = Read-Host 'Type REMOVE to uninstall Brave Locker'
    if ($answer -ne 'REMOVE') {
        Write-Host 'Cancelled. Nothing was changed.' -ForegroundColor Yellow
        return
    }
}

# --- 1. Restore Brave's own shortcuts (before deleting the backups) --------
Write-Host ''
$backupDir = Join-Path $paths.StateRoot 'shortcut-backup'
if (Test-Path $backupDir) {
    $restored = 0
    # Restore every shortcut we hold a backup for, wherever it lives.
    foreach ($candidate in @(
            (Join-Path ([Environment]::GetFolderPath('Desktop')) 'Brave.lnk')
            (Join-Path ([Environment]::GetFolderPath('CommonDesktopDirectory')) 'Brave.lnk')
            (Join-Path ([Environment]::GetFolderPath('Programs')) 'Brave.lnk')
            (Join-Path ([Environment]::GetFolderPath('CommonPrograms')) 'Brave.lnk')
            (Join-Path $env:APPDATA 'Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar\Brave.lnk')
        )) {
        $backupPath = Get-BraveLockerShortcutBackupPath -ShortcutPath $candidate -BackupDir $backupDir
        if (Test-Path $backupPath) {
            Copy-Item -Path $backupPath -Destination $candidate -Force
            Write-Host "  restored: $candidate"
            $restored++
        }
    }
    if ($restored -eq 0) { Write-Host '  no shortcut backups matched; nothing to restore' }
} else {
    Write-Host '  no shortcut backups found'
}

# --- 2. Remove any leftover private shortcuts ------------------------------
foreach ($folder in ([Environment]::GetFolderPath('Desktop')), ([Environment]::GetFolderPath('Programs'))) {
    $stale = Join-Path $folder 'Brave (Private).lnk'
    if (Test-Path $stale) {
        Remove-Item -Path $stale -Force
        Write-Host "  removed: $stale"
    }
}

# --- 3. Scheduled task ------------------------------------------------------
if (Get-ScheduledTask -TaskName 'BraveLocker-Mount' -ErrorAction SilentlyContinue) {
    Unregister-ScheduledTask -TaskName 'BraveLocker-Mount' -Confirm:$false
    Write-Host '  removed the scheduled task'
}

# --- 4. Detach and delete the vault ----------------------------------------
if ($vhdxPath -and (Test-Path $vhdxPath)) {
    if (Test-BraveLockerVaultMounted -VhdxPath $vhdxPath) {
        Dismount-DiskImage -ImagePath $vhdxPath -ErrorAction SilentlyContinue | Out-Null
        Write-Host '  detached the vault'
    }
    Remove-Item -Path $vhdxPath -Force
    Write-Host "  deleted $vhdxPath"
}

# --- 5. Folders -------------------------------------------------------------
foreach ($folder in @($InstallRoot, $MountFolder, $paths.StateRoot)) {
    if ($folder -and (Test-Path $folder)) {
        Remove-Item -Path $folder -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "  removed $folder"
    }
}

Write-Host ''
Write-Host 'Brave Locker is gone.' -ForegroundColor Green
Write-Host 'Brave opens normally again, with your original profile and no password.'
Write-Host ''
Write-Host 'To set it up fresh with a new passcode:' -ForegroundColor Cyan
Write-Host '  .\scripts\Install-BraveLocker.ps1'
Write-Host '  .\scripts\Set-BraveLockerAppLock.ps1'
