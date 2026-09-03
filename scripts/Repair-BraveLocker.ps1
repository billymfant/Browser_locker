#Requires -Version 5.1
<#
    Repairs the two things that stop the launcher running at all.

    Both were found on a live install and neither can be fixed from inside the
    launcher, because in both states the launcher either never starts or stops
    before it can ask for anything.

    1. THE SHORTCUT. Brave's updater rewrites its own Start menu shortcut when
       it updates itself: it resets TargetPath to brave.exe and leaves the
       Arguments alone. A shortcut the locker owns comes out of that pointing at
       brave.exe with the launcher's .vbs as an argument - so clicking Brave
       runs Brave directly and the passphrase prompt never appears. Repointing
       it needs administrator rights, because the shortcut lives under
       ProgramData.

    2. THE STALE MOUNT POINT. When a session ends without a dismount - a crash,
       a forced shutdown - the vault detaches but the directory mount point on
       the profile folder stays behind, now pointing at a volume that no longer
       exists. Nothing else can clear it: the normal dismount removes the mount
       point with Remove-PartitionAccessPath, which needs the vault ATTACHED,
       and it never will be again. Until it is deleted the launcher stops at
       "something is already mounted" before the passphrase prompt, and a
       restart does not help.

    Nothing here deletes data. The mount point is a link to a volume that is
    gone; the vault file and the original shortcut are untouched.
#>
[CmdletBinding()]
param(
    # Set on the elevated relaunch. Not for callers.
    [switch]$Elevated
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$logPath = Join-Path (Join-Path $env:LOCALAPPDATA 'BraveLocker') 'repair.log'

# --- Self-elevate -----------------------------------------------------------
# Same pattern as gui\BrowserLockerWizard.ps1. The window is left visible: this
# script reports what it changed and the user should be able to read it.
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$isAdmin = (New-Object Security.Principal.WindowsPrincipal($identity)).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin -and -not $Elevated) {
    Write-Host 'Asking for administrator rights (the Brave shortcut lives under ProgramData)...'
    $process = Start-Process -FilePath 'powershell.exe' -Verb RunAs -PassThru -Wait -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass',
        '-File', "`"$PSCommandPath`"", '-Elevated'
    )

    # The elevated run is a separate process with its own console, so its output
    # is not this window's to show. It logs instead, and this reads the log back.
    if (Test-Path $logPath) {
        Write-Host ''
        Get-Content -Path $logPath | ForEach-Object { Write-Host $_ }
    }
    if ($process.ExitCode -ne 0) {
        Write-Host ''
        Write-Host "The repair exited with code $($process.ExitCode)." -ForegroundColor Red
    }
    return
}

Import-Module (Join-Path $repoRoot 'src\BraveLocker\BraveLocker.psd1') -Force

$lines = New-Object System.Collections.Generic.List[string]
function Write-Step {
    param([string]$Text, [string]$Colour = 'Gray')
    $lines.Add($Text)
    Write-Host $Text -ForegroundColor $Colour
}

Write-Step ''
Write-Step "Brave Locker - repair  ($(Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))" 'Cyan'
Write-Step '======================' 'Cyan'
Write-Step ''

try {
    $paths = Get-BraveLockerPaths
    if (-not (Test-Path $paths.ConfigPath)) {
        throw 'Brave Locker is not set up on this PC. Nothing to repair.'
    }
    $config = Get-Content -Path $paths.ConfigPath -Raw | ConvertFrom-Json

    $mountFolder = [string](Get-BraveLockerPropertyValue -InputObject $config -Name 'ProfileMountPath')
    $vhdxPath    = [string](Get-BraveLockerPropertyValue -InputObject $config -Name 'VhdxPath')
    $installRoot = [string](Get-BraveLockerPropertyValue -InputObject $config -Name 'InstallRoot')

    # Older configs predate the browser choice and carry BraveExe.
    $browserExe = [string](Get-BraveLockerPropertyValue -InputObject $config -Name 'BrowserExe')
    if (-not $browserExe) { $browserExe = [string](Get-BraveLockerPropertyValue -InputObject $config -Name 'BraveExe') }

    if ([string]::IsNullOrWhiteSpace($installRoot)) { $installRoot = 'C:\Program Files\BraveLocker' }

    # --- Guard: never touch a mount point that is actually live -------------
    # Deleting the reparse point of a MOUNTED volume would orphan the vault
    # while it is open. The whole repair depends on the vault being detached.
    if (Test-BraveLockerVaultMounted -VhdxPath $vhdxPath) {
        Write-Step 'The vault is currently OPEN.' 'Yellow'
        Write-Step ''
        Write-Step 'Close Brave and let the launcher seal the vault, then run this again.'
        Write-Step 'Nothing has been changed.'
        $lines | Set-Content -Path $logPath -Encoding utf8
        return
    }

    # --- 1. Clear a stale mount point ---------------------------------------
    Write-Step '1. Profile folder' 'Cyan'

    $cleared = $false
    $item = Get-Item -Path $mountFolder -Force -ErrorAction SilentlyContinue

    if ($null -eq $item) {
        Write-Step "   Not present - the launcher will create it. Nothing to do."
    } elseif (-not ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
        Write-Step "   Ordinary folder, nothing stale to clear."
    } else {
        # A reparse point with the vault detached is by definition stale: the
        # volume it names is not attached, so nothing can be reached through it.
        Write-Step "   Stale mount point found at:"
        Write-Step "     $mountFolder"

        $result = Clear-BraveLockerStaleMountPoint -Path $mountFolder
        if (-not $result.Cleared) {
            throw "Could not delete the stale mount point: $($result.Error)"
        }

        $cleared = $true
        Write-Step "   Cleared. The folder is now an ordinary empty folder." 'Green'
    }

    # --- 2. Repoint the shortcuts -------------------------------------------
    Write-Step ''
    Write-Step '2. Brave shortcuts' 'Cyan'

    $vbs = Join-Path $installRoot 'scripts\BraveLockerLauncher.vbs'
    if (-not (Test-Path $vbs)) {
        throw "The launcher is missing from the installed copy: '$vbs'."
    }
    $backupDir = Join-Path $paths.StateRoot 'shortcut-backup'

    # The manifest lists what the locker took over. Discovery is added on top of
    # it because an updater can create a NEW shortcut the manifest never saw.
    $candidates = New-Object System.Collections.Generic.List[string]
    foreach ($entry in @(Get-BraveLockerShortcutManifest -BackupDir $backupDir)) {
        if (-not $candidates.Contains($entry)) { $candidates.Add($entry) }
    }
    foreach ($entry in @(Get-BraveLockerBraveShortcut -BraveExe $browserExe)) {
        if (-not $candidates.Contains($entry)) { $candidates.Add($entry) }
    }

    $shell = New-Object -ComObject WScript.Shell
    $hijacked = @(Get-BraveLockerHijackedShortcut -ShortcutPath $candidates.ToArray())
    $repointed = 0

    if ($candidates.Count -eq 0) {
        Write-Step '   No Brave shortcuts found.' 'Yellow'
    } elseif ($hijacked.Count -eq 0) {
        Write-Step "   All $($candidates.Count) shortcut(s) already point at the launcher."
    }

    foreach ($shortcut in $hijacked) {
        $target = ''
        try { $target = [string]$shell.CreateShortcut($shortcut).TargetPath } catch { $target = '' }

        Set-BraveLockerShortcutToLauncher -ShortcutPath $shortcut -VbsPath $vbs `
            -BraveExe $browserExe -BackupDir $backupDir
        $repointed++
        Write-Step "   repointed: $shortcut" 'Green'
        Write-Step "     was -> $target"
    }

    # --- 3. Keep it repaired -------------------------------------------------
    # Without this the next browser update takes the lock straight back off.
    Write-Step ''
    Write-Step '3. Shortcut guard' 'Cyan'

    $guardScript = Join-Path $installRoot 'scripts\Invoke-BraveLockerShortcutGuard.ps1'
    if (-not (Test-Path $guardScript)) {
        Write-Step '   Not in the installed copy yet - run Set-BraveLockerAppLock.ps1' 'Yellow'
        Write-Step '   to refresh the install and register it.' 'Yellow'
    } else {
        Register-BraveLockerShortcutGuardTask -ScriptPath $guardScript
        Write-Step '   Registered: re-locks the shortcuts at every logon.' 'Green'
    }

    # --- 4. The way out ------------------------------------------------------
    Write-Step ''
    Write-Step '4. Emergency card' 'Cyan'

    $cardSource = Join-Path $repoRoot 'docs\EMERGENCY-CARD.md'
    if (-not (Test-Path $cardSource)) {
        # An install refreshed from a copy that had no docs folder.
        $cardSource = Join-Path $installRoot 'Browser Locker - Emergency Card.txt'
    }
    if (Test-Path $cardSource) {
        $rescue = Install-BraveLockerRescueItems -InstallRoot $installRoot -CardSourcePath $cardSource
        Write-Step "   Installed: $($rescue.CardPath)" 'Green'
        Write-Step '   Start menu: "Browser Locker - Emergency Card" and "- Repair"' 'Green'
    } else {
        Write-Step '   Card source not found; skipped.' 'Yellow'
    }

    # --- Summary -------------------------------------------------------------
    Write-Step ''
    Write-Step 'Done.' 'Green'
    Write-Step ''
    if ($cleared) { Write-Step '  - cleared a stale mount point on the profile folder' }
    if ($repointed -gt 0) { Write-Step "  - repointed $repointed shortcut(s) back at the launcher" }
    if (-not $cleared -and $repointed -eq 0) {
        Write-Step '  - nothing needed repairing'
    } else {
        Write-Step ''
        Write-Step 'Click Brave the way you always do. It will ask for your passphrase.'
    }
}
catch {
    Write-Step ''
    Write-Step "The repair could not finish: $($_.Exception.Message)" 'Red'
    Write-Step 'Nothing further has been changed.'
    $lines | Set-Content -Path $logPath -Encoding utf8
    throw
}

$lines | Set-Content -Path $logPath -Encoding utf8
