#Requires -Version 5.1
<#
    Runs elevated via Task Scheduler. This is the ONLY Brave Locker code that
    holds administrator rights, so it does exactly two things: attach the vault
    and detach it. It never sees the passphrase and never touches the profile.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot '..\src\BraveLocker\BraveLocker.psd1') -Force

$paths = Get-BraveLockerPaths
$response = [pscustomobject]@{
    RequestId   = ''
    Success     = $false
    DriveLetter = ''
    Error       = ''
}

try {
    if (-not (Test-Path $paths.RequestPath)) {
        throw 'No request file present.'
    }

    $request = Get-Content -Path $paths.RequestPath -Raw | ConvertFrom-Json
    $response.RequestId = [string](Get-BraveLockerPropertyValue -InputObject $request -Name 'RequestId')

    $action   = [string](Get-BraveLockerPropertyValue -InputObject $request -Name 'Action')
    $vhdxPath = [string](Get-BraveLockerPropertyValue -InputObject $request -Name 'VhdxPath')

    switch ($action) {
        'Mount' {
            $response.DriveLetter = Mount-BraveLockerVault -VhdxPath $vhdxPath
            $response.Success = $true
        }
        'Dismount' {
            Dismount-BraveLockerVault -VhdxPath $vhdxPath
            $response.Success = $true
        }
        default { throw "Unknown action '$action'." }
    }
} catch {
    $response.Success = $false
    $response.Error = $_.Exception.Message
} finally {
    Remove-Item -Path $paths.RequestPath -Force -ErrorAction SilentlyContinue
    $response | ConvertTo-Json -Depth 5 | Set-Content -Path $paths.ResponsePath -Encoding utf8
}
