# The vault mounts onto Brave's own profile folder, which is what keeps Brave's
# App-Bound Encryption satisfied: the path it sees never changes, so the cookies
# and saved passwords it encrypted there still decrypt.
#
# Windows will only mount a volume over an EMPTY directory. That is a feature
# here - it means a stray profile can never be silently shadowed by the vault -
# but it does mean the folder has to be checked and cleared before every mount.
#
# A stray profile appears when Brave is started without the locker while the
# vault is sealed: Brave finds an empty folder and builds a fresh profile in it.

function Test-BraveLockerMountFolderReady {
    <#
        Whether the vault can be mounted onto this folder.

        Reasons:
          Missing      - the folder does not exist yet; the caller creates it
          Empty        - ready to mount
          NotEmpty     - a stray profile is sitting in it
          IsMountPoint - something is already mounted here
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path $Path)) {
        return [pscustomobject]@{ IsReady = $true; Reason = 'Missing'; ItemCount = 0 }
    }

    $item = Get-Item -Path $Path -Force -ErrorAction SilentlyContinue
    if ($null -eq $item) {
        return [pscustomobject]@{ IsReady = $false; Reason = 'Unreadable'; ItemCount = 0 }
    }

    # A folder the vault is already mounted on carries a reparse point.
    if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
        return [pscustomobject]@{ IsReady = $false; Reason = 'IsMountPoint'; ItemCount = 0 }
    }

    $count = @(Get-ChildItem -Path $Path -Force -ErrorAction SilentlyContinue).Count
    if ($count -gt 0) {
        return [pscustomobject]@{ IsReady = $false; Reason = 'NotEmpty'; ItemCount = $count }
    }

    [pscustomobject]@{ IsReady = $true; Reason = 'Empty'; ItemCount = 0 }
}

function New-BraveLockerQuarantinePath {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$QuarantineRoot,
        [Parameter(Mandatory)][datetime]$Now
    )

    Join-Path $QuarantineRoot ('stray-profile-' + $Now.ToString('yyyyMMdd-HHmmss'))
}

function Move-BraveLockerStrayProfile {
    <#
        Moves whatever is sitting in the mount folder out of the way.

        It MOVES, never deletes. A stray profile is a real Brave profile that
        someone browsed in, and it may hold a session or a download the user
        wants back. Deleting it to make a mount succeed would be destroying data
        to tidy up, which this tool does not do anywhere else either.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$QuarantineRoot,
        [datetime]$Now = (Get-Date)
    )

    $moved = 0
    $destination = ''

    if (Test-Path $Path) {
        $items = @(Get-ChildItem -Path $Path -Force -ErrorAction SilentlyContinue)
        if ($items.Count -gt 0) {
            $destination = New-BraveLockerQuarantinePath -QuarantineRoot $QuarantineRoot -Now $Now
            New-Item -ItemType Directory -Path $destination -Force | Out-Null

            foreach ($item in $items) {
                Move-Item -Path $item.FullName -Destination $destination -Force -ErrorAction Stop
                $moved++
            }
        }
    }

    [pscustomobject]@{
        MovedCount  = $moved
        Destination = $destination
    }
}

function Initialize-BraveLockerMountFolder {
    <#
        Brings the mount folder to the one state Windows will accept: existing
        and empty. Returns what it had to do, so the launcher can tell the user
        a stray profile was set aside rather than doing it silently.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$QuarantineRoot,
        [datetime]$Now = (Get-Date)
    )

    $state = Test-BraveLockerMountFolderReady -Path $Path

    if ($state.Reason -eq 'IsMountPoint') {
        return [pscustomobject]@{
            IsReady = $false; Action = 'AlreadyMounted'; MovedCount = 0; Destination = ''
        }
    }

    if ($state.Reason -eq 'Missing') {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
        return [pscustomobject]@{
            IsReady = $true; Action = 'Created'; MovedCount = 0; Destination = ''
        }
    }

    if ($state.Reason -eq 'NotEmpty') {
        $result = Move-BraveLockerStrayProfile -Path $Path -QuarantineRoot $QuarantineRoot -Now $Now
        return [pscustomobject]@{
            IsReady     = $true
            Action      = 'QuarantinedStrayProfile'
            MovedCount  = $result.MovedCount
            Destination = $result.Destination
        }
    }

    [pscustomobject]@{ IsReady = $state.IsReady; Action = 'AlreadyEmpty'; MovedCount = 0; Destination = '' }
}
