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
        [Parameter(Mandatory)][string]$BraveExe,
        # Overrides the executable derived from BraveExe. Lets a caller ask
        # "does this shortcut launch chrome.exe" without owning a path to it.
        [string]$ExeName = ''
    )

    if ([string]::IsNullOrWhiteSpace($TargetPath)) { return $false }

    $leaf = [System.IO.Path]::GetFileName($TargetPath.Trim())
    if (-not $leaf) { return $false }

    # Which executable counts is taken from the browser being locked, not
    # assumed to be Brave - the tool can lock Chrome, Edge, Vivaldi or Opera.
    $wanted = $ExeName
    if ([string]::IsNullOrWhiteSpace($wanted)) {
        $wanted = [System.IO.Path]::GetFileName($BraveExe.Trim())
    }
    if ([string]::IsNullOrWhiteSpace($wanted)) { return $false }

    $leaf.ToLowerInvariant() -eq $wanted.ToLowerInvariant()
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

    # Recorded only after the shortcut has actually been repointed, so the
    # manifest never claims a takeover that did not happen.
    Add-BraveLockerShortcutManifestEntry -BackupDir $BackupDir -ShortcutPath $ShortcutPath | Out-Null
}

function Test-BraveLockerShortcutIsLauncher {
    <#
        Whether this shortcut still launches the locker.

        The test is the TARGET only, deliberately. A browser update rewrites
        TargetPath back to the browser but leaves Arguments untouched, so a
        hijacked shortcut still carries the launcher's .vbs path and looks
        locked to anything that checks the arguments. The target is the half
        that decides what actually runs.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][AllowNull()][string]$TargetPath
    )

    if ([string]::IsNullOrWhiteSpace($TargetPath)) { return $false }

    $leaf = [System.IO.Path]::GetFileName($TargetPath.Trim())
    if ([string]::IsNullOrWhiteSpace($leaf)) { return $false }

    $leaf.ToLowerInvariant() -eq 'wscript.exe'
}

function Get-BraveLockerHijackedShortcut {
    <#
        Which of these shortcuts have stopped pointing at the launcher.

        Missing shortcuts and unreadable ones are skipped rather than reported:
        there is nothing to repair about a shortcut that is not there.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [AllowNull()]
        [string[]]$ShortcutPath
    )

    $shell = New-Object -ComObject WScript.Shell
    $hijacked = New-Object System.Collections.Generic.List[string]

    foreach ($path in $ShortcutPath) {
        if ([string]::IsNullOrWhiteSpace($path)) { continue }
        if (-not (Test-Path $path)) { continue }

        $target = ''
        try { $target = [string]$shell.CreateShortcut($path).TargetPath } catch { continue }

        if (-not (Test-BraveLockerShortcutIsLauncher -TargetPath $target)) {
            $hijacked.Add($path)
        }
    }

    $hijacked.ToArray()
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
        [string]$ExeName = '',
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
            if (Test-BraveLockerShortcutTargetsBrave -TargetPath $target -BraveExe $BraveExe -ExeName $ExeName) {
                $found.Add($_.FullName)
            }
        }
    }

    $found.ToArray()
}

function Get-BraveLockerShortcutManifestPath {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$BackupDir)

    Join-Path $BackupDir 'shortcuts.json'
}

function Get-BraveLockerShortcutManifest {
    <#
        The shortcuts the locker has taken over, by their original path.

        A backup file is named after a hash of that path, which cannot be
        reversed - so without this record the uninstaller has no way to match a
        backup back to the shortcut it came from, and would leave the user
        clicking a launcher whose config it had just deleted.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)][string]$BackupDir)

    $manifestPath = Get-BraveLockerShortcutManifestPath -BackupDir $BackupDir
    if (-not (Test-Path $manifestPath)) { return @() }

    try {
        $entries = Get-Content -Path $manifestPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    } catch {
        # A damaged manifest must not stop an uninstall; the caller falls back
        # to reporting that it found nothing to restore.
        return @()
    }

    @($entries | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { [string]$_ })
}

function Add-BraveLockerShortcutManifestEntry {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][string]$BackupDir,
        [Parameter(Mandatory)][string]$ShortcutPath
    )

    if (-not (Test-Path $BackupDir)) {
        New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null
    }

    $entries = @(Get-BraveLockerShortcutManifest -BackupDir $BackupDir)
    if ($entries -notcontains $ShortcutPath) { $entries += $ShortcutPath }

    ConvertTo-Json -InputObject ([string[]]$entries) -Depth 3 |
        Set-Content -Path (Get-BraveLockerShortcutManifestPath -BackupDir $BackupDir) -Encoding utf8

    $entries
}

function Install-BraveLockerRescueItems {
    <#
        Puts the emergency card and the repair tool somewhere a person can
        actually find them.

        Instructions that live only in a repo, or only in the head of whoever
        set the tool up, are not instructions. When the browser will not open
        the user has no working browser to read a web page with either - so the
        card is installed as plain text that Notepad can open, and reached from
        the Start menu next to the browser itself.

        The card is deliberately NOT html. Every other format assumes something
        still works.

        "Turn the lock off" is deliberately absent from the Start menu. It is
        reachable from the recovery dialog, which is where someone who is stuck
        will meet it, and from the card. A one-click "remove my security" item
        sitting in the Start menu is a different kind of accident.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$InstallRoot,
        [Parameter(Mandatory)][string]$CardSourcePath,
        # Defaults to the all-users Start menu, which is where the browser
        # shortcut this sits beside already lives.
        [string]$StartMenuFolder = ''
    )

    if (-not (Test-Path $CardSourcePath)) {
        throw "Brave Locker: the emergency card is missing from '$CardSourcePath'."
    }

    if ([string]::IsNullOrWhiteSpace($StartMenuFolder)) {
        $StartMenuFolder = [Environment]::GetFolderPath('CommonPrograms')
    }
    if (-not (Test-Path $StartMenuFolder)) {
        New-Item -ItemType Directory -Path $StartMenuFolder -Force | Out-Null
    }

    # .txt, so a double-click opens Notepad rather than asking the user which
    # program should handle a .md file they have never heard of.
    $cardTarget = Join-Path $InstallRoot 'Browser Locker - Emergency Card.txt'

    # Written as ASCII, with typographic characters folded down first.
    #
    # A UTF-8 file with no BOM opened as ANSI turns an em-dash into "â€”", and
    # that is exactly what happened the first time this was installed. This is
    # the one document that has to stay readable on a machine where everything
    # else has gone wrong - including a machine that is not this one, in an
    # editor nobody chose - so it uses only characters that cannot be
    # misdecoded.
    # Each replacement is string-to-string. Passing a [char] as the first
    # argument picks String.Replace(char, char), which then refuses a
    # replacement like '...' that is not exactly one character long.
    $folds = [ordered]@{
        ([string][char]0x2014) = '-'      # em dash
        ([string][char]0x2013) = '-'      # en dash
        ([string][char]0x2018) = "'"      # left single quote
        ([string][char]0x2019) = "'"      # right single quote
        ([string][char]0x201C) = '"'      # left double quote
        ([string][char]0x201D) = '"'      # right double quote
        ([string][char]0x2192) = '->'     # right arrow
        ([string][char]0x2190) = '<-'     # left arrow
        ([string][char]0x2026) = '...'    # ellipsis
        ([string][char]0x00A0) = ' '      # non-breaking space
    }

    $folded = Get-Content -Path $CardSourcePath -Raw -Encoding UTF8
    foreach ($from in $folds.Keys) { $folded = $folded.Replace($from, $folds[$from]) }

    # Anything still outside ASCII would be a character this list has not met.
    # Drop it rather than ship a card with a question mark in the middle of an
    # instruction.
    $folded = [regex]::Replace($folded, '[^\x00-\x7F]', '')

    Set-Content -Path $cardTarget -Value $folded -Encoding ascii

    $shell = New-Object -ComObject WScript.Shell
    $created = New-Object System.Collections.Generic.List[string]

    $cardLink = Join-Path $StartMenuFolder 'Browser Locker - Emergency Card.lnk'
    $link = $shell.CreateShortcut($cardLink)
    $link.TargetPath = Join-Path $env:WINDIR 'System32\notepad.exe'
    $link.Arguments = ('"{0}"' -f $cardTarget)
    $link.Description = 'What to do if your browser will not open'
    $link.Save()
    $created.Add($cardLink)

    $repairScript = Join-Path $InstallRoot 'scripts\Repair-BraveLocker.ps1'
    if (Test-Path $repairScript) {
        $repairLink = Join-Path $StartMenuFolder 'Browser Locker - Repair.lnk'
        $link = $shell.CreateShortcut($repairLink)
        $link.TargetPath = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $link.Arguments = ('-NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $repairScript)
        $link.Description = 'Fix the browser lock when the browser will not open'
        $link.Save()
        $created.Add($repairLink)
    }

    [pscustomobject]@{
        CardPath  = $cardTarget
        Shortcuts = $created.ToArray()
    }
}
