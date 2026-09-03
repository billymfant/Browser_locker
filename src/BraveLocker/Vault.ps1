function New-BraveLockerDiskpartScript {
    <#
        The Hyper-V module is not present on this machine, so New-VHD does not
        exist and vault creation goes through a generated diskpart script.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$VhdxPath,
        [Parameter(Mandatory)][int]$MaximumSizeMB,
        [Parameter(Mandatory)][string]$DriveLetter
    )

    if ($MaximumSizeMB -lt 1024) {
        throw "Brave Locker: the vault must be at least 1024 MB; got $MaximumSizeMB."
    }

    $letter = $DriveLetter.TrimEnd(':').ToUpperInvariant()

    @(
        "create vdisk file=`"$VhdxPath`" maximum=$MaximumSizeMB type=expandable"
        "select vdisk file=`"$VhdxPath`""
        'attach vdisk'
        'convert gpt'
        'create partition primary'
        'format fs=ntfs quick label="BraveVault"'
        "assign letter=$letter"
    ) -join "`r`n"
}

function New-BraveLockerVault {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$VhdxPath,
        [Parameter(Mandatory)][int]$MaximumSizeMB,
        [Parameter(Mandatory)][string]$DriveLetter
    )

    if (Test-Path $VhdxPath) {
        throw "Brave Locker: a vault already exists at '$VhdxPath'. Refusing to overwrite it."
    }

    $dir = Split-Path -Parent $VhdxPath
    if ($dir -and -not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    $script = New-BraveLockerDiskpartScript -VhdxPath $VhdxPath -MaximumSizeMB $MaximumSizeMB -DriveLetter $DriveLetter
    $scriptFile = Join-Path $env:TEMP ('bravelocker-' + [guid]::NewGuid().ToString() + '.txt')

    try {
        Set-Content -Path $scriptFile -Value $script -Encoding ascii
        $output = & diskpart.exe /s $scriptFile 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw ("Brave Locker: diskpart failed creating the vault.`r`n" + ($output -join "`r`n"))
        }
    } finally {
        Remove-Item -Path $scriptFile -Force -ErrorAction SilentlyContinue
    }
}

function Test-BraveLockerVaultMounted {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$VhdxPath)

    if (-not (Test-Path $VhdxPath)) { return $false }

    $image = Get-DiskImage -ImagePath $VhdxPath -ErrorAction SilentlyContinue
    if ($null -eq $image) { return $false }
    [bool]$image.Attached
}

function Get-BraveLockerPreferredAccessPath {
    <#
        Picks where the vault should be reached from. A folder mount point wins
        over a drive letter, because a drive letter puts the vault in Explorer
        for everyone to see. Volume GUID paths are never returned.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [AllowNull()]
        [string[]]$AccessPaths
    )

    $usable = @($AccessPaths | Where-Object {
        -not [string]::IsNullOrWhiteSpace($_) -and $_ -notmatch '^\\\\\?\\Volume'
    })
    if ($usable.Count -eq 0) { return '' }

    $folder = $usable | Where-Object { $_ -notmatch '^[A-Za-z]:\\?$' } | Select-Object -First 1
    if ($folder) { return ([string]$folder).TrimEnd('\') }

    ([string]$usable[0]).TrimEnd('\')
}

function Mount-BraveLockerVault {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$VhdxPath)

    if (-not (Test-Path $VhdxPath)) {
        throw "Brave Locker: no vault found at '$VhdxPath'."
    }

    if (-not (Test-BraveLockerVaultMounted -VhdxPath $VhdxPath)) {
        Mount-DiskImage -ImagePath $VhdxPath -StorageType VHDX -ErrorAction Stop | Out-Null
    }

    # The volume is still BitLocker-locked here: it has a mount path, but its
    # contents stay unreadable until Unlock-BraveLockerVault succeeds.
    $partition = Get-BraveLockerVaultPartition -VhdxPath $VhdxPath

    if ($null -eq $partition) {
        throw 'Brave Locker: the vault attached but no usable partition was found.'
    }

    $mountPath = Get-BraveLockerPreferredAccessPath -AccessPaths $partition.AccessPaths
    if (-not $mountPath) {
        throw 'Brave Locker: the vault attached but Windows gave it nowhere to be reached from.'
    }
    $mountPath
}

function Test-BraveLockerWrongKeyError {
    <#
        Whether a BitLocker failure actually means the passphrase was wrong.

        BitLocker reports a rejected key as FVE_E_FAILED_AUTHENTICATION,
        HRESULT 0x80310027. Everything else - a volume that never appeared, a
        volume that was already unlocked, a service that is not running - is a
        different problem with a different fix.

        Reporting those as "incorrect passphrase" sends someone hunting for a
        typo in a passphrase that was right all along. That is not hypothetical:
        it is how a working vault here came to look like a forgotten passphrase.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [AllowNull()]
        [string]$Message
    )

    if ([string]::IsNullOrWhiteSpace($Message)) { return $false }
    if ($Message -match '0x80310027') { return $true }
    [bool]($Message -match 'cannot be unlocked with the key provided')
}

function Invoke-BraveLockerUnlockAttempt {
    <#
        One unlock attempt, reported in full: whether it opened, and if not,
        whether the passphrase was actually the problem.

        Unlock-BraveLockerVault answers only yes or no, which is all a caller
        that just needs a decision wants. This is for the caller that has to
        tell a human WHY, and must not collapse every failure into "wrong
        passphrase".
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        # Either a drive letter ("V", "V:") or a folder mount point.
        [Parameter(Mandatory)][Alias('DriveLetter')][string]$MountPoint,
        [Parameter(Mandatory)][securestring]$Passphrase
    )

    $target = $MountPoint
    if ($target -match '^[A-Za-z]:?$') {
        $target = $target.TrimEnd(':').ToUpperInvariant() + ':'
    } else {
        $target = $target.TrimEnd('\')
    }

    try {
        Unlock-BitLocker -MountPoint $target -Password $Passphrase -ErrorAction Stop | Out-Null
        return [pscustomobject]@{
            Unlocked = $true; MountPoint = $target; Reason = 'Unlocked'; Error = ''
        }
    } catch {
        # A wrong passphrase is an expected outcome, not an exceptional one -
        # but only when it really was the passphrase.
        $message = [string]$_.Exception.Message
        $reason = if (Test-BraveLockerWrongKeyError -Message $message) { 'WrongPassphrase' } else { 'UnlockFailed' }
        Write-Verbose "Unlock of '$target' failed ($reason): $message"
        return [pscustomobject]@{
            Unlocked = $false; MountPoint = $target; Reason = $reason; Error = $message
        }
    }
}

function Unlock-BraveLockerVault {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        # Either a drive letter ("V", "V:") or a folder mount point.
        [Parameter(Mandatory)][Alias('DriveLetter')][string]$MountPoint,
        [Parameter(Mandatory)][securestring]$Passphrase
    )

    (Invoke-BraveLockerUnlockAttempt -MountPoint $MountPoint -Passphrase $Passphrase).Unlocked
}

function Dismount-BraveLockerVault {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$VhdxPath)

    if (-not (Test-BraveLockerVaultMounted -VhdxPath $VhdxPath)) { return }
    Dismount-DiskImage -ImagePath $VhdxPath -ErrorAction Stop | Out-Null
}

function Get-BraveLockerVaultPartition {
    <#
        The vault's data partition, or nothing when the vault is not attached.

        Reserved partitions are skipped: a GPT disk carries a Microsoft Reserved
        partition that holds no filesystem.

        A DETACHED image reports Number as $null, and Get-Disk rejects a null
        -Number at parameter-binding time rather than quietly returning nothing.
        Under the elevated task's $ErrorActionPreference = 'Stop' that binding
        failure was thrown, and "Cannot validate argument on parameter 'Number'"
        was then written over the real unlock result in response.json - so the
        one file that recorded WHY a launch failed instead recorded this. The
        attached check happens here, before Get-Disk is ever reached.

        Being detached is an ordinary state, not an error: every dismount path
        asks for the partition of a vault that may already be gone.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$VhdxPath)

    $image = Get-DiskImage -ImagePath $VhdxPath -ErrorAction SilentlyContinue
    if ($null -eq $image) { return }
    if (-not $image.Attached) { return }
    if ($null -eq $image.Number) { return }

    Get-Disk -Number $image.Number -ErrorAction SilentlyContinue |
        Get-Partition -ErrorAction SilentlyContinue |
        Where-Object { $_.Type -ne 'Reserved' } |
        Select-Object -First 1
}

function Get-BraveLockerPartitionDriveLetter {
    <#
        A partition with no drive letter reports it as NUL rather than null or
        an empty string, which reads as a one-character letter unless it is
        checked for. Returns '' when there is genuinely no letter.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowNull()]$Partition)

    if ($null -eq $Partition) { return '' }

    $letter = [string](Get-BraveLockerPropertyValue -InputObject $Partition -Name 'DriveLetter')
    if ([string]::IsNullOrWhiteSpace($letter) -or $letter -eq "`0") { return '' }
    $letter.ToUpperInvariant()
}

function Add-BraveLockerVaultDriveLetter {
    <#
        Gives the vault a drive letter, returning the letter used.

        The vault is always unlocked through a drive letter and only then moved
        onto its folder. That order is what was verified on this machine: unlock
        via V:, add the folder access path, drop the letter, and the contents
        stay readable through the folder.

        Whether BitLocker can unlock through a folder mount point directly was
        never established - the one attempt that appeared to prove it could not
        was in fact failing authentication for an unrelated reason. Unlocking
        through a letter works, so there is no reason to find out.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$VhdxPath)

    $partition = Get-BraveLockerVaultPartition -VhdxPath $VhdxPath
    if ($null -eq $partition) {
        throw 'Brave Locker: the vault has no usable partition to assign a letter to.'
    }

    $existing = Get-BraveLockerPartitionDriveLetter -Partition $partition
    if ($existing) { return $existing }

    $letter = Get-BraveLockerFreeDriveLetter -Preferred 'V'
    Add-PartitionAccessPath -DiskNumber $partition.DiskNumber `
        -PartitionNumber $partition.PartitionNumber -AccessPath "${letter}:" -ErrorAction Stop
    $letter
}

function Remove-BraveLockerVaultDriveLetter {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$VhdxPath,
        [Parameter(Mandatory)][string]$DriveLetter
    )

    $partition = Get-BraveLockerVaultPartition -VhdxPath $VhdxPath
    if ($null -eq $partition) { return }

    $letter = $DriveLetter.TrimEnd(':', '\').ToUpperInvariant()
    Remove-PartitionAccessPath -DiskNumber $partition.DiskNumber `
        -PartitionNumber $partition.PartitionNumber -AccessPath "${letter}:\" -ErrorAction Stop
}

function Set-BraveLockerVaultAccessPath {
    <#
        Mounts the unlocked vault onto a folder. The folder must exist and be
        empty - Windows refuses to mount a volume over anything else, and that
        refusal is what stops a stray profile being silently shadowed.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$VhdxPath,
        [Parameter(Mandatory)][string]$AccessPath
    )

    $partition = Get-BraveLockerVaultPartition -VhdxPath $VhdxPath
    if ($null -eq $partition) {
        throw 'Brave Locker: the vault has no usable partition to mount.'
    }

    if (-not (Test-Path $AccessPath)) {
        New-Item -ItemType Directory -Path $AccessPath -Force | Out-Null
    }

    Add-PartitionAccessPath -DiskNumber $partition.DiskNumber `
        -PartitionNumber $partition.PartitionNumber -AccessPath $AccessPath -ErrorAction Stop
}

function Remove-BraveLockerVaultAccessPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$VhdxPath,
        [Parameter(Mandatory)][string]$AccessPath
    )

    $partition = Get-BraveLockerVaultPartition -VhdxPath $VhdxPath
    if ($null -eq $partition) { return }

    Remove-PartitionAccessPath -DiskNumber $partition.DiskNumber `
        -PartitionNumber $partition.PartitionNumber -AccessPath $AccessPath -ErrorAction SilentlyContinue
}
