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
