BeforeAll {
    Import-Module "$PSScriptRoot\..\src\BraveLocker\BraveLocker.psd1" -Force
}

Describe 'Test-BraveLockerPassphrase' {
    It 'rejects a passphrase shorter than 8 characters' {
        $r = Test-BraveLockerPassphrase -Passphrase 'short12'
        $r.IsValid | Should -BeFalse
        $r.Reason  | Should -Be 'TooShort'
    }

    It 'rejects a 4-character passphrase' {
        (Test-BraveLockerPassphrase -Passphrase 'abcd').IsValid | Should -BeFalse
    }

    It 'accepts exactly 8 characters' {
        $r = Test-BraveLockerPassphrase -Passphrase 'abcd1234'
        $r.IsValid | Should -BeTrue
        $r.Reason  | Should -Be 'OK'
    }

    It 'flags 8 to 11 characters as weak but still usable' {
        $r = Test-BraveLockerPassphrase -Passphrase 'abcd1234'
        $r.IsValid | Should -BeTrue
        $r.IsWeak  | Should -BeTrue
    }

    It 'does not flag 12 or more characters as weak' {
        $r = Test-BraveLockerPassphrase -Passphrase 'abcd1234efgh'
        $r.IsValid | Should -BeTrue
        $r.IsWeak  | Should -BeFalse
    }

    It 'accepts a long multi-word passphrase' {
        $r = Test-BraveLockerPassphrase -Passphrase 'correct horse battery staple'
        $r.IsValid | Should -BeTrue
        $r.IsWeak  | Should -BeFalse
    }

    It 'rejects whitespace padding used to reach the minimum' {
        $r = Test-BraveLockerPassphrase -Passphrase 'abc          '
        $r.IsValid | Should -BeFalse
        $r.Reason  | Should -Be 'Whitespace'
    }

    It 'rejects an empty passphrase' {
        (Test-BraveLockerPassphrase -Passphrase '').IsValid | Should -BeFalse
    }
}
