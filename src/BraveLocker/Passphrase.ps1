# Someone who copies vault.vhdx can attack it offline, where the launcher's
# cooldown cannot reach them, so length is the only real defence there.
# 8 is the floor; below 12 still works but setup says plainly what it costs.
$script:BraveLockerMinPassphraseLength = 8
$script:BraveLockerWeakPassphraseLength = 12

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
        return [pscustomobject]@{ IsValid = $false; Reason = 'TooShort'; IsWeak = $true }
    }
    if ($Passphrase.Trim().Length -lt $min) {
        return [pscustomobject]@{ IsValid = $false; Reason = 'Whitespace'; IsWeak = $true }
    }

    [pscustomobject]@{
        IsValid = $true
        Reason  = 'OK'
        IsWeak  = ($Passphrase.Length -lt $script:BraveLockerWeakPassphraseLength)
    }
}
