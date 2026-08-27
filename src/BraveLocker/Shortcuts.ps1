function Test-BraveLockerShortcutTargetsBrave {
    <#
        True when a shortcut launches Brave itself. Matching on the executable
        name rather than the full path catches shortcuts left behind by an older
        Brave install, while still ignoring the uninstaller sitting beside it.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][AllowNull()][string]$TargetPath,
        [Parameter(Mandatory)][string]$BraveExe
    )

    if ([string]::IsNullOrWhiteSpace($TargetPath)) { return $false }

    $leaf = [System.IO.Path]::GetFileName($TargetPath.Trim())
    if (-not $leaf) { return $false }

    $leaf.ToLowerInvariant() -eq 'brave.exe'
}

function Get-BraveLockerShortcutBackupPath {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$ShortcutPath,
        [Parameter(Mandatory)][string]$BackupDir
    )

    # The full path is hashed into the name so shortcuts with the same file name
    # in different folders do not collide in the backup directory.
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($ShortcutPath.ToLowerInvariant())
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hash = ($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join ''
    } finally {
        $sha.Dispose()
    }

    $name = [System.IO.Path]::GetFileNameWithoutExtension($ShortcutPath)
    Join-Path $BackupDir ("{0}.{1}.lnk" -f $name, $hash.Substring(0, 12))
}

function Set-BraveLockerShortcutToLauncher {
    <#
        Repoints a Brave shortcut at the locker, keeping its name and icon so it
        still looks and reads like Brave. The original is backed up first.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ShortcutPath,
        [Parameter(Mandatory)][string]$VbsPath,
        [Parameter(Mandatory)][string]$BraveExe,
        [Parameter(Mandatory)][string]$BackupDir
    )

    if (-not (Test-Path $ShortcutPath)) {
        throw "Brave Locker: no shortcut at '$ShortcutPath'."
    }
    if (-not (Test-Path $VbsPath)) {
        throw "Brave Locker: launcher not found at '$VbsPath'."
    }

    if (-not (Test-Path $BackupDir)) {
        New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null
    }

    $backupPath = Get-BraveLockerShortcutBackupPath -ShortcutPath $ShortcutPath -BackupDir $BackupDir

    # Never overwrite an existing backup: on a second run the current shortcut
    # already points at the launcher, and saving it would destroy the only copy
    # of the original.
    if (-not (Test-Path $backupPath)) {
        Copy-Item -Path $ShortcutPath -Destination $backupPath -Force
    }

    $shell = New-Object -ComObject WScript.Shell
    $link = $shell.CreateShortcut($ShortcutPath)
    $link.TargetPath = Join-Path $env:WINDIR 'System32\wscript.exe'
    $link.Arguments = ('"{0}"' -f $VbsPath)
    $link.IconLocation = "$BraveExe,0"
    $link.WorkingDirectory = Split-Path -Parent $VbsPath
    $link.Description = 'Brave'
    $link.Save()
}

function Restore-BraveLockerShortcut {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ShortcutPath,
        [Parameter(Mandatory)][string]$BackupDir
    )

    $backupPath = Get-BraveLockerShortcutBackupPath -ShortcutPath $ShortcutPath -BackupDir $BackupDir
    if (-not (Test-Path $backupPath)) {
        throw "Brave Locker: no backup found for '$ShortcutPath'."
    }

    Copy-Item -Path $backupPath -Destination $ShortcutPath -Force
}

function Get-BraveLockerBraveShortcut {
    <#
        Finds the shortcuts a person actually clicks: desktop, Start menu and
        taskbar, for this user and for all users.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][string]$BraveExe,
        [string[]]$SearchPath
    )

    if (-not $SearchPath) {
        $SearchPath = @(
            [Environment]::GetFolderPath('Desktop')
            [Environment]::GetFolderPath('CommonDesktopDirectory')
            [Environment]::GetFolderPath('Programs')
            [Environment]::GetFolderPath('CommonPrograms')
            (Join-Path $env:APPDATA 'Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar')
        )
    }

    $shell = New-Object -ComObject WScript.Shell
    $found = New-Object System.Collections.Generic.List[string]

    foreach ($path in $SearchPath) {
        if (-not $path -or -not (Test-Path $path)) { continue }

        Get-ChildItem -Path $path -Filter '*.lnk' -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
            try {
                $target = $shell.CreateShortcut($_.FullName).TargetPath
            } catch {
                return
            }
            if (Test-BraveLockerShortcutTargetsBrave -TargetPath $target -BraveExe $BraveExe) {
                $found.Add($_.FullName)
            }
        }
    }

    $found.ToArray()
}
