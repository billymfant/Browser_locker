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

# No guessed defaults. The config records where the vault actually is; without
# it, guessing a path means either deleting nothing and reporting success, or
# reaching for a file that belongs to something else.
$vhdxPath = ''
$braveExe = ''
$sourceProfile = ''
if ($config) {
    $vhdxPath = [string](Get-BraveLockerPropertyValue -InputObject $config -Name 'VhdxPath')
    $braveExe = [string](Get-BraveLockerPropertyValue -InputObject $config -Name 'BraveExe')

    # PreMigrationPath is the current layout. SourceProfilePath is what earlier
    # versions wrote, when the profile was copied elsewhere rather than the
    # vault being mounted over it - an install from then must still uninstall.
    foreach ($name in 'PreMigrationPath', 'SourceProfilePath') {
        $candidate = [string](Get-BraveLockerPropertyValue -InputObject $config -Name $name)
        if (-not [string]::IsNullOrWhiteSpace($candidate)) {
            $sourceProfile = $candidate
            break
        }
    }
}

if (-not $config) {
    Write-Host 'No Browser Locker configuration was found on this PC.' -ForegroundColor Yellow
    Write-Host 'Without it there is no record of where the vault lives or which browser'
    Write-Host 'was locked, so there is nothing safe to remove automatically.'
    Write-Host ''
    Write-Host 'If a vault file exists, delete it by hand once you have copied your'
    Write-Host 'profile out of it - and restore your browser shortcuts from'
    Write-Host "  $(Join-Path $paths.StateRoot 'shortcut-backup')" -ForegroundColor Cyan
    return
}

if ([string]::IsNullOrWhiteSpace($sourceProfile)) {
    $sourceProfile = Join-Path $env:LOCALAPPDATA 'BraveSoftware\Brave-Browser\User Data'
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
$takenOver = @(Get-BraveLockerShortcutManifest -BackupDir $backupDir)

if ($takenOver.Count -eq 0) {
    Write-Host '  no shortcut backups found'
} else {
    $restored = 0
    $failed = @()
    foreach ($shortcut in $takenOver) {
        try {
            Restore-BraveLockerShortcut -ShortcutPath $shortcut -BackupDir $backupDir
            Write-Host "  restored: $shortcut"
            $restored++
        } catch {
            $failed += $shortcut
        }
    }
    if ($restored -eq 0) { Write-Host '  no shortcut backups matched; nothing to restore' }
    foreach ($shortcut in $failed) {
        # Named individually: a shortcut left pointing at a launcher that is
        # about to be deleted would simply stop working, so the user has to
        # know which one to recreate.
        Write-Host "  COULD NOT restore '$shortcut' - recreate it by hand from Brave" -ForegroundColor Yellow
    }
}

# --- 1b. Remove the rescue shortcuts ---------------------------------------
foreach ($name in 'Browser Locker - Emergency Card.lnk', 'Browser Locker - Repair.lnk') {
    $link = Join-Path ([Environment]::GetFolderPath('CommonPrograms')) $name
    if (Test-Path $link) {
        Remove-Item -Path $link -Force -ErrorAction SilentlyContinue
        Write-Host "  removed: $link"
    }
}

# --- 2. Remove any leftover private shortcuts ------------------------------
foreach ($folder in ([Environment]::GetFolderPath('Desktop')), ([Environment]::GetFolderPath('Programs'))) {
    $stale = Join-Path $folder 'Brave (Private).lnk'
    if (Test-Path $stale) {
        Remove-Item -Path $stale -Force
        Write-Host "  removed: $stale"
    }
}

# --- 3. Scheduled tasks -----------------------------------------------------
foreach ($taskName in 'BraveLocker-Mount', 'BraveLocker-ShortcutGuard') {
    if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
        Write-Host "  removed the scheduled task: $taskName"
    }
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

# --- 5. Put Brave's profile folder back ------------------------------------
# Setup renamed the original aside and mounted the vault in its place. With the
# vault detached, that leaves an empty folder where Brave expects its profile.
$profileMountPath = ''
if ($config) {
    $profileMountPath = [string](Get-BraveLockerPropertyValue -InputObject $config -Name 'ProfileMountPath')
}

if ($profileMountPath -and $sourceProfile -and (Test-Path $sourceProfile)) {
    if (Test-Path $profileMountPath) {
        $leftover = @(Get-ChildItem -Path $profileMountPath -Force -ErrorAction SilentlyContinue)
        if ($leftover.Count -eq 0) {
            Remove-Item -Path $profileMountPath -Force -ErrorAction SilentlyContinue
        } else {
            # Something browsed here without the locker. Keep it - it is a real
            # profile - and let the rename below fail loudly rather than merge.
            $stray = "$profileMountPath.stray-$((Get-Date).ToString('yyyyMMdd-HHmmss'))"
            Rename-Item -Path $profileMountPath -NewName (Split-Path -Leaf $stray) -ErrorAction SilentlyContinue
            Write-Host "  a profile was left at the mount folder; kept as $stray" -ForegroundColor Yellow
        }
    }

    if (-not (Test-Path $profileMountPath)) {
        Rename-Item -Path $sourceProfile -NewName (Split-Path -Leaf $profileMountPath) -ErrorAction Stop
        Write-Host "  restored your original Brave profile to $profileMountPath"
    } else {
        Write-Host "  could NOT restore the profile - '$profileMountPath' is still in the way" -ForegroundColor Yellow
        Write-Host "  your profile is safe at $sourceProfile - rename it back by hand" -ForegroundColor Yellow
    }
}

# --- 6. Folders -------------------------------------------------------------
# $MountFolder is the legacy hidden-mount location from an earlier version. The
# profile mount folder is NEVER listed here - deleting it would take Brave's
# profile with it.
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
