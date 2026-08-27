BeforeAll {
    Import-Module "$PSScriptRoot\..\src\BraveLocker\BraveLocker.psd1" -Force
}

Describe 'Test-BraveLockerCommandLineMatch' {
    It 'matches an unquoted user-data-dir' {
        Test-BraveLockerCommandLineMatch -ProfilePath 'V:\BraveProfile' `
            -CommandLine '"C:\brave.exe" --user-data-dir=V:\BraveProfile' | Should -BeTrue
    }

    It 'matches a quoted user-data-dir among other switches' {
        Test-BraveLockerCommandLineMatch -ProfilePath 'V:\BraveProfile' `
            -CommandLine '"C:\brave.exe" --user-data-dir="V:\BraveProfile" --type=renderer' | Should -BeTrue
    }

    It 'matches regardless of a trailing backslash' {
        Test-BraveLockerCommandLineMatch -ProfilePath 'V:\BraveProfile' `
            -CommandLine '"C:\brave.exe" --user-data-dir=V:\BraveProfile\' | Should -BeTrue
    }

    It 'is case-insensitive' {
        Test-BraveLockerCommandLineMatch -ProfilePath 'V:\BraveProfile' `
            -CommandLine '"C:\brave.exe" --user-data-dir=v:\braveprofile' | Should -BeTrue
    }

    It 'does NOT match the ordinary work Brave' {
        Test-BraveLockerCommandLineMatch -ProfilePath 'V:\BraveProfile' `
            -CommandLine '"C:\brave.exe"' | Should -BeFalse
    }

    It 'does NOT match a different profile directory' {
        Test-BraveLockerCommandLineMatch -ProfilePath 'V:\BraveProfile' `
            -CommandLine '"C:\brave.exe" --user-data-dir=V:\OtherProfile' | Should -BeFalse
    }

    It 'does NOT match a profile path that is merely a prefix' {
        Test-BraveLockerCommandLineMatch -ProfilePath 'V:\BraveProfile' `
            -CommandLine '"C:\brave.exe" --user-data-dir=V:\BraveProfileBackup' | Should -BeFalse
    }

    It 'handles an empty command line without throwing' {
        Test-BraveLockerCommandLineMatch -CommandLine '' -ProfilePath 'V:\BraveProfile' | Should -BeFalse
    }
}
