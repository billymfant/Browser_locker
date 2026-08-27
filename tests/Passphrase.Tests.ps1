BeforeAll {
    Import-Module "$PSScriptRoot\..\src\BraveLocker\BraveLocker.psd1" -Force
}

Describe 'Test-BraveLockerPassphrase' {
    It 'rejects a passphrase shorter than 16 characters' {
        $r = Test-BraveLockerPassphrase -Passphrase 'short-one-123'
        $r.IsValid | Should -BeFalse
        $r.Reason  | Should -Be 'TooShort'
    }

    It 'accepts exactly 16 characters' {
        $r = Test-BraveLockerPassphrase -Passphrase '1234567890123456'
        $r.IsValid | Should -BeTrue
        $r.Reason  | Should -Be 'OK'
    }

    It 'accepts a long multi-word passphrase' {
        $r = Test-BraveLockerPassphrase -Passphrase 'correct horse battery staple'
        $r.IsValid | Should -BeTrue
    }

    It 'rejects whitespace padding used to reach the minimum' {
        $r = Test-BraveLockerPassphrase -Passphrase 'abc                     '
        $r.IsValid | Should -BeFalse
        $r.Reason  | Should -Be 'Whitespace'
    }

    It 'rejects an empty passphrase' {
        (Test-BraveLockerPassphrase -Passphrase '').IsValid | Should -BeFalse
    }
}
