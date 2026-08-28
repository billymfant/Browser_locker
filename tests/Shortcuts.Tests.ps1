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

        (Get-ChildItem -Path $script:backupDir -Filter '*.lnk').Count | Should -Be 1
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
