#Requires -Version 5.1
<#
    The everyday launcher. Shows a passphrase popup, opens the vault onto
    Brave's own profile folder, starts Brave, and seals the vault when Brave
    closes.

    Brave is started with NO --user-data-dir. That is deliberate and load
    bearing: Brave's App-Bound Encryption ties cookies and saved passwords to
    the profile path, so a profile reached by any other path decrypts nothing
    and every account appears logged out. The vault is mounted onto the path
    Brave already uses instead of the profile being moved somewhere else.

    A wrong passphrase is never destructive: nothing is decrypted, nothing is
    deleted, the attempt is logged and the next try is delayed.

    THE CONTRACT
    ------------
    Clicking the browser icon has exactly two acceptable outcomes: the
    passphrase box appears, or a browser opens. Never silence, and never a
    message whose only advice is something that cannot work.

    That contract is the whole design, and it exists because the set of things
    that can go wrong here CANNOT be written down in advance. Every fault this
    tool has hit was found on a machine that had already broken - a browser
    update quietly repointing its own shortcut, a mount point left behind by a
    session that never dismounted. Recovery that only handles the faults
    someone thought of is worth exactly as much as the guesswork behind it.

    So this script does not try to enumerate failures. It makes failure
    survivable instead:

      - it runs with no console, so an unhandled error used to be INVISIBLE.
        Everything is wrapped now; any error becomes a dialog, including the
        ones nobody predicted.
      - every dead end offers the same three ways out - try again, open the
        browser without the lock, or turn the lock off and take the profile
        back - none of which require knowing what went wrong.
      - the last-resort dialog does not use the BraveLocker module, because a
        module that will not import is one of the things that can go wrong.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot

# ---------------------------------------------------------------------------
# Last resort. Deliberately depends on nothing but Windows itself: no module,
# no config, no vault. If this cannot run, nothing could have.
# ---------------------------------------------------------------------------
function Show-BraveLockerLastResort {
    param([string]$Message)

    # Log FIRST, then show. The order matters: a dialog can fail to appear, and
    # it also blocks until someone clicks it - so a message that is only shown
    # leaves no trace for anyone looking afterwards at why a launch died. This
    # was found by breaking the module deliberately: the dialog appeared, and
    # nothing whatsoever was written down.
    try {
        $log = Join-Path $env:LOCALAPPDATA 'BraveLocker\launcher-error.log'
        $dir = Split-Path -Parent $log
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        Add-Content -Path $log -Encoding utf8 -Value (
            "[{0}] {1}" -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), ($Message -replace '\s+', ' '))
    } catch { }

    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
        [System.Windows.Forms.MessageBox]::Show(
            $Message, 'Browser Locker',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
    } catch {
        # Nothing more can be done to reach the user in this process. The log
        # above is the record, and it is better than the silence this whole
        # design exists to prevent.
    }
}

# The card is the only instruction that survives this script being broken.
$script:CardHint = @'
If nothing here works, your data is still safe and still reachable. See the
emergency card - it opens the vault using nothing but built-in Windows:

  Start menu -> "Browser Locker - Emergency Card"
'@

# ---------------------------------------------------------------------------
# The module import is itself a thing that can fail.
# ---------------------------------------------------------------------------
try {
    Import-Module (Join-Path $repoRoot 'src\BraveLocker\BraveLocker.psd1') -Force -ErrorAction Stop
} catch {
    Show-BraveLockerLastResort @"
Browser Locker could not start.

Its own program files look damaged or missing:
$($_.Exception.Message)

Your vault has NOT been touched and your data is not lost.

$script:CardHint
"@
    return
}

# ---------------------------------------------------------------------------
# Everything below can fail. All of it is wrapped.
# ---------------------------------------------------------------------------
$browserExe = ''
$browserExeName = 'brave.exe'
$browserName = 'Brave'

function Resolve-BraveLockerDeadEnd {
    <#
        Turns a failure into a choice. Called instead of showing a message and
        giving up - which is what used to leave someone with a browser that
        would not open and no way forward that did not involve an expert.

        Acts on the choice and returns. The caller returns immediately after.
    #>
    param(
        [Parameter(Mandatory)][string]$Message,
        [string]$Detail = '',
        [switch]$NoOpenUnlocked
    )

    $choice = 'Close'
    try {
        $choice = Show-BraveLockerRecoveryChoice -Title $browserName -Message $Message `
            -Detail $Detail -IconSource $browserExe -NoOpenUnlocked:$NoOpenUnlocked
    } catch {
        # The choice dialog itself failed. Fall back to plain text, so the user
        # still learns what happened and where the card is.
        Show-BraveLockerLastResort "$Message`n`n$Detail`n`n$script:CardHint"
        return
    }

    switch ($choice) {
        'Retry' {
            # A fresh process rather than a loop: whatever state this one has
            # got itself into is left behind with it.
            Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -ArgumentList @(
                '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
                '-File', "`"$PSCommandPath`""
            ) | Out-Null
        }
        'OpenUnlocked' {
            # The vault stays sealed. The browser starts on whatever profile it
            # finds, which the locker quarantines and reports next time round.
            try {
                if ($browserExe -and (Test-Path $browserExe)) {
                    Start-Process -FilePath $browserExe | Out-Null
                } else {
                    Show-BraveLockerLastResort @"
The browser could not be started automatically - Browser Locker does not have a
valid path to it.

Open it from the Start menu instead. Your vault stays sealed and safe.
"@
                }
            } catch {
                Show-BraveLockerLastResort "The browser could not be started: $($_.Exception.Message)"
            }
        }
        'TurnOffLock' {
            $script = Join-Path $PSScriptRoot 'Unlock-BraveLockerPermanently.ps1'
            if (Test-Path $script) {
                # Visible console, and it elevates itself: this one asks real
                # questions and the answers matter.
                Start-Process -FilePath 'powershell.exe' -ArgumentList @(
                    '-NoProfile', '-ExecutionPolicy', 'Bypass',
                    '-File', "`"$script`""
                ) | Out-Null
            } else {
                Show-BraveLockerLastResort @"
The tool that turns the lock off is missing:
  $script

$script:CardHint
"@
            }
        }
        default { }   # Close - the user chose to do nothing.
    }
}

try {
    $paths = Get-BraveLockerPaths

    if (-not (Test-Path $paths.ConfigPath)) {
        # No config means no lock. The browser should simply open - refusing to
        # would be the tool getting in the way of a machine it is not set up on.
        Show-BraveLockerLastResort @'
Browser Locker is not set up on this PC, so there is no vault to open.

Opening your browser normally instead.
'@
        $fallbackExe = 'C:\Program Files\BraveSoftware\Brave-Browser\Application\brave.exe'
        if (Test-Path $fallbackExe) { Start-Process -FilePath $fallbackExe | Out-Null }
        return
    }

    $config = Get-Content -Path $paths.ConfigPath -Raw | ConvertFrom-Json
    $mountFolder = [string](Get-BraveLockerPropertyValue -InputObject $config -Name 'ProfileMountPath')

    # Which browser this install locks. Older configs predate the choice and are
    # Brave by definition.
    $browserExe = [string](Get-BraveLockerPropertyValue -InputObject $config -Name 'BrowserExe')
    if (-not $browserExe) { $browserExe = [string](Get-BraveLockerPropertyValue -InputObject $config -Name 'BraveExe') }
    $browserExeName = [string](Get-BraveLockerPropertyValue -InputObject $config -Name 'BrowserExeName')
    if (-not $browserExeName) { $browserExeName = 'brave.exe' }
    $browserName = [string](Get-BraveLockerPropertyValue -InputObject $config -Name 'BrowserName')
    if (-not $browserName) { $browserName = 'Brave' }

    if ([string]::IsNullOrWhiteSpace($mountFolder)) {
        Resolve-BraveLockerDeadEnd -Message 'This Browser Locker setup cannot be used.' -Detail @'
Its settings are from an older version and do not record where to mount the
vault. Turning the lock off will copy your profile back out of the vault.
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
            if (-not (Stop-BraveLockerBrowser -AnyProfile -ExeName $browserExeName -TimeoutSeconds 15)) {
                return $false
            }
        }

        $result = Invoke-BraveLockerMountTask -Action 'Dismount' -VhdxPath $VhdxPath -MountPath $MountFolder
        [bool]$result.Success
    }

    # --- Recover from a crash or forced reboot -----------------------------
    # A crash must not leave the profile decrypted, so seal any vault left
    # attached by a previous session before doing anything else.
    if (Test-BraveLockerVaultMounted -VhdxPath $config.VhdxPath) {
        if (-not (Complete-BraveLockerSession -VhdxPath $config.VhdxPath -MountFolder $mountFolder -StopBrave)) {
            # Stopping here matters. Carrying on would unlock an already-unlocked
            # volume, which BitLocker reports as a failure - so a correct
            # passphrase would be shown as wrong and logged as a failed attempt.
            #
            # "Open without the lock" is withheld: the vault is currently OPEN,
            # so a second browser would be pointed at a live profile.
            Resolve-BraveLockerDeadEnd -NoOpenUnlocked `
                -Message 'The vault was left open by a previous session.' -Detail @"
It could not be sealed, most likely because a $browserName window is still
running. Close every $browserName window and try again.

Your passphrase is fine and nothing has been lost.
"@
            return
        }
    }

    # --- Cooldown -----------------------------------------------------------
    $remaining = Get-BraveLockerRemainingCooldownSeconds -StatePath $paths.StatePath -NowUtc (Get-Date).ToUniversalTime()
    if ($remaining -gt 0) {
        Resolve-BraveLockerDeadEnd -Message 'Too many failed passphrase attempts.' -Detail @"
The vault is refusing to open for another $remaining seconds. This is only a
delay - nothing has been lost and nothing is damaged.
"@
        return
    }

    # --- Clear the way for the mount ---------------------------------------
    # Windows only mounts a volume over an empty folder. If the browser was
    # started without the locker while the vault was sealed, it will have built
    # a fresh profile in that folder; set it aside rather than deleting it.
    $prepared = Initialize-BraveLockerMountFolder -Path $mountFolder -QuarantineRoot $paths.StateRoot

    if (-not $prepared.IsReady) {
        if ($prepared.Action -eq 'StaleMountPointStuck') {
            # A leftover mount point that could not be removed from here.
            # Telling the user to restart would be worse than useless: nothing
            # owns this mount point any more, so no restart will ever clear it.
            Resolve-BraveLockerDeadEnd `
                -Message 'A previous session left something behind that needs admin rights.' -Detail @"
$mountFolder

Restarting will NOT fix this. Run Repair-BraveLocker.ps1 and click Yes to the
prompt, or use one of the options below.

$($prepared.Error)
"@
        } else {
            Resolve-BraveLockerDeadEnd `
                -Message 'The vault cannot be opened - something is already mounted there.' -Detail @"
$mountFolder

Restarting the PC usually clears this.
"@
        }
        return
    }

    if ($prepared.ClearedStaleMountPoint) {
        # Worth saying out loud rather than silently repairing: it means the
        # last session ended without sealing the vault.
        Show-BraveLockerMessage -Icon 'Warning' -Message @"
The last $browserName session did not close cleanly and left the vault's mount
point behind.

That has been cleared up. Nothing was lost, and your vault opens as usual.
"@
    }

    if ($prepared.Action -eq 'QuarantinedStrayProfile') {
        Show-BraveLockerMessage -Icon 'Warning' -Message @"
$browserName had been opened without its passcode at some point, and started a
new, empty profile.

That profile has been moved aside - nothing was deleted - to:

$($prepared.Destination)

Your real profile is in the vault and opens as usual.
"@
    }

    # --- Ask for the passphrase --------------------------------------------
    $note = ''
    $prior = Get-BraveLockerState -StatePath $paths.StatePath
    if ($prior.FailureCount -gt 0 -and $prior.LastFailureUtc) {
        $when = ([datetime]$prior.LastFailureUtc).ToLocalTime().ToString('ddd HH:mm')
        $note = "$($prior.FailureCount) failed attempt(s) since the last successful open, most recent $when."
    }

    $passphrase = Show-BraveLockerPassphrasePrompt -Title $browserName -IconSource $browserExe -Note $note
    if ($null -eq $passphrase) { return }   # Cancelled - nothing to do, nothing to report.

    # --- Open the vault -----------------------------------------------------
    # Unlocking BitLocker needs administrator rights, so the elevated task
    # attaches, unlocks through a drive letter, and then mounts the vault onto
    # the browser's own profile folder. The passphrase reaches it
    # DPAPI-protected.
    $mountResult = Invoke-BraveLockerMountTask -Action 'Mount' -VhdxPath $config.VhdxPath `
        -MountPath $mountFolder -Passphrase $passphrase

    if (-not $mountResult.Success) {
        Resolve-BraveLockerDeadEnd -Message 'Could not open the vault.' -Detail @"
$($mountResult.Error)

If the vault file is damaged or missing, your BitLocker recovery key is the way
back to this data - the one you saved off this PC during setup.
"@
        return
    }

    if (-not $mountResult.Unlocked) {
        # Nothing was decrypted and the task has already detached the vault.
        Complete-BraveLockerSession -VhdxPath $config.VhdxPath -MountFolder $mountFolder | Out-Null

        if ($mountResult.Reason -eq 'WrongPassphrase') {
            # Record the attempt and lengthen the wait. Nothing is deleted.
            $count = Add-BraveLockerFailedAttempt -StatePath $paths.StatePath -NowUtc (Get-Date).ToUniversalTime()
            $wait = Get-BraveLockerCooldownSeconds -FailureCount $count
            Show-BraveLockerMessage -Icon 'Error' -Message @"
Incorrect passphrase.

The vault stays sealed and nothing has been changed. Wait $wait seconds before
trying again.
"@
        } else {
            # The passphrase was never the problem, so it must not count towards
            # the lockout. The cooldown exists to slow down guessing; making a
            # broken mount look like a bad guess just locks the user out of
            # their own browser over a fault they cannot fix by retyping.
            Resolve-BraveLockerDeadEnd -Message 'The vault did not open, and this was not your passphrase.' -Detail @"
$($mountResult.Error)

Nothing has been changed and this does not count as a failed attempt.
"@
        }
        return
    }

    # --- Success ------------------------------------------------------------
    Clear-BraveLockerFailedAttempts -StatePath $paths.StatePath | Out-Null

    try {
        Start-BraveLockerBrowser -BraveExe $browserExe -UseDefaultProfile | Out-Null
        Wait-BraveLockerBrowserExit -AnyProfile -ExeName $browserExeName
    } finally {
        if (-not (Complete-BraveLockerSession -VhdxPath $config.VhdxPath -MountFolder $mountFolder)) {
            Show-BraveLockerMessage -Icon 'Warning' -Message @"
$browserName has closed, but the vault could not be sealed.

Something still has a file open on the vault drive. Close it and open
$browserName again - it will seal the vault on the way in.
"@
        }
    }
}
catch {
    # The catch-all. Anything not anticipated anywhere above arrives here and
    # becomes a dialog with a way out, instead of the silence that a hidden
    # console turns every unhandled error into.
    $detail = "$($_.Exception.Message)`r`n`r`nWhere: $($_.InvocationInfo.PositionMessage -replace '\s+', ' ')"

    try {
        Resolve-BraveLockerDeadEnd -Message 'Something went wrong opening your browser.' -Detail $detail
    } catch {
        Show-BraveLockerLastResort @"
Browser Locker hit a problem it could not recover from.

$detail

Your vault has NOT been touched and your data is not lost.

$script:CardHint
"@
    }

    try {
        $log = Join-Path (Join-Path $env:LOCALAPPDATA 'BraveLocker') 'launcher-error.log'
        Add-Content -Path $log -Encoding utf8 -Value (
            "[{0}] {1}" -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $detail)
    } catch { }
}
