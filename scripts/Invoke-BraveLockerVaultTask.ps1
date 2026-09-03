#Requires -Version 5.1
<#
    Runs elevated via Task Scheduler. This is the only Brave Locker code that
    holds administrator rights.

    It attaches the vault, unlocks it, mounts it onto Brave's own profile
    folder, and detaches it again. Unlocking BitLocker requires elevation, so
    the passphrase has to come here - it arrives DPAPI-protected under the
    current user (nobody else can decrypt it) and the request file is deleted
    the moment it has been read.

    The order matters and is not arbitrary:

        attach -> drive letter -> UNLOCK -> add folder access path -> drop letter

    The vault is unlocked through a drive letter and only then moved onto its
    folder. Mounting it at Brave's own profile path is what keeps Brave's
    App-Bound Encryption satisfied: the path Brave sees never changes, so the
    cookies and passwords it encrypted there still decrypt.

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
    MountPath   = ''
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
$mountFolder = [string](Get-BraveLockerPropertyValue -InputObject $request -Name 'MountPath')
$protected = [string](Get-BraveLockerPropertyValue -InputObject $request -Name 'ProtectedPassphrase')
Remove-Item -Path $paths.RequestPath -Force -ErrorAction SilentlyContinue

try {
    switch ($action) {
        'Mount' {
            if (-not (Test-BraveLockerVaultMounted -VhdxPath $vhdxPath)) {
                Mount-DiskImage -ImagePath $vhdxPath -StorageType VHDX -ErrorAction Stop | Out-Null
            }
            $response.Success = $true

            # Unlock happens through a drive letter, never through the folder.
            $letter = Add-BraveLockerVaultDriveLetter -VhdxPath $vhdxPath

            if ([string]::IsNullOrWhiteSpace($protected)) {
                $response.MountPath = "${letter}:"
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
                $response.MountPath = ""
                break
            }

            # Reports WrongPassphrase only when BitLocker actually rejected the
            # key. Anything else - a volume that never appeared, one already
            # unlocked - comes back as UnlockFailed with the real message, so
            # the launcher does not accuse a correct passphrase.
            $attempt = Invoke-BraveLockerUnlockAttempt -MountPoint $letter -Passphrase $secure
            if (-not $attempt.Unlocked) {
                # Detach again so a failed attempt never leaves the vault attached.
                $response.Unlocked = $false
                $response.Reason = $attempt.Reason
                $response.Error = $attempt.Error
                Dismount-BraveLockerVault -VhdxPath $vhdxPath
                $response.MountPath = ""
                break
            }

            # Unlocked. Move it onto Brave's own profile folder and drop the
            # letter, so the vault never appears in Explorer as a drive.
            if ([string]::IsNullOrWhiteSpace($mountFolder)) {
                throw 'The mount request carried no folder to mount the vault onto.'
            }

            Set-BraveLockerVaultAccessPath -VhdxPath $vhdxPath -AccessPath $mountFolder
            Remove-BraveLockerVaultDriveLetter -VhdxPath $vhdxPath -DriveLetter $letter

            $response.Unlocked = $true
            $response.MountPath = $mountFolder
            $response.Reason = 'Unlocked'
        }
        'Dismount' {
            if ($mountFolder) {
                Remove-BraveLockerVaultAccessPath -VhdxPath $vhdxPath -AccessPath $mountFolder
            }
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
