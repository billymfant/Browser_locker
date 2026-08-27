#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
    Start over with a new passcode.

    Removes the existing Brave Locker completely, then sets it up again from
    scratch and puts the lock back on your Brave shortcuts. Your Brave data is
    never at risk here: the vault is only a copy while your original profile
    still exists, and the uninstaller refuses to run if it does not.

    Run this from an elevated PowerShell with Brave closed.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$here = $PSScriptRoot

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
