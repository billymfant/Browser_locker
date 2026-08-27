#Requires -Version 5.1
<#
    Runs elevated via Task Scheduler. This is the only Brave Locker code that
    holds administrator rights.

    It attaches the vault, unlocks it, and detaches it. Unlocking BitLocker
    requires elevation, so the passphrase has to come here - it arrives
    DPAPI-protected under the current user (nobody else can decrypt it) and the
    request file is deleted the moment it has been read.

    On a wrong passphrase the vault is detached again before returning, so a
    failed attempt never leaves the profile attached.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot '..\src\BraveLocker\BraveLocker.psd1') -Force

$paths = Get-BraveLockerPaths
$response = [pscustomobject]@{
    RequestId   = ''
    Success     = $false
    DriveLetter = ''
    Unlocked    = $false
    Reason      = ''
    Error       = ''
}

$request = $null
try {
    if (-not (Test-Path $paths.RequestPath)) {
        throw 'No request file present.'
    }

    $request = Get-Content -Path $paths.RequestPath -Raw | ConvertFrom-Json
} catch {
    $response.Error = $_.Exception.Message
    $response.Reason = 'BadRequest'
    $response | ConvertTo-Json -Depth 5 | Set-Content -Path $paths.ResponsePath -Encoding utf8
    Remove-Item -Path $paths.RequestPath -Force -ErrorAction SilentlyContinue
    return
}

# Read what is needed, then remove the request file immediately - it holds the
# protected passphrase and should exist for as short a time as possible.
$response.RequestId = [string](Get-BraveLockerPropertyValue -InputObject $request -Name 'RequestId')
$action    = [string](Get-BraveLockerPropertyValue -InputObject $request -Name 'Action')
$vhdxPath  = [string](Get-BraveLockerPropertyValue -InputObject $request -Name 'VhdxPath')
$protected = [string](Get-BraveLockerPropertyValue -InputObject $request -Name 'ProtectedPassphrase')
Remove-Item -Path $paths.RequestPath -Force -ErrorAction SilentlyContinue

try {
    switch ($action) {
        'Mount' {
            $letter = Mount-BraveLockerVault -VhdxPath $vhdxPath
            $response.DriveLetter = $letter
            $response.Success = $true

            if ([string]::IsNullOrWhiteSpace($protected)) {
                $response.Reason = 'MountedOnly'
                break
            }

            $secure = $null
            try {
                $secure = ConvertTo-SecureString -String $protected -ErrorAction Stop
            } catch {
                # Only the account that protected it can decrypt it.
                $response.Reason = 'PassphraseUnreadable'
                Dismount-BraveLockerVault -VhdxPath $vhdxPath
                $response.DriveLetter = ''
                break
            }

            if (Unlock-BraveLockerVault -DriveLetter $letter -Passphrase $secure) {
                $response.Unlocked = $true
                $response.Reason = 'Unlocked'
            } else {
                # Wrong passphrase: detach again so nothing is left attached.
                $response.Unlocked = $false
                $response.Reason = 'WrongPassphrase'
                Dismount-BraveLockerVault -VhdxPath $vhdxPath
                $response.DriveLetter = ''
            }
        }
        'Dismount' {
            Dismount-BraveLockerVault -VhdxPath $vhdxPath
            $response.Success = $true
            $response.Reason = 'Dismounted'
        }
        default { throw "Unknown action '$action'." }
    }
} catch {
    $response.Success = $false
    $response.Error = $_.Exception.Message
    if (-not $response.Reason) { $response.Reason = 'Error' }
} finally {
    if ($null -ne $protected) { Clear-Variable protected -ErrorAction SilentlyContinue }
    Remove-Item -Path $paths.RequestPath -Force -ErrorAction SilentlyContinue
    $response | ConvertTo-Json -Depth 5 | Set-Content -Path $paths.ResponsePath -Encoding utf8
}
