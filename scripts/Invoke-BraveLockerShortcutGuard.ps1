#Requires -Version 5.1
<#
    Runs at logon, elevated, from the BraveLocker-ShortcutGuard task.

    Puts the lock back on any shortcut that has stopped pointing at the
    launcher. A browser update rewrites its own Start menu shortcut - target
    reset to the browser, arguments left alone - which silently takes the lock
    off: clicking Brave starts Brave directly and no passphrase is ever asked
    for.

    The launcher cannot fix this itself, because a hijacked shortcut is exactly
    what stops the launcher running. Hence a trigger from outside.

    It is deliberately silent and non-fatal. Nobody is watching a logon task, so
    it writes what it did to a log and never blocks logon over a shortcut.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot

try {
    Import-Module (Join-Path $repoRoot 'src\BraveLocker\BraveLocker.psd1') -Force

    $paths = Get-BraveLockerPaths
    $logPath = Join-Path $paths.StateRoot 'shortcut-guard.log'

    # Not set up, or the lock was never applied: nothing to guard.
    if (-not (Test-Path $paths.ConfigPath)) { return }
    $config = Get-Content -Path $paths.ConfigPath -Raw | ConvertFrom-Json

    $appLocked = Get-BraveLockerPropertyValue -InputObject $config -Name 'AppLocked'
    if (-not $appLocked) { return }

    $installRoot = [string](Get-BraveLockerPropertyValue -InputObject $config -Name 'InstallRoot')
    if ([string]::IsNullOrWhiteSpace($installRoot)) { $installRoot = 'C:\Program Files\BraveLocker' }

    $browserExe = [string](Get-BraveLockerPropertyValue -InputObject $config -Name 'BrowserExe')
    if (-not $browserExe) { $browserExe = [string](Get-BraveLockerPropertyValue -InputObject $config -Name 'BraveExe') }

    $vbs = Join-Path $installRoot 'scripts\BraveLockerLauncher.vbs'
    if (-not (Test-Path $vbs)) {
        throw "The launcher is missing from the installed copy: '$vbs'."
    }

    $backupDir = Join-Path $paths.StateRoot 'shortcut-backup'

    # The manifest is what the locker took over. Discovery is added on top,
    # because an updater can create a NEW shortcut the manifest has never seen -
    # and that one launches the browser unlocked just as effectively.
    $candidates = New-Object System.Collections.Generic.List[string]
    foreach ($entry in @(Get-BraveLockerShortcutManifest -BackupDir $backupDir)) {
        if (-not $candidates.Contains($entry)) { $candidates.Add($entry) }
    }
    if ($browserExe) {
        foreach ($entry in @(Get-BraveLockerBraveShortcut -BraveExe $browserExe)) {
            if (-not $candidates.Contains($entry)) { $candidates.Add($entry) }
        }
    }

    $hijacked = @(Get-BraveLockerHijackedShortcut -ShortcutPath $candidates.ToArray())
    if ($hijacked.Count -eq 0) { return }   # Silent when there is nothing to do.

    $repaired = New-Object System.Collections.Generic.List[string]
    foreach ($shortcut in $hijacked) {
        Set-BraveLockerShortcutToLauncher -ShortcutPath $shortcut -VbsPath $vbs `
            -BraveExe $browserExe -BackupDir $backupDir
        $repaired.Add($shortcut)
    }

    $stamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    Add-Content -Path $logPath -Encoding utf8 -Value (
        @("[$stamp] re-locked $($repaired.Count) shortcut(s):") +
        ($repaired | ForEach-Object { "    $_" })
    )
}
catch {
    # A logon task must never surface an error at the user or hold up logon.
    try {
        $fallback = Join-Path (Join-Path $env:LOCALAPPDATA 'BraveLocker') 'shortcut-guard.log'
        Add-Content -Path $fallback -Encoding utf8 -Value (
            "[{0}] failed: {1}" -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $_.Exception.Message
        )
    } catch {
        # Nothing left to try. Staying quiet beats breaking logon.
    }
}
