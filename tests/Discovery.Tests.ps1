BeforeAll {
    Import-Module "$PSScriptRoot\..\src\BraveLocker\BraveLocker.psd1" -Force
}

Describe 'Test-BraveLockerCryptoAvailable' {
    It 'refuses Windows Home, where BitLocker does not exist' {
        $r = Test-BraveLockerCryptoAvailable -Provider 'BitLocker' `
            -EditionOverride 'Microsoft Windows 11 Home' -CommandOverride $true
        $r.IsAvailable | Should -BeFalse
        $r.Reason      | Should -Be 'HomeEdition'
    }

    It 'refuses Home Single Language too' {
        (Test-BraveLockerCryptoAvailable -Provider 'BitLocker' `
            -EditionOverride 'Microsoft Windows 11 Home Single Language' -CommandOverride $true).Reason |
            Should -Be 'HomeEdition'
    }

    It 'accepts Pro' {
        $r = Test-BraveLockerCryptoAvailable -Provider 'BitLocker' `
            -EditionOverride 'Microsoft Windows 11 Pro' -CommandOverride $true
        $r.IsAvailable | Should -BeTrue
    }

    It 'accepts Enterprise and Education' {
        foreach ($edition in 'Microsoft Windows 11 Enterprise', 'Microsoft Windows 11 Education') {
            (Test-BraveLockerCryptoAvailable -Provider 'BitLocker' `
                -EditionOverride $edition -CommandOverride $true).IsAvailable | Should -BeTrue
        }
    }

    It 'refuses when the cmdlets are missing even on Pro' {
        $r = Test-BraveLockerCryptoAvailable -Provider 'BitLocker' `
            -EditionOverride 'Microsoft Windows 11 Pro' -CommandOverride $false
        $r.IsAvailable | Should -BeFalse
        $r.Reason      | Should -Be 'CmdletsMissing'
    }

    It 'refuses an unknown provider rather than pretending' {
        (Test-BraveLockerCryptoAvailable -Provider 'VeraCrypt').Reason | Should -Be 'UnknownProvider'
    }

    It 'explains itself in words a non-programmer can act on' {
        $r = Test-BraveLockerCryptoAvailable -Provider 'BitLocker' `
            -EditionOverride 'Microsoft Windows 11 Home' -CommandOverride $true
        $r.Detail | Should -Match 'Pro, Enterprise or Education'
    }
}

Describe 'Test-BraveLockerProfileUsable' {
    BeforeEach {
        $script:work = Join-Path $TestDrive (New-Guid).Guid
        New-Item -ItemType Directory -Path $script:work | Out-Null
    }

    It 'rejects a folder that does not exist' {
        (Test-BraveLockerProfileUsable -Path (Join-Path $script:work 'nope')).Reason | Should -Be 'Missing'
    }

    It 'rejects a folder with no Local State - that is not a Brave profile' {
        New-Item -ItemType Directory -Path (Join-Path $script:work 'Default') | Out-Null
        (Test-BraveLockerProfileUsable -Path $script:work).Reason | Should -Be 'NoLocalState'
    }

    It 'rejects Local State with no profile directories' {
        Set-Content -Path (Join-Path $script:work 'Local State') -Value '{}' -Encoding utf8
        (Test-BraveLockerProfileUsable -Path $script:work).Reason | Should -Be 'NoProfiles'
    }

    It 'accepts a real-looking profile' {
        Set-Content -Path (Join-Path $script:work 'Local State') -Value '{}' -Encoding utf8
        New-Item -ItemType Directory -Path (Join-Path $script:work 'Default') | Out-Null
        $r = Test-BraveLockerProfileUsable -Path $script:work
        $r.IsUsable     | Should -BeTrue
        $r.ProfileCount | Should -Be 1
    }

    It 'finds numbered profiles, not just Default' {
        # The real profile on the machine this was built for is "Profile 3",
        # and assuming Default is where the data lives is exactly the kind of
        # thing that ships broken.
        Set-Content -Path (Join-Path $script:work 'Local State') -Value '{}' -Encoding utf8
        New-Item -ItemType Directory -Path (Join-Path $script:work 'Profile 3') | Out-Null
        (Test-BraveLockerProfileUsable -Path $script:work).ProfileCount | Should -Be 1
    }

    It 'ignores folders that merely look profile-ish' {
        Set-Content -Path (Join-Path $script:work 'Local State') -Value '{}' -Encoding utf8
        New-Item -ItemType Directory -Path (Join-Path $script:work 'Crashpad') | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $script:work 'System Profile') | Out-Null
        (Test-BraveLockerProfileUsable -Path $script:work).Reason | Should -Be 'NoProfiles'
    }
}

Describe 'Get-BraveLockerVaultSizeMB' {
    It 'gives a small profile the 8 GB floor' {
        Get-BraveLockerVaultSizeMB -ProfileSizeBytes 200MB | Should -Be (8 * 1024)
    }

    It 'gives room to grow for a normal profile' {
        # 1.2 GB profile -> 5 GB of headroom, not 1.2 GB of none.
        Get-BraveLockerVaultSizeMB -ProfileSizeBytes 1.2GB | Should -BeGreaterThan (4 * 1024)
    }

    It 'caps at 128 GB so a huge profile cannot ask for a silly vault' {
        Get-BraveLockerVaultSizeMB -ProfileSizeBytes 500GB | Should -Be (128 * 1024)
    }
}

Describe 'Select-BraveLockerVaultDrive' {
    It 'picks the drive with the most free space' {
        $volumes = @(
            [pscustomobject]@{ DriveLetter = 'C'; FileSystem = 'NTFS'; SizeRemaining = 50GB;   DriveType = 'Fixed' }
            [pscustomobject]@{ DriveLetter = 'D'; FileSystem = 'NTFS'; SizeRemaining = 1000GB; DriveType = 'Fixed' }
        )
        Select-BraveLockerVaultDrive -Volume $volumes | Should -Be 'D'
    }

    It 'skips FAT volumes, which cannot hold a file over 4 GB' {
        $volumes = @(
            [pscustomobject]@{ DriveLetter = 'E'; FileSystem = 'exFAT'; SizeRemaining = 900GB; DriveType = 'Fixed' }
            [pscustomobject]@{ DriveLetter = 'C'; FileSystem = 'NTFS';  SizeRemaining = 60GB;  DriveType = 'Fixed' }
        )
        Select-BraveLockerVaultDrive -Volume $volumes | Should -Be 'C'
    }

    It 'skips drives without enough room' {
        $volumes = @(
            [pscustomobject]@{ DriveLetter = 'C'; FileSystem = 'NTFS'; SizeRemaining = 1GB; DriveType = 'Fixed' }
        )
        Select-BraveLockerVaultDrive -Volume $volumes -RequiredBytes 5GB | Should -Be ''
    }

    It 'skips letterless volumes' {
        $volumes = @(
            [pscustomobject]@{ DriveLetter = "`0"; FileSystem = 'NTFS'; SizeRemaining = 900GB; DriveType = 'Fixed' }
        )
        Select-BraveLockerVaultDrive -Volume $volumes | Should -Be ''
    }

    It 'returns empty rather than throwing when there are no volumes at all' {
        Select-BraveLockerVaultDrive -Volume @() | Should -Be ''
    }
}

Describe 'Get-BraveLockerDefaultVaultPath' {
    It 'builds a path on the chosen drive' {
        Get-BraveLockerDefaultVaultPath -DriveLetter 'D' | Should -Be 'D:\BraveLocker\vault.vhdx'
    }

    It 'tolerates a letter given with a colon' {
        Get-BraveLockerDefaultVaultPath -DriveLetter 'E:' | Should -Be 'E:\BraveLocker\vault.vhdx'
    }
}

Describe 'Test-BraveLockerRequirement' {
    It 'blocks setup on Windows Home and says why' {
        $r = Test-BraveLockerRequirement `
            -CryptoStatus ([pscustomobject]@{ IsAvailable = $false; Reason = 'HomeEdition'; Detail = 'BitLocker is not available on Microsoft Windows 11 Home.' }) `
            -IsElevated $true -BraveExe 'C:\brave.exe' -ProfilePath 'C:\nope' `
            -AlreadyInstalled $false -BraveProcessCount 0 -VaultDriveLetter 'D'
        $r.CanProceed | Should -BeFalse
        ($r.Checks | Where-Object { $_.Name -eq 'Disk encryption' }).Detail | Should -Match 'Home'
    }

    It 'blocks setup when not elevated' {
        $r = Test-BraveLockerRequirement `
            -CryptoStatus ([pscustomobject]@{ IsAvailable = $true; Reason = 'OK'; Detail = 'ok' }) `
            -IsElevated $false -BraveExe 'C:\brave.exe' -ProfilePath 'C:\nope' `
            -AlreadyInstalled $false -BraveProcessCount 0 -VaultDriveLetter 'D'
        $r.CanProceed | Should -BeFalse
    }

    It 'blocks setup while Brave is running' {
        $r = Test-BraveLockerRequirement `
            -CryptoStatus ([pscustomobject]@{ IsAvailable = $true; Reason = 'OK'; Detail = 'ok' }) `
            -IsElevated $true -BraveExe 'C:\brave.exe' -ProfilePath 'C:\nope' `
            -AlreadyInstalled $false -BraveProcessCount 22 -VaultDriveLetter 'D'
        ($r.Checks | Where-Object { $_.Name -eq 'Brave closed' }).IsOk | Should -BeFalse
        $r.CanProceed | Should -BeFalse
    }

    It 'reports every failure at once, not just the first' {
        # The wizard shows the whole list, so someone on Home without Brave
        # installed learns both things in one go instead of one per attempt.
        $r = Test-BraveLockerRequirement `
            -CryptoStatus ([pscustomobject]@{ IsAvailable = $false; Reason = 'HomeEdition'; Detail = 'no bitlocker' }) `
            -IsElevated $false -BraveExe '' -ProfilePath 'C:\nope' `
            -AlreadyInstalled $false -BraveProcessCount 5 -VaultDriveLetter ''
        @($r.Checks | Where-Object { -not $_.IsOk }).Count | Should -BeGreaterThan 3
    }

    It 'passes when everything is in order' {
        $work = Join-Path $TestDrive (New-Guid).Guid
        New-Item -ItemType Directory -Path $work | Out-Null
        Set-Content -Path (Join-Path $work 'Local State') -Value '{}' -Encoding utf8
        New-Item -ItemType Directory -Path (Join-Path $work 'Profile 3') | Out-Null

        $r = Test-BraveLockerRequirement `
            -CryptoStatus ([pscustomobject]@{ IsAvailable = $true; Reason = 'OK'; Detail = 'ok' }) `
            -IsElevated $true -BraveExe 'C:\brave.exe' -ProfilePath $work `
            -AlreadyInstalled $false -BraveProcessCount 0 -VaultDriveLetter 'D'
        $r.CanProceed | Should -BeTrue
    }
}

Describe 'Test-BraveLockerRequirement: existing installation' {
    It 'blocks a second setup over an existing install' {
        # Running setup again would create a second vault and rename an
        # already-vaulted profile aside - the fastest way to destroy data with
        # a tool meant to protect it.
        $r = Test-BraveLockerRequirement `
            -CryptoStatus ([pscustomobject]@{ IsAvailable = $true; Reason = 'OK'; Detail = 'ok' }) `
            -IsElevated $true -BraveExe 'C:\brave.exe' -ProfilePath 'C:\nope' `
            -AlreadyInstalled $true -BraveProcessCount 0 -VaultDriveLetter 'D'
        $r.CanProceed | Should -BeFalse
        ($r.Checks | Where-Object { $_.Name -eq 'Not already set up' }).IsOk | Should -BeFalse
    }

    It 'points at the scripts that handle an existing install' {
        $r = Test-BraveLockerRequirement `
            -CryptoStatus ([pscustomobject]@{ IsAvailable = $true; Reason = 'OK'; Detail = 'ok' }) `
            -IsElevated $true -BraveExe 'C:\brave.exe' -ProfilePath 'C:\nope' `
            -AlreadyInstalled $true -BraveProcessCount 0 -VaultDriveLetter 'D'
        ($r.Checks | Where-Object { $_.Name -eq 'Not already set up' }).Detail |
            Should -Match 'Reset-BraveLocker|Uninstall-BraveLocker'
    }
}
