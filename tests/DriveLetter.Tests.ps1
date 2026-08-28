BeforeAll {
    Import-Module "$PSScriptRoot\..\src\BraveLocker\BraveLocker.psd1" -Force
}

Describe 'Get-BraveLockerFreeDriveLetter' {
    It 'returns the preferred letter when it is free' {
        Get-BraveLockerFreeDriveLetter -Preferred 'V' -UsedLetters @('C', 'D') | Should -Be 'V'
    }

    It 'falls back to the highest free letter when the preferred one is taken' {
        Get-BraveLockerFreeDriveLetter -Preferred 'V' -UsedLetters @('C', 'D', 'V', 'Z', 'Y') | Should -Be 'X'
    }

    It 'is case-insensitive about used letters' {
        Get-BraveLockerFreeDriveLetter -Preferred 'v' -UsedLetters @('c', 'v') | Should -Be 'Z'
    }

    It 'throws when every letter from E to Z is taken' {
        $used = 69..90 | ForEach-Object { [string][char]$_ }
        { Get-BraveLockerFreeDriveLetter -Preferred 'V' -UsedLetters $used } |
            Should -Throw -ExpectedMessage '*no free drive letter*'
    }
}
