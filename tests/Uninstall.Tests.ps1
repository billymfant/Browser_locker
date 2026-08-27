BeforeAll {
    Import-Module "$PSScriptRoot\..\src\BraveLocker\BraveLocker.psd1" -Force
}

Describe 'Test-BraveLockerSafeToRemoveVault' {
    BeforeEach {
        $script:profileDir = Join-Path $TestDrive (New-Guid).Guid
    }

    It 'is safe when the original profile is present and populated' {
        New-Item -ItemType Directory -Path $script:profileDir | Out-Null
        1..150 | ForEach-Object {
            Set-Content -Path (Join-Path $script:profileDir "f$_.txt") -Value 'x'
        }

        $r = Test-BraveLockerSafeToRemoveVault -SourceProfilePath $script:profileDir
        $r.IsSafe | Should -BeTrue
        $r.Reason | Should -Be 'OriginalProfilePresent'
    }

    It 'is NOT safe when the original profile is gone - the vault is the only copy' {
        $r = Test-BraveLockerSafeToRemoveVault -SourceProfilePath $script:profileDir
        $r.IsSafe | Should -BeFalse
        $r.Reason | Should -Be 'OriginalProfileMissing'
    }

    It 'is NOT safe when the original profile exists but is nearly empty' {
        New-Item -ItemType Directory -Path $script:profileDir | Out-Null
        Set-Content -Path (Join-Path $script:profileDir 'lonely.txt') -Value 'x'

        $r = Test-BraveLockerSafeToRemoveVault -SourceProfilePath $script:profileDir
        $r.IsSafe | Should -BeFalse
        $r.Reason | Should -Be 'OriginalProfileEmpty'
    }

    It 'reports the file count it based the decision on' {
        New-Item -ItemType Directory -Path $script:profileDir | Out-Null
        1..120 | ForEach-Object {
            Set-Content -Path (Join-Path $script:profileDir "f$_.txt") -Value 'x'
        }

        (Test-BraveLockerSafeToRemoveVault -SourceProfilePath $script:profileDir).FileCount | Should -Be 120
    }
}
