# The encryption backend, behind a dispatcher.
#
# Today there is one provider: BitLocker, which ships with Windows Pro,
# Enterprise and Education. Windows Home has no BitLocker at all, so a second
# provider (VeraCrypt) is the planned route to supporting it.
#
# Everything above this file talks to Protect/Unlock/Lock/Recovery by provider
# NAME and never calls a BitLocker cmdlet directly. Adding a provider means
# adding its four functions and one switch arm - not hunting BitLocker calls
# through the whole tool.

$script:BraveLockerDefaultProvider = 'BitLocker'

function Get-BraveLockerCryptoProviderName {
    [CmdletBinding()]
    [OutputType([string[]])]
    param()

    , @('BitLocker')
}

function Test-BraveLockerCryptoAvailable {
    <#
        Whether this machine can actually use the provider.

        Reported as an object rather than a boolean because "no" needs to be
        explainable to someone who is not going to read the source.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [string]$Provider = $script:BraveLockerDefaultProvider,
        # Injectable so the decision can be tested without a machine that
        # happens to have, or lack, BitLocker.
        [AllowNull()][object]$EditionOverride,
        [AllowNull()][object]$CommandOverride
    )

    switch ($Provider) {
        'BitLocker' {
            $edition = $EditionOverride
            if ($null -eq $edition) {
                $edition = (Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue).Caption
            }
            $edition = [string]$edition

            $hasCommand = $CommandOverride
            if ($null -eq $hasCommand) {
                $hasCommand = [bool](Get-Command 'Enable-BitLocker' -ErrorAction SilentlyContinue)
            }
            $hasCommand = [bool]$hasCommand

            # Home has no BitLocker. Device Encryption on some Home machines is
            # a different feature and cannot be driven by these cmdlets.
            if ($edition -match '\bHome\b') {
                return [pscustomobject]@{
                    IsAvailable = $false
                    Provider    = 'BitLocker'
                    Reason      = 'HomeEdition'
                    Detail      = "BitLocker is not available on $edition. Brave Locker needs Windows Pro, Enterprise or Education."
                }
            }

            if (-not $hasCommand) {
                return [pscustomobject]@{
                    IsAvailable = $false
                    Provider    = 'BitLocker'
                    Reason      = 'CmdletsMissing'
                    Detail      = 'The BitLocker PowerShell cmdlets are not present on this system.'
                }
            }

            return [pscustomobject]@{
                IsAvailable = $true
                Provider    = 'BitLocker'
                Reason      = 'OK'
                Detail      = "BitLocker is available on $edition."
            }
        }
        default {
            [pscustomobject]@{
                IsAvailable = $false
                Provider    = $Provider
                Reason      = 'UnknownProvider'
                Detail      = "There is no encryption provider called '$Provider'."
            }
        }
    }
}

function Protect-BraveLockerVolume {
    <#
        Encrypts a freshly created volume with the given passphrase and returns
        its recovery key. The key is returned, never written anywhere - storing
        it on the machine would defeat the vault.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$MountPoint,
        [Parameter(Mandatory)][securestring]$Passphrase,
        [string]$Provider = $script:BraveLockerDefaultProvider
    )

    switch ($Provider) {
        'BitLocker' {
            Enable-BitLocker -MountPoint $MountPoint -PasswordProtector -Password $Passphrase `
                -EncryptionMethod XtsAes256 -UsedSpaceOnly -ErrorAction Stop | Out-Null

            $deadline = (Get-Date).AddMinutes(5)
            while ((Get-Date) -lt $deadline) {
                if ((Get-BitLockerVolume -MountPoint $MountPoint).VolumeStatus -eq 'FullyEncrypted') { break }
                Start-Sleep -Seconds 2
            }

            $recovery = Add-BitLockerKeyProtector -MountPoint $MountPoint -RecoveryPasswordProtector -ErrorAction Stop
            $key = ($recovery.KeyProtector |
                Where-Object { $_.KeyProtectorType -eq 'RecoveryPassword' } |
                Select-Object -Last 1).RecoveryPassword

            if ([string]::IsNullOrWhiteSpace($key)) {
                throw 'Brave Locker: the volume was encrypted but no recovery key was produced. Refusing to continue - a vault with no recovery key is one lost passphrase away from gone.'
            }
            return [string]$key
        }
        default { throw "Brave Locker: unknown encryption provider '$Provider'." }
    }
}

function Unlock-BraveLockerVolume {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$MountPoint,
        [Parameter(Mandatory)][securestring]$Passphrase,
        [string]$Provider = $script:BraveLockerDefaultProvider
    )

    switch ($Provider) {
        'BitLocker' { return (Unlock-BraveLockerVault -MountPoint $MountPoint -Passphrase $Passphrase) }
        default { throw "Brave Locker: unknown encryption provider '$Provider'." }
    }
}

function Lock-BraveLockerVolume {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$MountPoint,
        [string]$Provider = $script:BraveLockerDefaultProvider
    )

    switch ($Provider) {
        'BitLocker' { Lock-BitLocker -MountPoint $MountPoint -ErrorAction SilentlyContinue | Out-Null }
        default { throw "Brave Locker: unknown encryption provider '$Provider'." }
    }
}
