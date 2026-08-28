#Requires -Version 5.1
<#
    The everyday launcher. Shows a passphrase popup, opens the vault onto
    Brave's own profile folder, starts Brave, and seals the vault when Brave
    closes.

    It runs with no console window: everything the user sees is the popup and
    then Brave itself. Failures are reported through message boxes, never to a
    console nobody is looking at.

    Brave is started with NO --user-data-dir. That is deliberate and load
    bearing: Brave's App-Bound Encryption ties cookies and saved passwords to
    the profile path, so a profile reached by any other path decrypts nothing
    and every account appears logged out. The vault is mounted onto the path
    Brave already uses instead of the profile being moved somewhere else.

    A wrong passphrase is never destructive: nothing is decrypted, nothing is
    deleted, the attempt is logged and the next try is delayed.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $repoRoot 'src\BraveLocker\BraveLocker.psd1') -Force

$paths = Get-BraveLockerPaths
if (-not (Test-Path $paths.ConfigPath)) {
    Show-BraveLockerMessage -Icon 'Warning' -Message @'
Brave Locker is not set up on this PC yet.

Run Install-BraveLocker.ps1 from an administrator PowerShell first.
'@
    return
}
$config = Get-Content -Path $paths.ConfigPath -Raw | ConvertFrom-Json
$mountFolder = [string](Get-BraveLockerPropertyValue -InputObject $config -Name 'ProfileMountPath')

if ([string]::IsNullOrWhiteSpace($mountFolder)) {
    Show-BraveLockerMessage -Icon 'Error' -Message @'
This Brave Locker setup is from an older version and cannot be used.

Re-run Install-BraveLocker.ps1 from an administrator PowerShell.
'@
    return
}

function Complete-BraveLockerSession {
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$VhdxPath,
        [Parameter(Mandatory)][string]$MountFolder,
        [switch]$StopBrave
    )

    if ($StopBrave) {
        if (-not (Stop-BraveLockerBrowser -AnyProfile -TimeoutSeconds 15)) {
            return $false
        }
    }

    $result = Invoke-BraveLockerMountTask -Action 'Dismount' -VhdxPath $VhdxPath -MountPath $MountFolder
    [bool]$result.Success
}

# --- Recover from a crash or forced reboot ---------------------------------
# A crash must not leave the profile decrypted, so seal any vault left attached
# by a previous session before doing anything else.
if (Test-BraveLockerVaultMounted -VhdxPath $config.VhdxPath) {
    if (-not (Complete-BraveLockerSession -VhdxPath $config.VhdxPath -MountFolder $mountFolder -StopBrave)) {
        # Stopping here matters. Carrying on would unlock an already-unlocked
        # volume, which BitLocker reports as a failure - so a correct passphrase
        # would be shown as wrong and logged as a failed attempt.
        Show-BraveLockerMessage -Icon 'Error' -Message @'
The vault was left open by a previous session and could not be sealed.

Something still has a file open on it - most likely a Brave window that is
still running. Close it and try again.

Nothing has been lost and your passphrase is fine.
'@
        return
    }
}

# --- Cooldown ---------------------------------------------------------------
$remaining = Get-BraveLockerRemainingCooldownSeconds -StatePath $paths.StatePath -NowUtc (Get-Date).ToUniversalTime()
if ($remaining -gt 0) {
    Show-BraveLockerMessage -Icon 'Warning' -Message @"
Too many failed attempts.

Wait $remaining seconds and try again. Nothing has been lost - the vault is
simply refusing to open for a moment.
"@
    return
}

# --- Clear the way for the mount -------------------------------------------
# Windows only mounts a volume over an empty folder. If Brave was started
# without the locker while the vault was sealed, it will have built a fresh
# profile in that folder; set it aside rather than deleting it.
$prepared = Initialize-BraveLockerMountFolder -Path $mountFolder -QuarantineRoot $paths.StateRoot

if (-not $prepared.IsReady) {
    Show-BraveLockerMessage -Icon 'Error' -Message @"
The vault cannot be opened because something is already mounted at

$mountFolder

Restart the PC and try again.
"@
    return
}

if ($prepared.Action -eq 'QuarantinedStrayProfile') {
    Show-BraveLockerMessage -Icon 'Warning' -Message @"
Brave had been opened without its passcode at some point, and started a new,
empty profile.

That profile has been moved aside - nothing was deleted - to:

$($prepared.Destination)

Your real profile is in the vault and opens as usual.
"@
}

# --- Ask for the passphrase -------------------------------------------------
$note = ''
$prior = Get-BraveLockerState -StatePath $paths.StatePath
if ($prior.FailureCount -gt 0 -and $prior.LastFailureUtc) {
    $when = ([datetime]$prior.LastFailureUtc).ToLocalTime().ToString('ddd HH:mm')
    $note = "$($prior.FailureCount) failed attempt(s) since the last successful open, most recent $when."
}

$passphrase = Show-BraveLockerPassphrasePrompt -IconSource $config.BraveExe -Note $note
if ($null -eq $passphrase) { return }   # Cancelled - nothing to do, nothing to report.

# --- Open the vault ---------------------------------------------------------
# Unlocking BitLocker needs administrator rights, so the elevated task attaches,
# unlocks through a drive letter, and then mounts the vault onto Brave's own
# profile folder. The passphrase reaches it DPAPI-protected.
$mountResult = Invoke-BraveLockerMountTask -Action 'Mount' -VhdxPath $config.VhdxPath `
    -MountPath $mountFolder -Passphrase $passphrase

if (-not $mountResult.Success) {
    Show-BraveLockerMessage -Icon 'Error' -Message @"
Could not open the vault.

$($mountResult.Error)

If the vault file is damaged or missing, your BitLocker recovery key is the only
way back to this data - the one you saved off this PC during setup.
"@
    return
}

if (-not $mountResult.Unlocked) {
    # Wrong passphrase: nothing was decrypted and the task has already detached
    # the vault. Record the attempt and lengthen the wait. Nothing is deleted.
    $count = Add-BraveLockerFailedAttempt -StatePath $paths.StatePath -NowUtc (Get-Date).ToUniversalTime()
    Complete-BraveLockerSession -VhdxPath $config.VhdxPath -MountFolder $mountFolder | Out-Null
    $wait = Get-BraveLockerCooldownSeconds -FailureCount $count

    if ($mountResult.Reason -eq 'WrongPassphrase') {
        Show-BraveLockerMessage -Icon 'Error' -Message @"
Incorrect passphrase.

The vault stays sealed and nothing has been changed. Wait $wait seconds before
trying again.
"@
    } else {
        Show-BraveLockerMessage -Icon 'Error' -Message @"
The vault did not open.

$($mountResult.Reason) $($mountResult.Error)
"@
    }
    return
}

# --- Success ----------------------------------------------------------------
Clear-BraveLockerFailedAttempts -StatePath $paths.StatePath | Out-Null

try {
    Start-BraveLockerBrowser -BraveExe $config.BraveExe -UseDefaultProfile | Out-Null
    Wait-BraveLockerBrowserExit -AnyProfile
} finally {
    if (-not (Complete-BraveLockerSession -VhdxPath $config.VhdxPath -MountFolder $mountFolder)) {
        Show-BraveLockerMessage -Icon 'Warning' -Message @'
Brave has closed, but the vault could not be sealed.

Something still has a file open on the vault drive. Close it and open Brave
again - it will seal the vault on the way in.
'@
    }
}
