$script:BraveLockerMinPassphraseLength = 16

function Test-BraveLockerPassphrase {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Passphrase
    )

    $min = $script:BraveLockerMinPassphraseLength

    if ($Passphrase.Length -lt $min) {
        return [pscustomobject]@{ IsValid = $false; Reason = 'TooShort' }
    }
    if ($Passphrase.Trim().Length -lt $min) {
        return [pscustomobject]@{ IsValid = $false; Reason = 'Whitespace' }
    }
    [pscustomobject]@{ IsValid = $true; Reason = 'OK' }
}
