function Get-BraveLockerFreeDriveLetter {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [string]$Preferred = 'V',
        [string[]]$UsedLetters
    )

    if ($null -eq $UsedLetters) {
        $UsedLetters = @(Get-PSDrive -PSProvider FileSystem | ForEach-Object { $_.Name })
    }

    $used = @($UsedLetters | ForEach-Object { $_.ToString().ToUpperInvariant() })
    $want = $Preferred.ToString().ToUpperInvariant()

    if ($want -and ($used -notcontains $want)) { return $want }

    # Walk down from Z so the vault lands clear of anything the user plugs in.
    foreach ($code in 90..69) {
        $letter = [string][char]$code
        if ($used -notcontains $letter) { return $letter }
    }

    throw 'Brave Locker: no free drive letter between E and Z is available for the vault.'
}
