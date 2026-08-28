# Finding Brave, finding its profile, and choosing where the vault goes.
#
# The original tool hardcoded D:\apps\brave_locker and Brave's Program Files
# path, which is fine for one machine and useless for anyone else's.

function Get-BraveLockerBraveExePath {
    <#
        Where Brave is installed. Registry first, because that survives Brave
        being installed per-user or on a drive nobody would guess.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([string[]]$SearchPath)

    if ($SearchPath) {
        foreach ($candidate in $SearchPath) {
            if ($candidate -and (Test-Path $candidate)) { return $candidate }
        }
        return ''
    }

    $registryKeys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\brave.exe'
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\brave.exe'
    )
    foreach ($key in $registryKeys) {
        if (-not (Test-Path $key)) { continue }
        $value = [string](Get-ItemProperty -Path $key -ErrorAction SilentlyContinue).'(default)'
        if ($value -and (Test-Path $value)) { return $value }
    }

    $candidates = @(
        (Join-Path $env:ProgramFiles 'BraveSoftware\Brave-Browser\Application\brave.exe')
        (Join-Path ${env:ProgramFiles(x86)} 'BraveSoftware\Brave-Browser\Application\brave.exe')
        (Join-Path $env:LOCALAPPDATA 'BraveSoftware\Brave-Browser\Application\brave.exe')
    )
    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path $candidate)) { return $candidate }
    }

    ''
}

function Get-BraveLockerProfileRoot {
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$LocalAppData = $env:LOCALAPPDATA)

    Join-Path $LocalAppData 'BraveSoftware\Brave-Browser\User Data'
}

function Test-BraveLockerProfileUsable {
    <#
        Whether a folder looks like a real Brave profile worth protecting.

        "Local State plus at least one profile directory" rather than a file
        count, because a count says nothing about whether the thing is a Brave
        profile or a folder that happens to hold 200 files.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path $Path)) {
        return [pscustomobject]@{ IsUsable = $false; Reason = 'Missing'; ProfileCount = 0; SizeBytes = 0 }
    }

    if (-not (Test-Path (Join-Path $Path 'Local State'))) {
        return [pscustomobject]@{ IsUsable = $false; Reason = 'NoLocalState'; ProfileCount = 0; SizeBytes = 0 }
    }

    $profiles = @(Get-ChildItem -Path $Path -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^(Default|Profile \d+)$' })

    if ($profiles.Count -eq 0) {
        return [pscustomobject]@{ IsUsable = $false; Reason = 'NoProfiles'; ProfileCount = 0; SizeBytes = 0 }
    }

    $size = (Get-ChildItem -Path $Path -Recurse -File -ErrorAction SilentlyContinue |
        Measure-Object -Property Length -Sum).Sum
    if ($null -eq $size) { $size = 0 }

    [pscustomobject]@{
        IsUsable     = $true
        Reason       = 'OK'
        ProfileCount = $profiles.Count
        SizeBytes    = [int64]$size
    }
}

function Get-BraveLockerVaultSizeMB {
    <#
        Vault size for a profile of this size: room to grow, rounded up to a
        whole GB, floor 8 GB, ceiling 128 GB. The VHDX is dynamically
        expanding, so this is a ceiling and not an allocation.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Mandatory)][int64]$ProfileSizeBytes)

    $profileGB = $ProfileSizeBytes / 1GB
    $wantedGB = [math]::Ceiling($profileGB * 4)
    if ($wantedGB -lt 8) { $wantedGB = 8 }
    if ($wantedGB -gt 128) { $wantedGB = 128 }
    [int]($wantedGB * 1024)
}

function Select-BraveLockerVaultDrive {
    <#
        Which drive should hold the vault file.

        Prefers the drive with the most free space, so the vault is not parked
        on a nearly-full system drive. Only NTFS is eligible: the vault file
        itself is fine anywhere, but a FAT volume caps files at 4 GB.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Volume,
        [int64]$RequiredBytes = 5GB
    )

    $eligible = @($Volume | Where-Object {
        $name = [string](Get-BraveLockerPropertyValue -InputObject $_ -Name 'DriveLetter')
        $fs   = [string](Get-BraveLockerPropertyValue -InputObject $_ -Name 'FileSystem')
        $free = Get-BraveLockerPropertyValue -InputObject $_ -Name 'SizeRemaining'
        $type = [string](Get-BraveLockerPropertyValue -InputObject $_ -Name 'DriveType')

        $name -and $name -ne "`0" -and
        $fs -eq 'NTFS' -and
        ($type -eq '' -or $type -eq 'Fixed') -and
        $null -ne $free -and [int64]$free -ge $RequiredBytes
    })

    if ($eligible.Count -eq 0) { return '' }

    $best = $eligible | Sort-Object -Property @{
        Expression = { [int64](Get-BraveLockerPropertyValue -InputObject $_ -Name 'SizeRemaining') }
    } -Descending | Select-Object -First 1

    [string](Get-BraveLockerPropertyValue -InputObject $best -Name 'DriveLetter')
}

function Get-BraveLockerDefaultVaultPath {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$DriveLetter)

    $letter = $DriveLetter.TrimEnd(':', '\').ToUpperInvariant()
    Join-Path "${letter}:\" 'BraveLocker\vault.vhdx'
}

function Test-BraveLockerRequirement {
    <#
        Everything that must be true before setup may touch anything, as a list
        of results rather than the first thrown error - so the wizard can show
        the whole picture at once instead of one problem per attempt.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [string]$Provider = 'BitLocker',
        [AllowNull()][object]$CryptoStatus,
        [AllowNull()][object]$IsElevated,
        [AllowNull()][object]$BraveExe,
        [AllowNull()][object]$ProfilePath,
        [AllowNull()][object]$BraveProcessCount,
        [AllowNull()][object]$VaultDriveLetter,
        [AllowNull()][object]$AlreadyInstalled
    )

    $checks = New-Object System.Collections.Generic.List[object]
    function Add-Check {
        param($Name, $Ok, $Detail, $Fatal = $true)
        $checks.Add([pscustomobject]@{ Name = $Name; IsOk = [bool]$Ok; Detail = $Detail; IsFatal = [bool]$Fatal })
    }

    # Checked first: running setup over an existing install would build a second
    # vault and rename an already-vaulted profile aside, which is the fastest
    # way to lose someone's data with a tool meant to protect it.
    if ($null -eq $AlreadyInstalled) {
        $AlreadyInstalled = Test-Path (Get-BraveLockerPaths).ConfigPath
    }
    $notInstalled = (-not [bool]$AlreadyInstalled)
    Add-Check 'Not already set up' $notInstalled $(if ($notInstalled) {
        'Brave Locker is not set up on this PC yet.'
    } else {
        'Brave Locker is already set up on this PC. To change your passcode use Reset-BraveLocker.ps1, or remove it first with Uninstall-BraveLocker.ps1. Running setup again would build a second vault and move your already-protected profile aside.'
    })

    if ($null -eq $CryptoStatus) { $CryptoStatus = Test-BraveLockerCryptoAvailable -Provider $Provider }
    Add-Check 'Disk encryption' $CryptoStatus.IsAvailable $CryptoStatus.Detail

    if ($null -eq $IsElevated) {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $IsElevated = (New-Object Security.Principal.WindowsPrincipal($identity)).IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    Add-Check 'Administrator rights' $IsElevated $(if ($IsElevated) {
        'Running with administrator rights.'
    } else {
        'Setup must be run as administrator - creating the vault and registering the mount helper both require it.'
    })

    if ($null -eq $BraveExe) { $BraveExe = Get-BraveLockerBraveExePath }
    $BraveExe = [string]$BraveExe
    Add-Check 'Brave installed' ([bool]$BraveExe) $(if ($BraveExe) {
        "Found Brave at $BraveExe"
    } else {
        'Brave could not be found on this PC. Install Brave first.'
    })

    if ($null -eq $ProfilePath) { $ProfilePath = Get-BraveLockerProfileRoot }
    $profileState = Test-BraveLockerProfileUsable -Path ([string]$ProfilePath)
    Add-Check 'Brave profile' $profileState.IsUsable $(if ($profileState.IsUsable) {
        "{0} profile(s), {1:N2} GB at {2}" -f $profileState.ProfileCount, ($profileState.SizeBytes / 1GB), $ProfilePath
    } else {
        "No usable Brave profile at $ProfilePath ($($profileState.Reason)). Open Brave once, then run setup again."
    })

    if ($null -eq $BraveProcessCount) {
        $BraveProcessCount = @(Get-Process -Name 'brave' -ErrorAction SilentlyContinue).Count
    }
    $braveClosed = ([int]$BraveProcessCount -eq 0)
    Add-Check 'Brave closed' $braveClosed $(if ($braveClosed) {
        'Brave is closed.'
    } else {
        "Brave is running ($BraveProcessCount processes). Close it so the profile is copied in a consistent state."
    })

    if ($null -eq $VaultDriveLetter) {
        $required = 5GB
        if ($profileState.IsUsable) { $required = [int64]($profileState.SizeBytes * 2) + 1GB }
        $VaultDriveLetter = Select-BraveLockerVaultDrive -Volume @(Get-Volume -ErrorAction SilentlyContinue) -RequiredBytes $required
    }
    $VaultDriveLetter = [string]$VaultDriveLetter
    Add-Check 'Room for the vault' ([bool]$VaultDriveLetter) $(if ($VaultDriveLetter) {
        "The vault will live on ${VaultDriveLetter}:"
    } else {
        'No NTFS drive has enough free space for the vault.'
    })

    $all = $checks.ToArray()

    # Counted with a plain loop rather than a Where-Object pipeline: PowerShell
    # 5.1 fails to compile the boolean conditional over a generic List here and
    # throws "Argument types do not match" from deep inside the expression tree.
    $blocking = 0
    foreach ($check in $all) {
        if ($check.IsFatal -and (-not $check.IsOk)) { $blocking++ }
    }

    [pscustomobject]@{
        CanProceed  = ($blocking -eq 0)
        Checks      = $all
        BraveExe    = [string]$BraveExe
        ProfilePath = [string]$ProfilePath
        VaultDrive  = [string]$VaultDriveLetter
        ProfileSize = $profileState.SizeBytes
    }
}
