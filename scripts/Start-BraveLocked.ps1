#Requires -Version 5.1
<#
    The everyday launcher. Shows a passphrase popup, opens the vault, starts
    Brave against the profile inside it, and seals the vault when Brave closes.

    It runs with no console window: everything the user sees is the popup and
    then Brave itself. Failures are reported through message boxes, never to a
    console nobody is looking at.

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

function Complete-BraveLockerSession {
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$VhdxPath,
        [string]$ProfilePath = ''
    )

    if ($ProfilePath) {
        if (-not (Stop-BraveLockerBrowser -ProfilePath $ProfilePath -TimeoutSeconds 15)) {
            return $false
        }
    }

    $result = Invoke-BraveLockerMountTask -Action 'Dismount' -VhdxPath $VhdxPath
    [bool]$result.Success
}

# --- Recover from a crash or forced reboot ---------------------------------
# A crash must not leave the profile decrypted, so seal any vault left attached
# by a previous session before doing anything else.
if (Test-BraveLockerVaultMounted -VhdxPath $config.VhdxPath) {
    # Close any Brave still holding the old session open, or the dismount will
    # fail on its open handles.
    $staleProfile = ''
    $knownMount = [string](Get-BraveLockerPropertyValue -InputObject $config -Name 'MountPath')
    if ($knownMount) { $staleProfile = Join-Path $knownMount $config.ProfileDirName }

    if (-not (Complete-BraveLockerSession -VhdxPath $config.VhdxPath -ProfilePath $staleProfile)) {
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
# Unlocking BitLocker needs administrator rights, so the elevated task both
# attaches and unlocks. The passphrase reaches it DPAPI-protected.
$mountResult = Invoke-BraveLockerMountTask -Action 'Mount' -VhdxPath $config.VhdxPath -Passphrase $passphrase

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
    Complete-BraveLockerSession -VhdxPath $config.VhdxPath | Out-Null
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

$profilePath = Join-Path $mountResult.MountPath $config.ProfileDirName

try {
    Start-BraveLockerBrowser -BraveExe $config.BraveExe -ProfilePath $profilePath | Out-Null
    Wait-BraveLockerBrowserExit -ProfilePath $profilePath
} finally {
    if (-not (Complete-BraveLockerSession -VhdxPath $config.VhdxPath -ProfilePath $profilePath)) {
        Show-BraveLockerMessage -Icon 'Warning' -Message @'
Brave has closed, but the vault could not be sealed.

Something still has a file open on the vault drive. Close it and open Brave
(Private) again - it will seal the vault on the way in.
'@
    }
}
