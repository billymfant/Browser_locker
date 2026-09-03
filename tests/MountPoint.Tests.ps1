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

Describe 'Test-BraveLockerStaleMountPoint' {
    # A session that ends without a dismount leaves the mount point behind
    # pointing at a volume that is gone. Nothing in the normal dismount path can
    # clear it afterwards - Remove-PartitionAccessPath works through the
    # partition, and there is no partition once the vault is detached - so the
    # launcher has to recognise it rather than treat it as a live mount.
    It 'is false for an ordinary folder' {
        Mock -ModuleName BraveLocker Get-Item { [pscustomobject]@{ Attributes = [System.IO.FileAttributes]::Directory } }
        Test-BraveLockerStaleMountPoint -Path 'C:\User Data' | Should -BeFalse
    }

    It 'is false for a folder that is not there at all' {
        Mock -ModuleName BraveLocker Get-Item { }
        Test-BraveLockerStaleMountPoint -Path 'C:\User Data' | Should -BeFalse
    }

    It 'is false for a LIVE mount point, which can still be read through' {
        # The safety-critical case. Calling a live mount stale would have the
        # launcher delete the mount point of an open vault.
        Mock -ModuleName BraveLocker Get-Item {
            [pscustomobject]@{ Attributes = [System.IO.FileAttributes]::Directory -bor [System.IO.FileAttributes]::ReparsePoint }
        }
        Mock -ModuleName BraveLocker Get-ChildItem { [pscustomobject]@{ Name = 'Local State' } }
        Test-BraveLockerStaleMountPoint -Path 'C:\User Data' | Should -BeFalse
    }

    It 'is true for a mount point whose volume has gone' {
        Mock -ModuleName BraveLocker Get-Item {
            [pscustomobject]@{ Attributes = [System.IO.FileAttributes]::Directory -bor [System.IO.FileAttributes]::ReparsePoint }
        }
        Mock -ModuleName BraveLocker Get-ChildItem { throw 'Could not find a part of the path.' }
        Test-BraveLockerStaleMountPoint -Path 'C:\User Data' | Should -BeTrue
    }
}

Describe 'Test-BraveLockerMountFolderReady tells a stale mount point from a live one' {
    BeforeEach {
        Mock -ModuleName BraveLocker Test-Path { $true }
        Mock -ModuleName BraveLocker Get-Item {
            [pscustomobject]@{ Attributes = [System.IO.FileAttributes]::Directory -bor [System.IO.FileAttributes]::ReparsePoint }
        }
    }

    It 'reports IsMountPoint while the vault is genuinely mounted' {
        Mock -ModuleName BraveLocker Get-ChildItem { [pscustomobject]@{ Name = 'Local State' } }
        (Test-BraveLockerMountFolderReady -Path 'C:\User Data').Reason | Should -Be 'IsMountPoint'
    }

    It 'reports StaleMountPoint when nothing can be read through it' {
        Mock -ModuleName BraveLocker Get-ChildItem { throw 'Could not find a part of the path.' }
        (Test-BraveLockerMountFolderReady -Path 'C:\User Data').Reason | Should -Be 'StaleMountPoint'
    }
}

Describe 'Initialize-BraveLockerMountFolder and a stale mount point' {
    It 'clears it and becomes ready, instead of dead-ending the launcher' {
        # This is the bug that bricked a real install: a stale mount point came
        # back as "something is already mounted, restart the PC" - advice that
        # could never work, because no restart removes a mount point nothing
        # owns any more. The launcher stopped there, before the passphrase
        # prompt, every single time.
        #
        # The folder is judged twice: stale, then plain and empty once cleared.
        $script:readyCalls = 0
        Mock -ModuleName BraveLocker Test-BraveLockerMountFolderReady {
            $script:readyCalls++
            if ($script:readyCalls -eq 1) {
                [pscustomobject]@{ IsReady = $false; Reason = 'StaleMountPoint'; ItemCount = 0 }
            } else {
                [pscustomobject]@{ IsReady = $true; Reason = 'Empty'; ItemCount = 0 }
            }
        }
        Mock -ModuleName BraveLocker Clear-BraveLockerStaleMountPoint {
            [pscustomobject]@{ Cleared = $true; Error = '' }
        }

        $r = Initialize-BraveLockerMountFolder -Path 'C:\User Data' -QuarantineRoot 'C:\state'

        Should -Invoke -ModuleName BraveLocker Clear-BraveLockerStaleMountPoint -Times 1
        $r.IsReady                | Should -BeTrue
        $r.ClearedStaleMountPoint | Should -BeTrue
        $r.Action                 | Should -Be 'AlreadyEmpty'
    }

    It 'still quarantines a stray profile the stale mount point was hiding' {
        # Clearing the link can uncover a profile that was underneath it all
        # along. The user has to be told where that went, so the stray profile
        # keeps the Action and the clearing is reported alongside it.
        $script:readyCalls = 0
        Mock -ModuleName BraveLocker Test-BraveLockerMountFolderReady {
            $script:readyCalls++
            if ($script:readyCalls -eq 1) {
                [pscustomobject]@{ IsReady = $false; Reason = 'StaleMountPoint'; ItemCount = 0 }
            } else {
                [pscustomobject]@{ IsReady = $false; Reason = 'NotEmpty'; ItemCount = 3 }
            }
        }
        Mock -ModuleName BraveLocker Clear-BraveLockerStaleMountPoint {
            [pscustomobject]@{ Cleared = $true; Error = '' }
        }
        Mock -ModuleName BraveLocker Move-BraveLockerStrayProfile {
            [pscustomobject]@{ MovedCount = 3; Destination = 'C:\state\stray-profile-1' }
        }

        $r = Initialize-BraveLockerMountFolder -Path 'C:\User Data' -QuarantineRoot 'C:\state'

        $r.IsReady                | Should -BeTrue
        $r.Action                 | Should -Be 'QuarantinedStrayProfile'
        $r.MovedCount             | Should -Be 3
        $r.ClearedStaleMountPoint | Should -BeTrue
    }

    It 'reports StaleMountPointStuck rather than claiming to be ready when it cannot clear it' {
        # mountvol needs administrator rights, so the unelevated launcher can
        # fail here. It must say so - and say that a restart will not help -
        # rather than carrying on into a mount that cannot succeed.
        Mock -ModuleName BraveLocker Test-BraveLockerMountFolderReady {
            [pscustomobject]@{ IsReady = $false; Reason = 'StaleMountPoint'; ItemCount = 0 }
        }
        Mock -ModuleName BraveLocker Clear-BraveLockerStaleMountPoint {
            [pscustomobject]@{ Cleared = $false; Error = 'Access is denied.' }
        }

        $r = Initialize-BraveLockerMountFolder -Path 'C:\User Data' -QuarantineRoot 'C:\state'

        $r.IsReady | Should -BeFalse
        $r.Action  | Should -Be 'StaleMountPointStuck'
        $r.Error   | Should -Match 'Access is denied'
    }

    It 'never clears a LIVE mount point' {
        Mock -ModuleName BraveLocker Test-BraveLockerMountFolderReady {
            [pscustomobject]@{ IsReady = $false; Reason = 'IsMountPoint'; ItemCount = 0 }
        }
        Mock -ModuleName BraveLocker Clear-BraveLockerStaleMountPoint { }

        $r = Initialize-BraveLockerMountFolder -Path 'C:\User Data' -QuarantineRoot 'C:\state'

        Should -Invoke -ModuleName BraveLocker Clear-BraveLockerStaleMountPoint -Times 0
        $r.Action | Should -Be 'AlreadyMounted'
    }
}
