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
    $partition = Get-DiskImage -ImagePath $VhdxPath |
        Get-Disk |
        Get-Partition -ErrorAction SilentlyContinue |
        Where-Object { $_.Type -ne 'Reserved' } |
        Select-Object -First 1

    if ($null -eq $partition) {
        throw 'Brave Locker: the vault attached but no usable partition was found.'
    }

    $mountPath = Get-BraveLockerPreferredAccessPath -AccessPaths $partition.AccessPaths
    if (-not $mountPath) {
        throw 'Brave Locker: the vault attached but Windows gave it nowhere to be reached from.'
    }
    $mountPath
}

function Unlock-BraveLockerVault {
    [CmdletBinding()]
    [OutputType([bool])]
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
        return $true
    } catch {
        # A wrong passphrase is an expected outcome, not an exceptional one.
        Write-Verbose "Unlock failed: $($_.Exception.Message)"
        return $false
    }
}

function Dismount-BraveLockerVault {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$VhdxPath)

    if (-not (Test-BraveLockerVaultMounted -VhdxPath $VhdxPath)) { return }
    Dismount-DiskImage -ImagePath $VhdxPath -ErrorAction Stop | Out-Null
}
