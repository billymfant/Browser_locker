#Requires -Version 5.1
<#
    The everyday launcher. Prompts for the passphrase, opens the vault, starts
    Brave against the profile inside it, and seals the vault when Brave closes.

    A wrong passphrase is never destructive: nothing is mounted, nothing is
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
    Write-Host 'Brave Locker is not set up yet. Run Install-BraveLocker.ps1 first.' -ForegroundColor Yellow
    Read-Host 'Press Enter to close' | Out-Null
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
            Write-Host 'Brave would not close. Not forcing the vault shut - that risks corrupting the profile.' -ForegroundColor Yellow
            return $false
        }
    }

    $result = Invoke-BraveLockerMountTask -Action 'Dismount' -VhdxPath $VhdxPath
    if (-not $result.Success) {
        Write-Host "Warning: the vault could not be sealed - $($result.Error)" -ForegroundColor Yellow
        Write-Host 'Close anything using the vault drive, then run this launcher again.' -ForegroundColor Yellow
        return $false
    }
    $true
}

# --- Recover from a crash or forced reboot ---------------------------------
# A crash must not leave the profile sitting decrypted, so seal any vault left
# attached by a previous session before doing anything else.
if (Test-BraveLockerVaultMounted -VhdxPath $config.VhdxPath) {
    Write-Host 'The vault was left open by a previous session. Sealing it first.' -ForegroundColor Yellow
    Complete-BraveLockerSession -VhdxPath $config.VhdxPath | Out-Null
}

# --- Cooldown ---------------------------------------------------------------
$remaining = Get-BraveLockerRemainingCooldownSeconds -StatePath $paths.StatePath -NowUtc (Get-Date).ToUniversalTime()
if ($remaining -gt 0) {
    Write-Host "Too many failed attempts. Wait $remaining seconds and try again." -ForegroundColor Yellow
    Read-Host 'Press Enter to close' | Out-Null
    return
}

# --- Unlock -----------------------------------------------------------------
$passphrase = Read-Host -Prompt 'Vault passphrase' -AsSecureString

$mountResult = Invoke-BraveLockerMountTask -Action 'Mount' -VhdxPath $config.VhdxPath
if (-not $mountResult.Success) {
    Write-Host "Could not open the vault: $($mountResult.Error)" -ForegroundColor Red
    Write-Host ''
    Write-Host 'If the vault file is damaged or missing, your BitLocker recovery key is'
    Write-Host 'the only way back to this data - the one you stored off this PC at setup.'
    Read-Host 'Press Enter to close' | Out-Null
    return
}

$driveLetter = $mountResult.DriveLetter
if (-not (Unlock-BraveLockerVault -DriveLetter $driveLetter -Passphrase $passphrase)) {
    # Wrong passphrase: nothing was decrypted. Seal it back up, record the
    # attempt, and lengthen the wait. Nothing is ever deleted.
    $count = Add-BraveLockerFailedAttempt -StatePath $paths.StatePath -NowUtc (Get-Date).ToUniversalTime()
    Complete-BraveLockerSession -VhdxPath $config.VhdxPath | Out-Null
    $wait = Get-BraveLockerCooldownSeconds -FailureCount $count
    Write-Host ''
    Write-Host "Incorrect passphrase. The vault stays sealed and nothing has been changed." -ForegroundColor Red
    Write-Host "Wait $wait seconds before trying again." -ForegroundColor Red
    Read-Host 'Press Enter to close' | Out-Null
    return
}

# --- Success ----------------------------------------------------------------
$prior = Clear-BraveLockerFailedAttempts -StatePath $paths.StatePath
if ($prior.FailureCount -gt 0) {
    $when = ([datetime]$prior.LastFailureUtc).ToLocalTime().ToString('ddd HH:mm')
    Write-Host ''
    Write-Host "Note: $($prior.FailureCount) failed attempt(s) since you last opened this, most recent $when." -ForegroundColor Yellow
}

$profilePath = Join-Path "${driveLetter}:" $config.ProfileDirName

try {
    Start-BraveLockerBrowser -BraveExe $config.BraveExe -ProfilePath $profilePath | Out-Null
    Write-Host ''
    Write-Host 'Brave is open.' -ForegroundColor Green
    Write-Host 'Leave this window running - it seals the vault when you close Brave.'
    Write-Host 'While Brave is open the profile is decrypted, so lock Windows (Win+L) if you step away.'
    Wait-BraveLockerBrowserExit -ProfilePath $profilePath
} finally {
    if (Complete-BraveLockerSession -VhdxPath $config.VhdxPath -ProfilePath $profilePath) {
        Write-Host 'Vault sealed.' -ForegroundColor Green
    } else {
        Write-Host 'The vault is still open. Deal with the warning above before walking away.' -ForegroundColor Red
    }
}
