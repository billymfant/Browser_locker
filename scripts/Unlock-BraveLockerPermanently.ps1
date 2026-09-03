#Requires -Version 5.1
<#
    Turns the lock off and gives you your profile back as an ordinary folder.

    This is the deliberate way out. It is NOT the uninstaller:

      Uninstall-BraveLocker.ps1 restores the copy of your profile that was
      taken before migration and then DELETES the vault. Everything done in
      the browser since setup lives only in the vault, so that path throws it
      away. It is the right tool immediately after a setup you regret, and the
      wrong one at any point after that.

      This script takes the CURRENT profile out of the vault, puts it back
      where the browser expects it, and leaves the vault file alone.

    The order is chosen so that nothing is dismantled until the data is safely
    out and checked:

        unlock -> copy out -> VERIFY the copy -> put it in place -> stand down

    The vault is never deleted here, by any path. Once you are satisfied your
    profile is back you can delete it yourself; until then it is a complete
    encrypted backup, and this script would rather leave a spare copy behind
    than be clever.
#>
[CmdletBinding()]
param(
    # Set on the elevated relaunch. Not for callers.
    [switch]$Elevated
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot

# --- Self-elevate -----------------------------------------------------------
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$isAdmin = (New-Object Security.Principal.WindowsPrincipal($identity)).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin -and -not $Elevated) {
    $process = Start-Process -FilePath 'powershell.exe' -Verb RunAs -PassThru -Wait -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-NoExit',
        '-File', "`"$PSCommandPath`"", '-Elevated'
    )
    if ($process.ExitCode -ne 0) {
        Write-Host "Turning the lock off exited with code $($process.ExitCode)." -ForegroundColor Red
    }
    return
}

Import-Module (Join-Path $repoRoot 'src\BraveLocker\BraveLocker.psd1') -Force

Write-Host ''
Write-Host 'Turn the lock off, and keep your data' -ForegroundColor Cyan
Write-Host '=====================================' -ForegroundColor Cyan
Write-Host ''

$paths = Get-BraveLockerPaths
if (-not (Test-Path $paths.ConfigPath)) {
    Write-Host 'There is no Browser Locker setup on this PC, so there is no lock to turn off.' -ForegroundColor Yellow
    Write-Host 'If your browser will not open, that is a different problem.'
    return
}

$config      = Get-Content -Path $paths.ConfigPath -Raw | ConvertFrom-Json
$vhdxPath    = [string](Get-BraveLockerPropertyValue -InputObject $config -Name 'VhdxPath')
$mountFolder = [string](Get-BraveLockerPropertyValue -InputObject $config -Name 'ProfileMountPath')

$browserExe = [string](Get-BraveLockerPropertyValue -InputObject $config -Name 'BrowserExe')
if (-not $browserExe) { $browserExe = [string](Get-BraveLockerPropertyValue -InputObject $config -Name 'BraveExe') }
$browserExeName = [string](Get-BraveLockerPropertyValue -InputObject $config -Name 'BrowserExeName')
if (-not $browserExeName) { $browserExeName = 'brave.exe' }
$browserName = [string](Get-BraveLockerPropertyValue -InputObject $config -Name 'BrowserName')
if (-not $browserName) { $browserName = 'Brave' }

$processName = [System.IO.Path]::GetFileNameWithoutExtension($browserExeName)

if (-not (Test-Path $vhdxPath)) {
    Write-Host "The vault file is missing:" -ForegroundColor Red
    Write-Host "  $vhdxPath"
    Write-Host ''
    Write-Host 'Without it there is nothing to copy your profile out of. If you have a'
    Write-Host 'backup of that file, put it back and run this again.'
    return
}

if (@(Get-Process -Name $processName -ErrorAction SilentlyContinue).Count -gt 0) {
    Write-Host "Close $browserName completely first, then run this again." -ForegroundColor Yellow
    return
}

Write-Host "This will:"
Write-Host "  1. open the vault with your passphrase"
Write-Host "  2. copy your profile out of it into an ordinary folder"
Write-Host "  3. put your original $browserName shortcut back"
Write-Host "  4. stop the locker running at startup"
Write-Host ''
Write-Host "Your vault file is NOT deleted. It stays as an encrypted backup at" -ForegroundColor Green
Write-Host "  $vhdxPath" -ForegroundColor Green
Write-Host ''
Write-Host "Afterwards $browserName opens normally, with no passphrase, and anyone"
Write-Host "using this PC can see your profile." -ForegroundColor Yellow
Write-Host ''

$answer = Read-Host 'Type OFF to continue, or anything else to cancel'
if ($answer -ne 'OFF') {
    Write-Host 'Cancelled. Nothing was changed.' -ForegroundColor Yellow
    return
}

# --- 1. Open the vault ------------------------------------------------------
Write-Host ''
Write-Host 'Step 1 of 5: opening the vault' -ForegroundColor Cyan

$passphrase = Show-BraveLockerPassphrasePrompt -Title $browserName -IconSource $browserExe `
    -Note 'Needed once, to copy your profile out of the vault.'
if ($null -eq $passphrase) {
    Write-Host 'Cancelled. Nothing was changed.' -ForegroundColor Yellow
    return
}

$attached = $false
$letter = ''
try {
    if (-not (Test-BraveLockerVaultMounted -VhdxPath $vhdxPath)) {
        Mount-DiskImage -ImagePath $vhdxPath -StorageType VHDX -ErrorAction Stop | Out-Null
    }
    $attached = $true

    # Through a drive letter, not the profile folder: the folder may still be
    # carrying a mount point from a session that never dismounted, and the
    # point of this script is to work when things are already broken.
    $letter = Add-BraveLockerVaultDriveLetter -VhdxPath $vhdxPath

    $attempt = Invoke-BraveLockerUnlockAttempt -MountPoint $letter -Passphrase $passphrase
    if (-not $attempt.Unlocked) {
        if ($attempt.Reason -eq 'WrongPassphrase') {
            Write-Host ''
            Write-Host 'That passphrase was not accepted, so the vault stays sealed.' -ForegroundColor Red
            Write-Host 'Nothing has been changed. Run this again to retry.'
            Write-Host ''
            Write-Host 'If the passphrase is genuinely lost, your BitLocker recovery key is'
            Write-Host 'the way in - the one setup made you save off this PC. See the'
            Write-Host 'emergency card: docs\EMERGENCY-CARD.md'
        } else {
            Write-Host ''
            Write-Host 'The vault did not open, and this was not your passphrase:' -ForegroundColor Red
            Write-Host "  $($attempt.Error)"
            Write-Host 'Nothing has been changed.'
        }
        return
    }
    Write-Host "  opened at ${letter}:"

    # --- 2. Copy the profile out --------------------------------------------
    Write-Host ''
    Write-Host 'Step 2 of 5: copying your profile out' -ForegroundColor Cyan

    $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
    $staging = "$mountFolder.unlocked-$stamp"
    Write-Host "  to $staging"
    Write-Host '  (this can take a while for a large profile)'

    # robocopy rather than Copy-Item: it handles the long paths and the many
    # small files a browser profile is made of, and reports what it did.
    $robocopy = Join-Path $env:WINDIR 'System32\robocopy.exe'
    & $robocopy "${letter}:\" $staging /E /COPY:DAT /R:1 /W:1 /NFL /NDL /NJH /NJS | Out-Null

    # robocopy uses 0-7 for success; 8 and above is a real failure.
    if ($LASTEXITCODE -ge 8) {
        throw "Copying the profile out of the vault failed (robocopy exit $LASTEXITCODE). Nothing has been changed - the vault is untouched."
    }

    # --- 3. Verify the copy BEFORE anything is taken apart -------------------
    Write-Host ''
    Write-Host 'Step 3 of 5: checking the copy' -ForegroundColor Cyan

    $copied = @(Get-ChildItem -Path $staging -Recurse -Force -ErrorAction SilentlyContinue)
    $localState = Join-Path $staging 'Local State'

    if (-not (Test-Path $localState)) {
        throw "The copy at '$staging' has no 'Local State' file, so it is not a complete profile. Nothing has been changed and the vault is untouched - the copy has been left in place for you to look at."
    }
    if ($copied.Count -lt 20) {
        throw "The copy at '$staging' holds only $($copied.Count) items, which is too few to be a real profile. Nothing has been changed and the vault is untouched."
    }
    Write-Host "  $($copied.Count) items copied, and 'Local State' is present"
}
finally {
    if ($attached) {
        if ($letter) {
            Remove-BraveLockerVaultDriveLetter -VhdxPath $vhdxPath -DriveLetter $letter -ErrorAction SilentlyContinue
        }
        Dismount-BraveLockerVault -VhdxPath $vhdxPath
        Write-Host '  vault sealed again'
    }
}

# --- 4. Put the profile where the browser looks for it ---------------------
Write-Host ''
Write-Host 'Step 4 of 5: putting your profile back' -ForegroundColor Cyan

# The mount folder is now a leftover mount point pointing at a vault that has
# just been detached. Clearing it is exactly the stale-mount-point case.
if (Test-BraveLockerStaleMountPoint -Path $mountFolder) {
    $cleared = Clear-BraveLockerStaleMountPoint -Path $mountFolder
    if (-not $cleared.Cleared) {
        throw "Could not clear the old mount point at '$mountFolder': $($cleared.Error). Your profile is safe at '$staging' - move it to '$mountFolder' by hand."
    }
    Write-Host '  cleared the old mount point'
}

if (Test-Path $mountFolder) {
    $leftover = @(Get-ChildItem -Path $mountFolder -Force -ErrorAction SilentlyContinue)
    if ($leftover.Count -eq 0) {
        Remove-Item -Path $mountFolder -Force -ErrorAction SilentlyContinue
    } else {
        # Something browsed here without the locker. It is a real profile, so
        # it is moved aside rather than merged or deleted.
        $stray = "$mountFolder.stray-$stamp"
        Rename-Item -Path $mountFolder -NewName (Split-Path -Leaf $stray) -ErrorAction Stop
        Write-Host "  a stray profile was in the way; kept at $stray" -ForegroundColor Yellow
    }
}

Rename-Item -Path $staging -NewName (Split-Path -Leaf $mountFolder) -ErrorAction Stop
Write-Host "  your profile is now at $mountFolder"

# --- 5. Stand the locker down ----------------------------------------------
Write-Host ''
Write-Host 'Step 5 of 5: standing the locker down' -ForegroundColor Cyan

$backupDir = Join-Path $paths.StateRoot 'shortcut-backup'
$restored = 0
foreach ($shortcut in @(Get-BraveLockerShortcutManifest -BackupDir $backupDir)) {
    try {
        Restore-BraveLockerShortcut -ShortcutPath $shortcut -BackupDir $backupDir
        Write-Host "  restored: $shortcut"
        $restored++
    } catch {
        Write-Host "  COULD NOT restore '$shortcut' - recreate it from $browserName by hand" -ForegroundColor Yellow
    }
}
if ($restored -eq 0) {
    Write-Host "  no shortcut backups found - if your $browserName shortcut still asks for" -ForegroundColor Yellow
    Write-Host '  a passphrase, delete it and make a new one from the browser itself.' -ForegroundColor Yellow
}

foreach ($taskName in 'BraveLocker-Mount', 'BraveLocker-ShortcutGuard') {
    if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
        Write-Host "  removed the scheduled task: $taskName"
    }
}

# The config is what tells the launcher there is a lock. Renaming rather than
# deleting it means a re-enable is possible, and means this script never
# destroys the only record of where the vault lives.
Rename-Item -Path $paths.ConfigPath -NewName "config.turned-off-$stamp.json" -ErrorAction SilentlyContinue
Write-Host '  the launcher will no longer ask for a passphrase'

Write-Host ''
Write-Host 'Done. The lock is off.' -ForegroundColor Green
Write-Host ''
Write-Host "$browserName now opens normally, with your profile and no passphrase."
Write-Host ''
Write-Host 'Your vault has NOT been deleted. It is still encrypted, and still needs' -ForegroundColor Cyan
Write-Host 'your passphrase or recovery key to open:' -ForegroundColor Cyan
Write-Host "  $vhdxPath" -ForegroundColor Cyan
Write-Host ''
Write-Host 'Once you have opened the browser and checked everything is there, you can'
Write-Host 'delete that file to reclaim the space. Until then it is your backup.'
Write-Host ''
Read-Host 'Press Enter to close'
