#Requires -Version 5.1
<#
    Deletes the original, unprotected Brave profile.

    This is deliberately separate from setup and deliberately manual. Until it
    runs, a full plaintext copy of the profile still sits in AppData and the
    vault protects nothing. It is also irreversible, so it asks first.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $repoRoot 'src\BraveLocker\BraveLocker.psd1') -Force

$paths = Get-BraveLockerPaths
if (-not (Test-Path $paths.ConfigPath)) {
    throw 'Brave Locker is not set up. Nothing to clean up.'
}
$config = Get-Content -Path $paths.ConfigPath -Raw | ConvertFrom-Json

# The original profile, renamed aside by setup. The vault is now mounted at the
# path Brave uses, so this folder is the last unencrypted copy - and the last
# rollback if the vaulted Brave turns out to be missing something.
$preMigrationPath = [string](Get-BraveLockerPropertyValue -InputObject $config -Name 'PreMigrationPath')
if ([string]::IsNullOrWhiteSpace($preMigrationPath)) {
    throw 'This setup predates the current layout and has no recorded original profile. Re-run Install-BraveLocker.ps1.'
}

if (-not (Test-Path $preMigrationPath)) {
    Write-Host 'The original profile is already gone. Nothing to do.' -ForegroundColor Green
    return
}

if (@(Get-Process -Name 'brave' -ErrorAction SilentlyContinue).Count -gt 0) {
    throw 'Close Brave completely before running this.'
}

$size = (Get-ChildItem -Path $preMigrationPath -Recurse -File -ErrorAction SilentlyContinue |
    Measure-Object -Property Length -Sum).Sum / 1GB

Write-Host ''
Write-Host 'This permanently deletes your original, unprotected Brave profile:' -ForegroundColor Red
Write-Host ('  {0}  ({1:N2} GB)' -f $preMigrationPath, $size)
Write-Host ''
Write-Host 'Only do this if you have already opened Brave (Private) and confirmed that'
Write-Host 'your logins, bookmarks and saved cards are all present in the vault copy.'
Write-Host 'There is no undo. The vault becomes the only copy of this data.'
Write-Host ''

$answer = Read-Host 'Type DELETE to confirm'
if ($answer -ne 'DELETE') {
    Write-Host 'Cancelled. Nothing was removed.' -ForegroundColor Yellow
    return
}

Remove-Item -Path $preMigrationPath -Recurse -Force
Write-Host ''
Write-Host 'Original profile deleted. Your Brave data now exists only inside the encrypted vault.' -ForegroundColor Green
Write-Host 'Make sure that recovery key really is somewhere safe.' -ForegroundColor Yellow
