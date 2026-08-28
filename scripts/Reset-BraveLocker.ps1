#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
    Start over with a new passcode.

    Removes the existing Brave Locker completely, then sets it up again from
    scratch and puts the lock back on your Brave shortcuts. Your Brave data is
    never at risk here: the vault is only a copy while your original profile
    still exists, and the uninstaller refuses to run if it does not.

    That last point is also this script's limit. Once
    Complete-BraveLockerMigration.ps1 has deleted the original profile, the
    vault holds the only copy of your logins and cards, so there is nothing left
    to rebuild a new vault from and this script will not run. Change your
    passcode BEFORE running the migration cleanup, not after.

    Run this from an elevated PowerShell with Brave closed.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$here = $PSScriptRoot
$repoRoot = Split-Path -Parent $here
Import-Module (Join-Path $repoRoot 'src\BraveLocker\BraveLocker.psd1') -Force

# Say this here rather than letting the user get most of the way in and hit a
# refusal from deep inside the uninstaller.
$paths = Get-BraveLockerPaths
if (Test-Path $paths.ConfigPath) {
    $existing = Get-Content -Path $paths.ConfigPath -Raw | ConvertFrom-Json
    $sourceProfile = [string](Get-BraveLockerPropertyValue -InputObject $existing -Name 'SourceProfilePath')
    if ($sourceProfile -and -not (Test-BraveLockerSafeToRemoveVault -SourceProfilePath $sourceProfile).IsSafe) {
        Write-Host ''
        Write-Host 'Cannot start over: the vault is the only copy of your Brave data.' -ForegroundColor Red
        Write-Host ''
        Write-Host "Your original profile at"
        Write-Host "  $sourceProfile"
        Write-Host 'is gone, so the migration cleanup has already been run. This script would'
        Write-Host 'have to delete the vault to build a new one, and there is nothing left to'
        Write-Host 'rebuild it from - that would destroy your logins, passwords and cards.'
        Write-Host ''
        Write-Host 'The passcode can only be changed BEFORE the migration cleanup runs.' -ForegroundColor Yellow
        Write-Host 'From here, your BitLocker recovery key is the way in if the passphrase is lost.'
        return
    }
}

Write-Host ''
Write-Host '==========================================' -ForegroundColor Cyan
Write-Host ' Brave Locker - start over, new passcode'   -ForegroundColor Cyan
Write-Host '==========================================' -ForegroundColor Cyan
Write-Host ''
Write-Host 'This runs three steps back to back:'
Write-Host '  1. Remove the current setup (vault deleted, Brave shortcuts restored)'
Write-Host '  2. Set it up again - you choose a NEW passphrase here'
Write-Host '  3. Put the lock back on your Brave shortcuts'
Write-Host ''
Write-Host 'Your existing Brave profile is the source, and it is only ever copied.'
Write-Host ''

$answer = Read-Host 'Type START to begin'
if ($answer -ne 'START') {
    Write-Host 'Cancelled. Nothing was changed.' -ForegroundColor Yellow
    return
}

Write-Host ''
Write-Host '--- Step 1 of 3: removing the old setup ---' -ForegroundColor Cyan
# No $LASTEXITCODE check here: these are PowerShell scripts, not native
# commands, so a failure surfaces as a terminating error under
# $ErrorActionPreference = 'Stop' and stops this script on its own. Reading
# $LASTEXITCODE before any native command has run is itself an error under
# Set-StrictMode -Version Latest.
& (Join-Path $here 'Uninstall-BraveLocker.ps1') -Force

Write-Host ''
Write-Host '--- Step 2 of 3: fresh setup, new passphrase ---' -ForegroundColor Cyan
Write-Host 'Choose a passphrase you will remember. Write it down somewhere safe' -ForegroundColor Yellow
Write-Host 'before you finish, along with the recovery key it shows you.' -ForegroundColor Yellow
Write-Host ''
& (Join-Path $here 'Install-BraveLocker.ps1')

Write-Host ''
Write-Host '--- Step 3 of 3: locking your Brave shortcuts ---' -ForegroundColor Cyan
& (Join-Path $here 'Set-BraveLockerAppLock.ps1')

Write-Host ''
Write-Host 'All done. Click Brave and it will ask for your new passcode.' -ForegroundColor Green
