BeforeAll {
    Import-Module "$PSScriptRoot\..\src\BraveLocker\BraveLocker.psd1" -Force
}

Describe 'New-BraveLockerDiskpartScript' {
    BeforeEach {
        $script:s = New-BraveLockerDiskpartScript -VhdxPath 'D:\apps\brave_locker\vault.vhdx' `
            -MaximumSizeMB 32768 -DriveLetter 'V'
    }

    It 'creates an expandable vdisk of the requested size' {
        $script:s | Should -Match 'create vdisk file="D:\\apps\\brave_locker\\vault\.vhdx" maximum=32768 type=expandable'
    }

    It 'attaches, partitions, formats NTFS and assigns the letter, in that order' {
        $lines = $script:s -split "`r?`n" | Where-Object { $_ -ne '' }
        ($lines -join '|') | Should -Match 'attach vdisk.*create partition primary.*format fs=ntfs quick.*assign letter=V'
    }

    It 'labels the volume so it is recognisable in Explorer' {
        $script:s | Should -Match 'label="BraveVault"'
    }

    It 'quotes the path so spaces cannot break the script' {
        $s2 = New-BraveLockerDiskpartScript -VhdxPath 'D:\my apps\vault.vhdx' -MaximumSizeMB 2048 -DriveLetter 'X'
        $s2 | Should -Match 'file="D:\\my apps\\vault\.vhdx"'
    }

    It 'rejects a size below 1024 MB' {
        { New-BraveLockerDiskpartScript -VhdxPath 'D:\v.vhdx' -MaximumSizeMB 10 -DriveLetter 'V' } |
            Should -Throw -ExpectedMessage '*at least 1024*'
    }
}

Describe 'Get-BraveLockerPreferredAccessPath' {
    It 'prefers a folder mount point over a drive letter' {
        # A drive letter puts the vault in Explorer for anyone to notice.
        Get-BraveLockerPreferredAccessPath -AccessPaths @('V:\', 'C:\ProgramData\BraveLocker\data\') |
            Should -Be 'C:\ProgramData\BraveLocker\data'
    }

    It 'falls back to the drive letter when there is no folder' {
        Get-BraveLockerPreferredAccessPath -AccessPaths @('V:\') | Should -Be 'V:'
    }

    It 'never returns a volume GUID path' {
        Get-BraveLockerPreferredAccessPath -AccessPaths @('\\?\Volume{1234-5678}\', 'V:\') | Should -Be 'V:'
    }

    It 'returns empty when there is nowhere to mount' {
        Get-BraveLockerPreferredAccessPath -AccessPaths @('\\?\Volume{1234-5678}\') | Should -Be ''
    }

    It 'returns empty for an empty list' {
        Get-BraveLockerPreferredAccessPath -AccessPaths @() | Should -Be ''
    }

    It 'ignores blank entries' {
        Get-BraveLockerPreferredAccessPath -AccessPaths @('', 'V:\') | Should -Be 'V:'
    }
}

Describe 'Get-BraveLockerPartitionDriveLetter' {
    It 'returns the letter when the partition has one' {
        $p = [pscustomobject]@{ DriveLetter = 'V' }
        Get-BraveLockerPartitionDriveLetter -Partition $p | Should -Be 'V'
    }

    It 'uppercases it' {
        $p = [pscustomobject]@{ DriveLetter = 'v' }
        Get-BraveLockerPartitionDriveLetter -Partition $p | Should -Be 'V'
    }

    It 'returns empty for the NUL character Windows uses to mean "no letter"' {
        # Get-Partition reports a letterless partition as NUL, not null or ''.
        # Read naively that looks like a real one-character drive letter, and
        # the vault then gets unlocked against a path like ":".
        $p = [pscustomobject]@{ DriveLetter = "`0" }
        Get-BraveLockerPartitionDriveLetter -Partition $p | Should -Be ''
    }

    It 'returns empty for a genuinely empty letter' {
        $p = [pscustomobject]@{ DriveLetter = '' }
        Get-BraveLockerPartitionDriveLetter -Partition $p | Should -Be ''
    }

    It 'returns empty for a null partition rather than throwing' {
        Get-BraveLockerPartitionDriveLetter -Partition $null | Should -Be ''
    }

    It 'returns empty when the object has no DriveLetter property at all' {
        Get-BraveLockerPartitionDriveLetter -Partition ([pscustomobject]@{ Type = 'Basic' }) | Should -Be ''
    }
}

Describe 'Get-BraveLockerVaultPartition when the vault is not attached' {
    # A detached disk image reports Number as null, and Get-Disk refuses a null
    # -Number by binding failure rather than by returning nothing. Under the
    # elevated task's $ErrorActionPreference = 'Stop' that binding failure
    # became "Cannot validate argument on parameter 'Number'" - which was
    # written over the real unlock result and destroyed the evidence of why a
    # launch had failed.
    It 'returns nothing instead of throwing' {
        Mock -ModuleName BraveLocker Get-DiskImage {
            [pscustomobject]@{ ImagePath = 'D:\v.vhdx'; Attached = $false; Number = $null }
        }
        # Not just "does not throw": it must raise no error at all. The elevated
        # task runs with $ErrorActionPreference = 'Stop', where the error this
        # raised became a thrown one - and its message was then written over the
        # real unlock result in response.json.
        $before = $Error.Count
        $result = Get-BraveLockerVaultPartition -VhdxPath 'D:\v.vhdx'
        ($Error.Count - $before) | Should -Be 0 -Because 'a detached vault is an ordinary state, not an error'
        $result | Should -BeNullOrEmpty
    }

    It 'never reaches Get-Disk with a null disk number' {
        Mock -ModuleName BraveLocker Get-DiskImage {
            [pscustomobject]@{ ImagePath = 'D:\v.vhdx'; Attached = $false; Number = $null }
        }
        Mock -ModuleName BraveLocker Get-Disk { }
        $before = $Error.Count
        Get-BraveLockerVaultPartition -VhdxPath 'D:\v.vhdx' | Out-Null
        # Get-Disk validates -Number and rejects null at binding time, so even
        # reaching it with a detached image costs an error record.
        ($Error.Count - $before) | Should -Be 0
        Should -Invoke -ModuleName BraveLocker Get-Disk -Times 0
    }
}

Describe 'Test-BraveLockerWrongKeyError' {
    # BitLocker reports a genuinely wrong passphrase as HRESULT 0x80310027.
    # Everything else - a missing volume, an already-unlocked volume, a service
    # that is not running - is a different problem and must not be reported to
    # the user as "incorrect passphrase".
    It 'recognises the wrong-key HRESULT' {
        Test-BraveLockerWrongKeyError -Message 'The drive cannot be unlocked with the key provided. Confirm that you have provided the correct key and try again. (Exception from HRESULT: 0x80310027)' |
            Should -BeTrue
    }

    It 'recognises the wrong-key wording without the HRESULT' {
        Test-BraveLockerWrongKeyError -Message 'The drive cannot be unlocked with the key provided.' | Should -BeTrue
    }

    It 'does not treat a missing volume as a wrong passphrase' {
        Test-BraveLockerWrongKeyError -Message 'The system cannot find the drive specified.' | Should -BeFalse
    }

    It 'does not treat an already-unlocked volume as a wrong passphrase' {
        Test-BraveLockerWrongKeyError -Message 'The volume is not locked. (Exception from HRESULT: 0x80310001)' |
            Should -BeFalse
    }

    It 'handles an empty message' {
        Test-BraveLockerWrongKeyError -Message '' | Should -BeFalse
    }
}

Describe 'Invoke-BraveLockerUnlockAttempt' {
    It 'reports Unlocked when BitLocker accepts the passphrase' {
        Mock -ModuleName BraveLocker Unlock-BitLocker { }
        $r = Invoke-BraveLockerUnlockAttempt -MountPoint 'V' -Passphrase (ConvertTo-BraveLockerSecureString -Text 'passphrase')
        $r.Unlocked | Should -BeTrue
        $r.Reason   | Should -Be 'Unlocked'
        $r.Error    | Should -Be ''
    }

    It 'reports WrongPassphrase only for the wrong-key HRESULT' {
        Mock -ModuleName BraveLocker Unlock-BitLocker {
            throw 'The drive cannot be unlocked with the key provided. (Exception from HRESULT: 0x80310027)'
        }
        $r = Invoke-BraveLockerUnlockAttempt -MountPoint 'V' -Passphrase (ConvertTo-BraveLockerSecureString -Text 'passphrase')
        $r.Unlocked | Should -BeFalse
        $r.Reason   | Should -Be 'WrongPassphrase'
    }

    It 'keeps the real error for any other failure, rather than blaming the passphrase' {
        Mock -ModuleName BraveLocker Unlock-BitLocker { throw 'The system cannot find the drive specified.' }
        $r = Invoke-BraveLockerUnlockAttempt -MountPoint 'V' -Passphrase (ConvertTo-BraveLockerSecureString -Text 'passphrase')
        $r.Unlocked | Should -BeFalse
        $r.Reason   | Should -Be 'UnlockFailed'
        $r.Error    | Should -Match 'cannot find the drive'
    }

    It 'normalises a bare drive letter to a mount point' {
        Mock -ModuleName BraveLocker Unlock-BitLocker { }
        $r = Invoke-BraveLockerUnlockAttempt -MountPoint 'v' -Passphrase (ConvertTo-BraveLockerSecureString -Text 'passphrase')
        $r.MountPoint | Should -Be 'V:'
    }

    It 'leaves a folder mount point alone apart from a trailing slash' {
        Mock -ModuleName BraveLocker Unlock-BitLocker { }
        $r = Invoke-BraveLockerUnlockAttempt -MountPoint 'C:\Users\U\AppData\Local\X\User Data\' `
            -Passphrase (ConvertTo-BraveLockerSecureString -Text 'passphrase')
        $r.MountPoint | Should -Be 'C:\Users\U\AppData\Local\X\User Data'
    }
}

Describe 'Unlock-BraveLockerVault still answers yes or no' {
    It 'returns $true when the unlock succeeds' {
        Mock -ModuleName BraveLocker Unlock-BitLocker { }
        Unlock-BraveLockerVault -MountPoint 'V' -Passphrase (ConvertTo-BraveLockerSecureString -Text 'p') | Should -BeTrue
    }

    It 'returns $false when the unlock fails' {
        Mock -ModuleName BraveLocker Unlock-BitLocker { throw 'The drive cannot be unlocked with the key provided.' }
        Unlock-BraveLockerVault -MountPoint 'V' -Passphrase (ConvertTo-BraveLockerSecureString -Text 'p') | Should -BeFalse
    }
}
