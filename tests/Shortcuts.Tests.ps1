BeforeAll {
    Import-Module "$PSScriptRoot\..\src\BraveLocker\BraveLocker.psd1" -Force
    $script:brave = 'C:\Program Files\BraveSoftware\Brave-Browser\Application\brave.exe'
}

Describe 'Test-BraveLockerShortcutTargetsBrave' {
    It 'matches a shortcut pointing straight at brave.exe' {
        Test-BraveLockerShortcutTargetsBrave -TargetPath $script:brave -BraveExe $script:brave | Should -BeTrue
    }

    It 'ignores case and trailing spaces' {
        Test-BraveLockerShortcutTargetsBrave -TargetPath ('  ' + $script:brave.ToUpper() + ' ') -BraveExe $script:brave |
            Should -BeTrue
    }

    It 'matches any brave.exe even from a different install location' {
        Test-BraveLockerShortcutTargetsBrave -TargetPath 'D:\Portable\Brave\brave.exe' -BraveExe $script:brave |
            Should -BeTrue
    }

    It 'does NOT match Chrome' {
        Test-BraveLockerShortcutTargetsBrave -TargetPath 'C:\Program Files\Google\Chrome\Application\chrome.exe' `
            -BraveExe $script:brave | Should -BeFalse
    }

    It 'does NOT match the Brave uninstaller' {
        Test-BraveLockerShortcutTargetsBrave -TargetPath 'C:\Program Files\BraveSoftware\Brave-Browser\Application\uninstall.exe' `
            -BraveExe $script:brave | Should -BeFalse
    }

    It 'does NOT match a shortcut already taken over by the locker' {
        Test-BraveLockerShortcutTargetsBrave -TargetPath 'C:\Windows\System32\wscript.exe' -BraveExe $script:brave |
            Should -BeFalse
    }

    It 'handles an empty target without throwing' {
        Test-BraveLockerShortcutTargetsBrave -TargetPath '' -BraveExe $script:brave | Should -BeFalse
    }
}

Describe 'shortcut takeover round-trip' {
    BeforeEach {
        $script:workDir = Join-Path $TestDrive (New-Guid).Guid
        New-Item -ItemType Directory -Path $script:workDir | Out-Null
        $script:lnk = Join-Path $script:workDir 'Brave.lnk'
        $script:backupDir = Join-Path $script:workDir 'backup'

        $shell = New-Object -ComObject WScript.Shell
        $link = $shell.CreateShortcut($script:lnk)
        $link.TargetPath = $script:brave
        $link.Arguments = '--some-flag'
        $link.Save()

        $script:vbs = Join-Path $script:workDir 'Launcher.vbs'
        Set-Content -Path $script:vbs -Value "' launcher" -Encoding ascii
    }

    It 'repoints the shortcut at the launcher while keeping the Brave icon' {
        Set-BraveLockerShortcutToLauncher -ShortcutPath $script:lnk -VbsPath $script:vbs `
            -BraveExe $script:brave -BackupDir $script:backupDir

        $shell = New-Object -ComObject WScript.Shell
        $link = $shell.CreateShortcut($script:lnk)
        $link.TargetPath | Should -Match 'wscript\.exe$'
        $link.Arguments  | Should -Match ([regex]::Escape($script:vbs))
        $link.IconLocation | Should -Match 'brave\.exe'
    }

    It 'backs the original up before changing it' {
        Set-BraveLockerShortcutToLauncher -ShortcutPath $script:lnk -VbsPath $script:vbs `
            -BraveExe $script:brave -BackupDir $script:backupDir

        # Wrapped in @() because a single result is a scalar, and .Count on a
        # scalar throws under Set-StrictMode -Version Latest - which the build
        # script sets, so this passed locally and failed the moment it mattered.
        @(Get-ChildItem -Path $script:backupDir -Filter '*.lnk').Count | Should -Be 1
    }

    It 'restores the original target exactly' {
        Set-BraveLockerShortcutToLauncher -ShortcutPath $script:lnk -VbsPath $script:vbs `
            -BraveExe $script:brave -BackupDir $script:backupDir
        Restore-BraveLockerShortcut -ShortcutPath $script:lnk -BackupDir $script:backupDir

        $shell = New-Object -ComObject WScript.Shell
        $link = $shell.CreateShortcut($script:lnk)
        $link.TargetPath | Should -Be $script:brave
        $link.Arguments  | Should -Be '--some-flag'
    }

    It 'does not overwrite an existing backup when run twice' {
        # Running takeover twice must not replace the good backup with a
        # shortcut that already points at the launcher - that would make the
        # original unrecoverable.
        Set-BraveLockerShortcutToLauncher -ShortcutPath $script:lnk -VbsPath $script:vbs `
            -BraveExe $script:brave -BackupDir $script:backupDir
        Set-BraveLockerShortcutToLauncher -ShortcutPath $script:lnk -VbsPath $script:vbs `
            -BraveExe $script:brave -BackupDir $script:backupDir
        Restore-BraveLockerShortcut -ShortcutPath $script:lnk -BackupDir $script:backupDir

        $shell = New-Object -ComObject WScript.Shell
        (New-Object -ComObject WScript.Shell).CreateShortcut($script:lnk).TargetPath | Should -Be $script:brave
    }
}

Describe 'shortcut takeover manifest' {
    BeforeEach {
        $script:workDir = Join-Path $TestDrive (New-Guid).Guid
        New-Item -ItemType Directory -Path $script:workDir | Out-Null
        $script:backupDir = Join-Path $script:workDir 'backup'
        $script:vbs = Join-Path $script:workDir 'Launcher.vbs'
        Set-Content -Path $script:vbs -Value "' launcher" -Encoding ascii

        $shell = New-Object -ComObject WScript.Shell
        # Deliberately not called "Brave.lnk", and nested, because that is the
        # case the uninstaller used to be unable to restore.
        $nested = Join-Path $script:workDir 'Start Menu\Brave'
        New-Item -ItemType Directory -Path $nested -Force | Out-Null
        $script:oddLnk = Join-Path $nested 'Brave Browser.lnk'
        $link = $shell.CreateShortcut($script:oddLnk)
        $link.TargetPath = $script:brave
        $link.Save()
    }

    It 'is empty before any takeover' {
        Get-BraveLockerShortcutManifest -BackupDir $script:backupDir | Should -BeNullOrEmpty
    }

    It 'records a taken-over shortcut by its original path' {
        Set-BraveLockerShortcutToLauncher -ShortcutPath $script:oddLnk -VbsPath $script:vbs `
            -BraveExe $script:brave -BackupDir $script:backupDir

        @(Get-BraveLockerShortcutManifest -BackupDir $script:backupDir) | Should -Be @($script:oddLnk)
    }

    It 'does not record the same shortcut twice' {
        Set-BraveLockerShortcutToLauncher -ShortcutPath $script:oddLnk -VbsPath $script:vbs `
            -BraveExe $script:brave -BackupDir $script:backupDir
        Set-BraveLockerShortcutToLauncher -ShortcutPath $script:oddLnk -VbsPath $script:vbs `
            -BraveExe $script:brave -BackupDir $script:backupDir

        @(Get-BraveLockerShortcutManifest -BackupDir $script:backupDir).Count | Should -Be 1
    }

    It 'lets a shortcut that is not called Brave.lnk be restored' {
        # The uninstaller can only find a backup if it knows the original path:
        # the backup file name is a hash of that path and cannot be reversed.
        Set-BraveLockerShortcutToLauncher -ShortcutPath $script:oddLnk -VbsPath $script:vbs `
            -BraveExe $script:brave -BackupDir $script:backupDir

        foreach ($recorded in Get-BraveLockerShortcutManifest -BackupDir $script:backupDir) {
            Restore-BraveLockerShortcut -ShortcutPath $recorded -BackupDir $script:backupDir
        }

        (New-Object -ComObject WScript.Shell).CreateShortcut($script:oddLnk).TargetPath |
            Should -Be $script:brave
    }

    It 'records every shortcut when several are taken over' {
        $second = Join-Path $script:workDir 'Desktop Brave.lnk'
        $link = (New-Object -ComObject WScript.Shell).CreateShortcut($second)
        $link.TargetPath = $script:brave
        $link.Save()

        Set-BraveLockerShortcutToLauncher -ShortcutPath $script:oddLnk -VbsPath $script:vbs `
            -BraveExe $script:brave -BackupDir $script:backupDir
        Set-BraveLockerShortcutToLauncher -ShortcutPath $second -VbsPath $script:vbs `
            -BraveExe $script:brave -BackupDir $script:backupDir

        $manifest = @(Get-BraveLockerShortcutManifest -BackupDir $script:backupDir)
        $manifest.Count | Should -Be 2
        $manifest | Should -Contain $second
    }

    It 'treats a damaged manifest as nothing to restore rather than throwing' {
        Set-BraveLockerShortcutToLauncher -ShortcutPath $script:oddLnk -VbsPath $script:vbs `
            -BraveExe $script:brave -BackupDir $script:backupDir
        Set-Content -Path (Get-BraveLockerShortcutManifestPath -BackupDir $script:backupDir) `
            -Value '{ not json' -Encoding utf8

        Get-BraveLockerShortcutManifest -BackupDir $script:backupDir | Should -BeNullOrEmpty
    }
}

Describe 'Test-BraveLockerShortcutIsLauncher' {
    # A browser update rewrites TargetPath back to the browser and leaves
    # Arguments alone, so the hijacked shortcut still carries the launcher's
    # .vbs path. Anything that checks the arguments sees a locked shortcut; only
    # the target says what actually runs.
    It 'is true for the launcher' {
        Test-BraveLockerShortcutIsLauncher -TargetPath 'C:\Windows\System32\wscript.exe' | Should -BeTrue
    }

    It 'ignores case and path, matching on the executable' {
        Test-BraveLockerShortcutIsLauncher -TargetPath 'C:\WINDOWS\SysWOW64\WScript.EXE' | Should -BeTrue
    }

    It 'is false once an update has pointed it back at the browser' {
        Test-BraveLockerShortcutIsLauncher -TargetPath 'C:\Program Files\BraveSoftware\Brave-Browser\Application\brave.exe' |
            Should -BeFalse
    }

    It 'is false for an empty target' {
        Test-BraveLockerShortcutIsLauncher -TargetPath '' | Should -BeFalse
    }
}

Describe 'Get-BraveLockerHijackedShortcut' {
    BeforeEach {
        $script:work = Join-Path $TestDrive (New-Guid).Guid
        New-Item -ItemType Directory -Path $script:work | Out-Null
        $script:shell = New-Object -ComObject WScript.Shell
    }

    It 'finds a shortcut a browser update pointed back at the browser' {
        # The exact shape found on a live install after Brave updated itself:
        # target reset to the browser, the locker's arguments still attached -
        # which is why the arguments are no use for telling the two apart.
        $path = Join-Path $script:work 'Brave.lnk'
        $link = $script:shell.CreateShortcut($path)
        $link.TargetPath = 'C:\Windows\System32\notepad.exe'
        $link.Arguments = '"C:\Program Files\BraveLocker\scripts\BraveLockerLauncher.vbs"'
        $link.Save()

        @(Get-BraveLockerHijackedShortcut -ShortcutPath @($path)) | Should -Contain $path
    }

    It 'leaves a shortcut that still points at the launcher alone' {
        $path = Join-Path $script:work 'Brave.lnk'
        $link = $script:shell.CreateShortcut($path)
        $link.TargetPath = Join-Path $env:WINDIR 'System32\wscript.exe'
        $link.Arguments = '"C:\Program Files\BraveLocker\scripts\BraveLockerLauncher.vbs"'
        $link.Save()

        @(Get-BraveLockerHijackedShortcut -ShortcutPath @($path)).Count | Should -Be 0
    }

    It 'skips a shortcut that is no longer there' {
        $missing = Join-Path $script:work 'Gone.lnk'
        @(Get-BraveLockerHijackedShortcut -ShortcutPath @($missing)).Count | Should -Be 0
    }

    It 'copes with an empty list' {
        @(Get-BraveLockerHijackedShortcut -ShortcutPath @()).Count | Should -Be 0
    }
}

Describe 'Install-BraveLockerRescueItems' {
    BeforeEach {
        $script:work = Join-Path $TestDrive (New-Guid).Guid
        $script:installRoot = Join-Path $script:work 'install'
        $script:startMenu = Join-Path $script:work 'startmenu'
        New-Item -ItemType Directory -Path (Join-Path $script:installRoot 'scripts') -Force | Out-Null
        New-Item -ItemType Directory -Path $script:startMenu -Force | Out-Null
        $script:card = Join-Path $script:work 'EMERGENCY-CARD.md'
        Set-Content -Path $script:card -Value 'open the vault with nothing but Windows' -Encoding utf8
    }

    It 'installs the card as .txt, so a double-click opens Notepad' {
        # A .md file asks the user to choose a program they have never heard of,
        # at the exact moment they are least able to deal with it.
        $r = Install-BraveLockerRescueItems -InstallRoot $script:installRoot `
            -CardSourcePath $script:card -StartMenuFolder $script:startMenu

        $r.CardPath | Should -Match '\.txt$'
        Test-Path $r.CardPath | Should -BeTrue
        Get-Content $r.CardPath -Raw | Should -Match 'nothing but Windows'
    }

    It 'puts the card in the Start menu' {
        Install-BraveLockerRescueItems -InstallRoot $script:installRoot `
            -CardSourcePath $script:card -StartMenuFolder $script:startMenu | Out-Null

        $link = Join-Path $script:startMenu 'Browser Locker - Emergency Card.lnk'
        Test-Path $link | Should -BeTrue

        $shell = New-Object -ComObject WScript.Shell
        $shell.CreateShortcut($link).TargetPath | Should -Match 'notepad\.exe$'
    }

    It 'adds a Repair shortcut when the repair script is installed' {
        Set-Content -Path (Join-Path $script:installRoot 'scripts\Repair-BraveLocker.ps1') `
            -Value '# repair' -Encoding utf8

        Install-BraveLockerRescueItems -InstallRoot $script:installRoot `
            -CardSourcePath $script:card -StartMenuFolder $script:startMenu | Out-Null

        Test-Path (Join-Path $script:startMenu 'Browser Locker - Repair.lnk') | Should -BeTrue
    }

    It 'does NOT put "turn the lock off" in the Start menu' {
        # It is reachable from the recovery dialog and from the card. A one-click
        # "remove my security" item in the Start menu is its own kind of accident.
        Install-BraveLockerRescueItems -InstallRoot $script:installRoot `
            -CardSourcePath $script:card -StartMenuFolder $script:startMenu | Out-Null

        @(Get-ChildItem $script:startMenu -Filter '*.lnk' | Where-Object { $_.Name -match 'Unlock|Turn' }).Count |
            Should -Be 0
    }

    It 'refuses rather than installing a shortcut to a card that is not there' {
        { Install-BraveLockerRescueItems -InstallRoot $script:installRoot `
            -CardSourcePath (Join-Path $script:work 'nope.md') -StartMenuFolder $script:startMenu } |
            Should -Throw '*emergency card is missing*'
    }

    It 'is idempotent - running it twice leaves one of each' {
        Install-BraveLockerRescueItems -InstallRoot $script:installRoot `
            -CardSourcePath $script:card -StartMenuFolder $script:startMenu | Out-Null
        Install-BraveLockerRescueItems -InstallRoot $script:installRoot `
            -CardSourcePath $script:card -StartMenuFolder $script:startMenu | Out-Null

        @(Get-ChildItem $script:startMenu -Filter '*.lnk').Count | Should -Be 1
    }
}

Describe 'the emergency card survives being read anywhere' {
    BeforeEach {
        $script:work = Join-Path $TestDrive (New-Guid).Guid
        $script:installRoot = Join-Path $script:work 'install'
        $script:startMenu = Join-Path $script:work 'startmenu'
        New-Item -ItemType Directory -Path $script:installRoot -Force | Out-Null
        New-Item -ItemType Directory -Path $script:startMenu -Force | Out-Null
    }

    It 'folds typographic characters down to plain ASCII' {
        # A UTF-8 file with no BOM read as ANSI turns an em-dash into "a EUR"".
        # That happened on the first real install, to the one document that has
        # to stay readable when everything else has gone wrong.
        $source = Join-Path $script:work 'card.md'
        $fancy = "Dash {0} here, quote {1}word{2}, arrow {3}, ellipsis {4}" -f `
            ([char]0x2014), ([char]0x201C), ([char]0x201D), ([char]0x2192), ([char]0x2026)
        Set-Content -Path $source -Value $fancy -Encoding UTF8

        $r = Install-BraveLockerRescueItems -InstallRoot $script:installRoot `
            -CardSourcePath $source -StartMenuFolder $script:startMenu

        $bytes = [System.IO.File]::ReadAllBytes($r.CardPath)
        @($bytes | Where-Object { $_ -gt 127 }).Count |
            Should -Be 0 -Because 'a byte above 127 is a character some editor will render as mojibake'
    }

    It 'keeps the words, not just the bytes' {
        $source = Join-Path $script:work 'card.md'
        Set-Content -Path $source -Value ("Right-click {0} Mount" -f ([char]0x2192)) -Encoding UTF8

        $r = Install-BraveLockerRescueItems -InstallRoot $script:installRoot `
            -CardSourcePath $source -StartMenuFolder $script:startMenu

        Get-Content $r.CardPath -Raw | Should -Match 'Right-click -> Mount'
    }
}

Describe 'the shipped emergency card' {
    It 'is pure ASCII at source, so it cannot be mis-decoded anywhere' {
        $card = Join-Path (Split-Path -Parent $PSScriptRoot) 'docs\EMERGENCY-CARD.md'
        Test-Path $card | Should -BeTrue
        @([System.IO.File]::ReadAllBytes($card) | Where-Object { $_ -gt 127 }).Count | Should -Be 0
    }

    It 'tells the user the one thing that destroys their data' {
        $card = Join-Path (Split-Path -Parent $PSScriptRoot) 'docs\EMERGENCY-CARD.md'
        Get-Content $card -Raw | Should -Match 'Do not delete the vault file'
    }

    It 'documents the path that needs no Browser Locker files at all' {
        $card = Join-Path (Split-Path -Parent $PSScriptRoot) 'docs\EMERGENCY-CARD.md'
        $text = Get-Content $card -Raw
        $text | Should -Match 'Mount-DiskImage'
        $text | Should -Match 'manage-bde'
    }
}
