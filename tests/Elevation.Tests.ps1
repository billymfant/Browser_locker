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
}
