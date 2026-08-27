function New-BraveLockerShortcut {
    <#
        Creates the launcher shortcut. It points at the VBScript wrapper rather
        than powershell.exe directly, so no console window ever appears - the
        passphrase popup is the first thing the user sees.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$InstallRoot,
        [Parameter(Mandatory)][string]$BraveExe,
        [string]$ShortcutPath = (Join-Path ([Environment]::GetFolderPath('Desktop')) 'Brave (Private).lnk'),
        [switch]$AlsoStartMenu
    )

    $vbs = Join-Path $InstallRoot 'scripts\BraveLockerLauncher.vbs'
    if (-not (Test-Path $vbs)) {
        throw "Brave Locker: launcher not found at '$vbs'."
    }

    $targets = @($ShortcutPath)
    if ($AlsoStartMenu) {
        $startMenu = Join-Path ([Environment]::GetFolderPath('Programs')) 'Brave (Private).lnk'
        $targets += $startMenu
    }

    $shell = New-Object -ComObject WScript.Shell
    foreach ($target in $targets) {
        $dir = Split-Path -Parent $target
        if ($dir -and -not (Test-Path $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }

        $link = $shell.CreateShortcut($target)
        $link.TargetPath = 'wscript.exe'
        $link.Arguments = ('"{0}"' -f $vbs)
        $link.WorkingDirectory = $InstallRoot
        $link.IconLocation = $BraveExe
        $link.Description = 'Open Brave with the encrypted private profile.'
        $link.Save()
    }

    $ShortcutPath
}
