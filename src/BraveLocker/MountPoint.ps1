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

function Test-BraveLockerStaleMountPoint {
    <#
        Whether this folder is a mount point left pointing at a volume that is
        no longer there.

        A session that ends without a dismount - a crash, a forced shutdown -
        detaches the vault but leaves the directory mount point behind. Nothing
        in the normal dismount path can ever clear it afterwards:
        Remove-BraveLockerVaultAccessPath removes the mount point through the
        PARTITION, and there is no partition once the vault is detached.

        Told apart from a live mount by whether anything can be read through it.
        A mounted vault enumerates; a link to a volume that is gone cannot be
        opened at all.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Path)

    $item = Get-Item -Path $Path -Force -ErrorAction SilentlyContinue
    if ($null -eq $item) { return $false }
    if (-not ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) { return $false }

    try {
        Get-ChildItem -Path $Path -Force -ErrorAction Stop | Out-Null
        return $false
    } catch {
        return $true
    }
}

function Clear-BraveLockerStaleMountPoint {
    <#
        Removes a stale mount point, leaving an ordinary empty folder ready to
        be mounted onto. Reports whether it managed it rather than throwing:
        the launcher runs unelevated and has to be able to say something useful
        when it cannot.

        Only ever removes the LINK. There is nothing on the other side of it to
        remove - that is what makes it stale.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string]$Path)

    $errorMessage = ''

    # mountvol /D is the command built for this. Note that
    # "fsutil reparsepoint delete" is NOT an alternative: it opens the target
    # before deleting and fails with "cannot find the path specified", which is
    # precisely the situation being repaired. Verified on a live stale mount.
    #
    # The trailing backslash is required - mountvol rejects a directory mount
    # point given without one. It also needs administrator rights, so this is
    # expected to fail in the unelevated launcher and fall through below.
    try {
        & "$env:WINDIR\System32\mountvol.exe" "$Path\" /D 2>&1 | Out-Null
    } catch {
        $errorMessage = $_.Exception.Message
    }

    if (Test-BraveLockerStaleMountPoint -Path $Path) {
        # RemoveDirectory deletes the link itself and never follows it, so it
        # works without the target existing - and, unlike mountvol, without
        # administrator rights when the user owns the folder. It takes the whole
        # directory entry, so the empty folder is put back afterwards.
        try {
            [System.IO.Directory]::Delete($Path)
        } catch {
            $errorMessage = $_.Exception.Message
        }
    }

    if (-not (Test-Path $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }

    $cleared = -not (Test-BraveLockerStaleMountPoint -Path $Path)
    if ($cleared) { $errorMessage = '' }

    [pscustomobject]@{ Cleared = $cleared; Error = $errorMessage }
}

function Test-BraveLockerMountFolderReady {
    <#
        Whether the vault can be mounted onto this folder.

        Reasons:
          Missing         - the folder does not exist yet; the caller creates it
          Empty           - ready to mount
          NotEmpty        - a stray profile is sitting in it
          IsMountPoint    - the vault is genuinely mounted here right now
          StaleMountPoint - a mount point left over from a session that never
                            dismounted, pointing at a volume that is gone

        The last two must not be confused. A live mount point means back off;
        a stale one means clear it and carry on. Treating a stale one as live
        left the launcher refusing to open with "something is already mounted,
        restart the PC" - advice that could never work, because a restart does
        not remove a mount point that nothing owns any more.
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
        if (Test-BraveLockerStaleMountPoint -Path $Path) {
            return [pscustomobject]@{ IsReady = $false; Reason = 'StaleMountPoint'; ItemCount = 0 }
        }
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

        A stale mount point is cleared first and then the folder is judged
        again, because clearing one can uncover a stray profile underneath.
        That is why ClearedStaleMountPoint is a flag rather than an Action:
        both can be true of the same launch, and the stray profile is the one
        the user needs told about, since it says where their data went.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$QuarantineRoot,
        [datetime]$Now = (Get-Date)
    )

    $clearedStale = $false
    $state = Test-BraveLockerMountFolderReady -Path $Path

    if ($state.Reason -eq 'StaleMountPoint') {
        # Left by a session that never dismounted. Clearing it is the only way
        # forward - nothing else will ever remove it - so it happens here rather
        # than being reported as a wall the user cannot climb.
        $cleared = Clear-BraveLockerStaleMountPoint -Path $Path
        if (-not $cleared.Cleared) {
            return [pscustomobject]@{
                IsReady = $false; Action = 'StaleMountPointStuck'; MovedCount = 0
                Destination = ''; Error = $cleared.Error; ClearedStaleMountPoint = $false
            }
        }

        $clearedStale = $true
        $state = Test-BraveLockerMountFolderReady -Path $Path
    }

    if ($state.Reason -eq 'IsMountPoint') {
        return [pscustomobject]@{
            IsReady = $false; Action = 'AlreadyMounted'; MovedCount = 0; Destination = ''
            Error = ''; ClearedStaleMountPoint = $clearedStale
        }
    }

    if ($state.Reason -eq 'Missing') {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
        return [pscustomobject]@{
            IsReady = $true; Action = 'Created'; MovedCount = 0; Destination = ''
            Error = ''; ClearedStaleMountPoint = $clearedStale
        }
    }

    if ($state.Reason -eq 'NotEmpty') {
        $result = Move-BraveLockerStrayProfile -Path $Path -QuarantineRoot $QuarantineRoot -Now $Now
        return [pscustomobject]@{
            IsReady                = $true
            Action                 = 'QuarantinedStrayProfile'
            MovedCount             = $result.MovedCount
            Destination            = $result.Destination
            Error                  = ''
            ClearedStaleMountPoint = $clearedStale
        }
    }

    [pscustomobject]@{
        IsReady = $state.IsReady; Action = 'AlreadyEmpty'; MovedCount = 0; Destination = ''
        Error = ''; ClearedStaleMountPoint = $clearedStale
    }
}
