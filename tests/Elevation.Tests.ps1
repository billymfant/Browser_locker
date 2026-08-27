BeforeAll {
    Import-Module "$PSScriptRoot\..\src\BraveLocker\BraveLocker.psd1" -Force
}

Describe 'New-BraveLockerVaultRequest' {
    It 'carries the action and path' {
        $r = New-BraveLockerVaultRequest -Action 'Mount' -VhdxPath 'D:\v.vhdx'
        $r.Action   | Should -Be 'Mount'
        $r.VhdxPath | Should -Be 'D:\v.vhdx'
    }

    It 'gives every request a distinct id' {
        $a = New-BraveLockerVaultRequest -Action 'Mount' -VhdxPath 'D:\v.vhdx'
        $b = New-BraveLockerVaultRequest -Action 'Mount' -VhdxPath 'D:\v.vhdx'
        $a.RequestId | Should -Not -Be $b.RequestId
    }

    It 'rejects an unknown action' {
        { New-BraveLockerVaultRequest -Action 'Delete' -VhdxPath 'D:\v.vhdx' } | Should -Throw
    }

    It 'carries no passphrase when none is supplied' {
        $r = New-BraveLockerVaultRequest -Action 'Dismount' -VhdxPath 'D:\v.vhdx'
        $r.ProtectedPassphrase | Should -Be ''
    }

    It 'carries the protected passphrase when one is supplied' {
        $r = New-BraveLockerVaultRequest -Action 'Mount' -VhdxPath 'D:\v.vhdx' -ProtectedPassphrase 'ABC123'
        $r.ProtectedPassphrase | Should -Be 'ABC123'
    }

    It 'never stores the passphrase in readable form' {
        # DPAPI round-trip: what lands in the request file must not be the text.
        $secure = ConvertTo-SecureString 'my-real-passphrase' -AsPlainText -Force
        $protected = ConvertFrom-SecureString -SecureString $secure
        $protected | Should -Not -Match 'my-real-passphrase'

        $r = New-BraveLockerVaultRequest -Action 'Mount' -VhdxPath 'D:\v.vhdx' -ProtectedPassphrase $protected
        ($r | ConvertTo-Json) | Should -Not -Match 'my-real-passphrase'
    }

    It 'round-trips back to the original passphrase for the task that must use it' {
        $secure = ConvertTo-SecureString 'my-real-passphrase' -AsPlainText -Force
        $protected = ConvertFrom-SecureString -SecureString $secure
        $restored = ConvertTo-SecureString -String $protected
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($restored)
        try {
            [Runtime.InteropServices.Marshal]::PtrToStringUni($bstr) | Should -Be 'my-real-passphrase'
        } finally {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        }
    }
}

Describe 'Test-BraveLockerVaultResponse' {
    It 'accepts a response whose id matches the request' {
        $resp = [pscustomobject]@{ RequestId = 'abc'; Success = $true }
        Test-BraveLockerVaultResponse -Response $resp -RequestId 'abc' | Should -BeTrue
    }

    It 'rejects a stale response from an earlier request' {
        $resp = [pscustomobject]@{ RequestId = 'old'; Success = $true }
        Test-BraveLockerVaultResponse -Response $resp -RequestId 'new' | Should -BeFalse
    }

    It 'rejects a null response' {
        Test-BraveLockerVaultResponse -Response $null -RequestId 'abc' | Should -BeFalse
    }

    It 'rejects a response with no id at all' {
        $resp = [pscustomobject]@{ Success = $true }
        Test-BraveLockerVaultResponse -Response $resp -RequestId 'abc' | Should -BeFalse
    }
}

Describe 'Test-BraveLockerAclHardened' {
    It 'accepts an ACL where only admins and SYSTEM can write' {
        $out = @(
            'D:\apps\brave_locker BUILTIN\Administrators:(OI)(CI)(F)'
            '                     NT AUTHORITY\SYSTEM:(OI)(CI)(F)'
            '                     BUILTIN\Users:(OI)(CI)(RX)'
        )
        Test-BraveLockerAclHardened -IcaclsOutput $out | Should -BeTrue
    }

    It 'rejects an ACL granting Users full control' {
        $out = @(
            'D:\apps\brave_locker BUILTIN\Administrators:(OI)(CI)(F)'
            '                     BUILTIN\Users:(OI)(CI)(F)'
        )
        Test-BraveLockerAclHardened -IcaclsOutput $out | Should -BeFalse
    }

    It 'rejects an ACL granting Users modify' {
        Test-BraveLockerAclHardened -IcaclsOutput @('D:\x BUILTIN\Users:(OI)(CI)(M)') | Should -BeFalse
    }

    It 'rejects an ACL granting Authenticated Users write' {
        Test-BraveLockerAclHardened -IcaclsOutput @('D:\x NT AUTHORITY\Authenticated Users:(OI)(CI)(W)') |
            Should -BeFalse
    }

    It 'rejects an ACL granting Everyone full control' {
        Test-BraveLockerAclHardened -IcaclsOutput @('D:\x Everyone:(OI)(CI)(F)') | Should -BeFalse
    }

    It 'tolerates the blank lines real icacls output contains' {
        # icacls emits a blank line and a summary line; rejecting those made the
        # verification throw during setup instead of verifying anything.
        $out = @(
            'C:\Program Files\BraveLocker BUILTIN\Users:(OI)(CI)(RX)'
            '                             NT AUTHORITY\SYSTEM:(OI)(CI)(F)'
            '                             BUILTIN\Administrators:(OI)(CI)(F)'
            ''
            'Successfully processed 1 files; Failed processing 0 files'
        )
        Test-BraveLockerAclHardened -IcaclsOutput $out | Should -BeTrue
    }

    It 'tolerates a null entry in the output' {
        Test-BraveLockerAclHardened -IcaclsOutput @('D:\x BUILTIN\Users:(OI)(CI)(RX)', $null) | Should -BeTrue
    }
}
