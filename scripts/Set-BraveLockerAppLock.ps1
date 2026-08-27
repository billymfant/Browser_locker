#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
    Turns Brave Locker from "a separate private browser" into "a lock on Brave".

      - Your real Brave shortcuts launch the locker instead (same name, same icon).
      - The extra "Brave (Private)" shortcuts are removed.
      - The vault stops appearing as a drive: it mounts to a hidden folder, and
        the volume label stops saying BraveVault.

    The mount change is verified before it is kept. If the vault cannot be
    unlocked through the new hidden path, everything is put back the way it was.
#>
[CmdletBinding()]
param(
    [string]$InstallRoot = 'C:\Program Files\BraveLocker',
    [string]$MountFolder = 'C:\ProgramData\BraveLocker\data'
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
Write-Host 'I need your vault passphrase to check the vault still opens after the change.'
Write-Host 'If it does not, everything is put back exactly as it is now.'
Write-Host ''
$passphrase = Read-Host -Prompt 'Vault passphrase' -AsSecureString

# --- 1. Refresh the installed copy -----------------------------------------
Write-Host ''
Write-Host "Updating $InstallRoot ..."
foreach ($sub in 'src', 'scripts') {
    $target = Join-Path $InstallRoot $sub
    if (Test-Path $target) { Remove-Item -Path $target -Recurse -Force }
    New-Item -ItemType Directory -Path $target -Force | Out-Null
    Copy-Item -Path (Join-Path $repoRoot "$sub\*") -Destination $target -Recurse -Force
}
Set-BraveLockerScriptAcl -Path $InstallRoot
Register-BraveLockerMountTask -ScriptPath (Join-Path $InstallRoot 'scripts\Invoke-BraveLockerVaultTask.ps1')
Write-Host 'Installed copy refreshed and verified.'

# --- 2. Hide the vault: folder mount point instead of a drive letter --------
Write-Host ''
Write-Host 'Hiding the vault drive...'

if (-not (Test-Path $MountFolder)) {
    New-Item -ItemType Directory -Path $MountFolder -Force | Out-Null
}
# A mount-point folder must be empty, and it should not invite browsing.
(Get-Item $MountFolder).Attributes = 'Directory, Hidden'

Mount-DiskImage -ImagePath $config.VhdxPath -StorageType VHDX -ErrorAction Stop | Out-Null
$partition = Get-DiskImage -ImagePath $config.VhdxPath | Get-Disk | Get-Partition |
    Where-Object { $_.Type -ne 'Reserved' } | Select-Object -First 1

$originalLetter = $partition.DriveLetter
$mountOk = $false

try {
    Add-PartitionAccessPath -DiskNumber $partition.DiskNumber -PartitionNumber $partition.PartitionNumber `
        -AccessPath $MountFolder -ErrorAction Stop

    if ($originalLetter) {
        Remove-PartitionAccessPath -DiskNumber $partition.DiskNumber -PartitionNumber $partition.PartitionNumber `
            -AccessPath "${originalLetter}:\" -ErrorAction Stop
    }

    # Prove it: unlock through the hidden path and read the profile back.
    if (-not (Unlock-BraveLockerVault -DriveLetter $MountFolder -Passphrase $passphrase)) {
        throw 'The vault would not unlock through the hidden folder path.'
    }

    $profileCheck = Join-Path $MountFolder $config.ProfileDirName
    if (-not (Test-Path $profileCheck)) {
        throw "Unlocked, but the profile was not visible at '$profileCheck'."
    }

    Write-Host 'Verified: the vault opens through the hidden folder and the profile is there.' -ForegroundColor Green
    $mountOk = $true

} catch {
    Write-Host ''
    Write-Host "Could not hide the drive: $($_.Exception.Message)" -ForegroundColor Yellow
    Write-Host 'Putting the drive letter back. Nothing is lost - the vault still works as before.' -ForegroundColor Yellow

    try {
        if ($originalLetter) {
            Add-PartitionAccessPath -DiskNumber $partition.DiskNumber -PartitionNumber $partition.PartitionNumber `
                -AccessPath "${originalLetter}:\" -ErrorAction SilentlyContinue
        }
        Remove-PartitionAccessPath -DiskNumber $partition.DiskNumber -PartitionNumber $partition.PartitionNumber `
            -AccessPath $MountFolder -ErrorAction SilentlyContinue
    } catch {
        Write-Host 'Rollback of the access paths reported a problem; check Disk Management.' -ForegroundColor Yellow
    }
}

# --- 3. Drop the BraveVault label ------------------------------------------
if ($mountOk) {
    try {
        $volume = Get-Volume -FilePath $MountFolder -ErrorAction Stop
        Set-Volume -UniqueId $volume.UniqueId -NewFileSystemLabel 'Data' -ErrorAction Stop
        Write-Host 'Volume label changed from BraveVault to Data.'
    } catch {
        Write-Host "Could not relabel the volume: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

Lock-BitLocker -MountPoint $(if ($mountOk) { $MountFolder } else { "${originalLetter}:" }) -ErrorAction SilentlyContinue | Out-Null
Dismount-BraveLockerVault -VhdxPath $config.VhdxPath

# --- 4. Save the new mount path --------------------------------------------
$config | Add-Member -NotePropertyName 'MountPath' -NotePropertyValue $(if ($mountOk) { $MountFolder } else { '' }) -Force
$config | ConvertTo-Json -Depth 5 | Set-Content -Path $paths.ConfigPath -Encoding utf8

# --- 5. Take over the real Brave shortcuts ---------------------------------
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

# --- 6. Remove the separate private shortcuts ------------------------------
foreach ($folder in ([Environment]::GetFolderPath('Desktop')), ([Environment]::GetFolderPath('Programs'))) {
    $stale = Join-Path $folder 'Brave (Private).lnk'
    if (Test-Path $stale) {
        Remove-Item -Path $stale -Force
        Write-Host "  removed: $stale"
    }
}

Write-Host ''
Write-Host 'Done.' -ForegroundColor Green
Write-Host 'Click Brave the way you always do. It will ask for your passphrase first.'
if (-not $mountOk) {
    Write-Host ''
    Write-Host 'Note: the vault still uses a drive letter while Brave is open.' -ForegroundColor Yellow
    Write-Host 'Everything else works; it just is not invisible yet.' -ForegroundColor Yellow
}
