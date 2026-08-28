BeforeAll {
    Import-Module "$PSScriptRoot\..\src\BraveLocker\BraveLocker.psd1" -Force
}

Describe 'Test-BraveLockerMountFolderReady' {
    BeforeEach {
        $script:work = Join-Path $TestDrive (New-Guid).Guid
        New-Item -ItemType Directory -Path $script:work | Out-Null
        $script:folder = Join-Path $script:work 'User Data'
    }

    It 'treats a folder that does not exist yet as ready - the caller creates it' {
        $state = Test-BraveLockerMountFolderReady -Path $script:folder
        $state.IsReady | Should -BeTrue
        $state.Reason  | Should -Be 'Missing'
    }

    It 'is ready when the folder exists and is empty' {
        New-Item -ItemType Directory -Path $script:folder | Out-Null
        $state = Test-BraveLockerMountFolderReady -Path $script:folder
        $state.IsReady | Should -BeTrue
        $state.Reason  | Should -Be 'Empty'
    }

    It 'is NOT ready when a stray profile is sitting in it' {
        New-Item -ItemType Directory -Path $script:folder | Out-Null
        Set-Content -Path (Join-Path $script:folder 'Local State') -Value '{}' -Encoding utf8
        $state = Test-BraveLockerMountFolderReady -Path $script:folder
        $state.IsReady   | Should -BeFalse
        $state.Reason    | Should -Be 'NotEmpty'
        $state.ItemCount | Should -Be 1
    }

    It 'counts hidden entries too, since Windows still refuses to mount over them' {
        New-Item -ItemType Directory -Path $script:folder | Out-Null
        $hidden = Join-Path $script:folder '.hidden'
        Set-Content -Path $hidden -Value 'x' -Encoding utf8
        (Get-Item $hidden -Force).Attributes = 'Hidden'
        (Test-BraveLockerMountFolderReady -Path $script:folder).Reason | Should -Be 'NotEmpty'
    }
}

Describe 'Move-BraveLockerStrayProfile' {
    BeforeEach {
        $script:work = Join-Path $TestDrive (New-Guid).Guid
        New-Item -ItemType Directory -Path $script:work | Out-Null
        $script:folder = Join-Path $script:work 'User Data'
        $script:quarantine = Join-Path $script:work 'state'
        New-Item -ItemType Directory -Path $script:folder | Out-Null
    }

    It 'moves a stray profile out of the way and reports where it went' {
        Set-Content -Path (Join-Path $script:folder 'Local State') -Value '{}' -Encoding utf8
        New-Item -ItemType Directory -Path (Join-Path $script:folder 'Default') | Out-Null

        $result = Move-BraveLockerStrayProfile -Path $script:folder -QuarantineRoot $script:quarantine

        $result.MovedCount | Should -Be 2
        Test-Path $result.Destination | Should -BeTrue
        @(Get-ChildItem $script:folder -Force).Count | Should -Be 0
    }

    It 'never deletes - the stray profile survives intact in quarantine' {
        # A stray profile is a real profile someone browsed in. Deleting it to
        # make a mount succeed would be destroying data to tidy up.
        Set-Content -Path (Join-Path $script:folder 'Local State') -Value 'irreplaceable' -Encoding utf8

        $result = Move-BraveLockerStrayProfile -Path $script:folder -QuarantineRoot $script:quarantine

        Get-Content (Join-Path $result.Destination 'Local State') -Raw |
            Should -Match 'irreplaceable'
    }

    It 'does nothing to an already empty folder' {
        $result = Move-BraveLockerStrayProfile -Path $script:folder -QuarantineRoot $script:quarantine
        $result.MovedCount  | Should -Be 0
        $result.Destination | Should -BeNullOrEmpty
    }

    It 'gives each quarantine a distinct timestamped name' {
        $a = New-BraveLockerQuarantinePath -QuarantineRoot 'C:\state' -Now ([datetime]'2026-08-28T10:00:00')
        $b = New-BraveLockerQuarantinePath -QuarantineRoot 'C:\state' -Now ([datetime]'2026-08-28T11:30:15')
        $a | Should -Not -Be $b
        $a | Should -Match 'stray-profile-20260828-100000$'
    }
}

Describe 'Initialize-BraveLockerMountFolder' {
    BeforeEach {
        $script:work = Join-Path $TestDrive (New-Guid).Guid
        New-Item -ItemType Directory -Path $script:work | Out-Null
        $script:folder = Join-Path $script:work 'User Data'
        $script:quarantine = Join-Path $script:work 'state'
    }

    It 'creates the folder when it is missing' {
        $r = Initialize-BraveLockerMountFolder -Path $script:folder -QuarantineRoot $script:quarantine
        $r.IsReady | Should -BeTrue
        $r.Action  | Should -Be 'Created'
        Test-Path $script:folder | Should -BeTrue
    }

    It 'leaves an already empty folder alone' {
        New-Item -ItemType Directory -Path $script:folder | Out-Null
        $r = Initialize-BraveLockerMountFolder -Path $script:folder -QuarantineRoot $script:quarantine
        $r.IsReady | Should -BeTrue
        $r.Action  | Should -Be 'AlreadyEmpty'
    }

    It 'clears a stray profile so the mount can proceed' {
        New-Item -ItemType Directory -Path $script:folder | Out-Null
        Set-Content -Path (Join-Path $script:folder 'Local State') -Value '{}' -Encoding utf8

        $r = Initialize-BraveLockerMountFolder -Path $script:folder -QuarantineRoot $script:quarantine

        $r.IsReady    | Should -BeTrue
        $r.Action     | Should -Be 'QuarantinedStrayProfile'
        $r.MovedCount | Should -Be 1
        @(Get-ChildItem $script:folder -Force).Count | Should -Be 0
    }
}
