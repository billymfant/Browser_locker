BeforeAll {
    Import-Module "$PSScriptRoot\..\src\BraveLocker\BraveLocker.psd1" -Force

    function Get-PlainText {
        param([securestring]$Secure)
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
        try { [Runtime.InteropServices.Marshal]::PtrToStringUni($bstr) }
        finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    }
}

Describe 'ConvertTo-BraveLockerSecureString' {
    It 'produces a SecureString' {
        ConvertTo-BraveLockerSecureString -Text 'hello world' | Should -BeOfType [securestring]
    }

    It 'round-trips the exact text' {
        $s = ConvertTo-BraveLockerSecureString -Text 'correct horse battery'
        Get-PlainText -Secure $s | Should -Be 'correct horse battery'
    }

    It 'preserves spaces and punctuation' {
        $s = ConvertTo-BraveLockerSecureString -Text 'a b!c#d $e'
        Get-PlainText -Secure $s | Should -Be 'a b!c#d $e'
    }

    It 'handles an empty string without throwing' {
        $s = ConvertTo-BraveLockerSecureString -Text ''
        $s.Length | Should -Be 0
    }

    It 'handles null without throwing' {
        $s = ConvertTo-BraveLockerSecureString -Text $null
        $s.Length | Should -Be 0
    }

    It 'is read-only, so it cannot be altered after creation' {
        (ConvertTo-BraveLockerSecureString -Text 'abc').IsReadOnly() | Should -BeTrue
    }

    It 'feeds a passphrase the elevated task can decrypt' {
        # The full path the real passphrase takes: dialog text -> SecureString
        # -> DPAPI-protected string -> back to the original.
        $s = ConvertTo-BraveLockerSecureString -Text 'vault passphrase 123'
        $protected = ConvertFrom-SecureString -SecureString $s
        Get-PlainText -Secure (ConvertTo-SecureString -String $protected) | Should -Be 'vault passphrase 123'
    }
}

Describe 'UI functions are available to the launcher' {
    It 'exports the passphrase prompt' {
        Get-Command Show-BraveLockerPassphrasePrompt -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }

    It 'exports the message box' {
        Get-Command Show-BraveLockerMessage -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }
}
