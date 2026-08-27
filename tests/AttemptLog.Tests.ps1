BeforeAll {
    Import-Module "$PSScriptRoot\..\src\BraveLocker\BraveLocker.psd1" -Force
}

Describe 'Get-BraveLockerCooldownSeconds' {
    It 'is zero with no failures'      { Get-BraveLockerCooldownSeconds -FailureCount 0 | Should -Be 0 }
    It 'is 5 seconds after one'        { Get-BraveLockerCooldownSeconds -FailureCount 1 | Should -Be 5 }
    It 'is 30 seconds after two'       { Get-BraveLockerCooldownSeconds -FailureCount 2 | Should -Be 30 }
    It 'is 5 minutes after three'      { Get-BraveLockerCooldownSeconds -FailureCount 3 | Should -Be 300 }
    It 'holds at 5 minutes after many' { Get-BraveLockerCooldownSeconds -FailureCount 9 | Should -Be 300 }
}

Describe 'attempt log' {
    BeforeEach {
        $script:statePath = Join-Path $TestDrive ((New-Guid).Guid + '\state.json')
        $script:now = [datetime]::new(2026, 8, 27, 14, 22, 0, [datetimekind]::Utc)
    }

    It 'reports zero failures when no state file exists' {
        (Get-BraveLockerState -StatePath $script:statePath).FailureCount | Should -Be 0
    }

    It 'increments the failure count and persists it' {
        Add-BraveLockerFailedAttempt -StatePath $script:statePath -NowUtc $script:now | Should -Be 1
        Add-BraveLockerFailedAttempt -StatePath $script:statePath -NowUtc $script:now | Should -Be 2
        (Get-BraveLockerState -StatePath $script:statePath).FailureCount | Should -Be 2
    }

    It 'records the most recent failure time' {
        Add-BraveLockerFailedAttempt -StatePath $script:statePath -NowUtc $script:now | Out-Null
        $s = Get-BraveLockerState -StatePath $script:statePath
        ([datetime]$s.LastFailureUtc).ToUniversalTime().Hour | Should -Be 14
    }

    It 'returns the prior state when cleared, then resets to zero' {
        Add-BraveLockerFailedAttempt -StatePath $script:statePath -NowUtc $script:now | Out-Null
        (Clear-BraveLockerFailedAttempts -StatePath $script:statePath).FailureCount | Should -Be 1
        (Get-BraveLockerState -StatePath $script:statePath).FailureCount | Should -Be 0
    }

    It 'reports remaining cooldown immediately after a failure' {
        Add-BraveLockerFailedAttempt -StatePath $script:statePath -NowUtc $script:now | Out-Null
        Get-BraveLockerRemainingCooldownSeconds -StatePath $script:statePath -NowUtc $script:now | Should -Be 5
    }

    It 'reports no remaining cooldown once it has elapsed' {
        Add-BraveLockerFailedAttempt -StatePath $script:statePath -NowUtc $script:now | Out-Null
        Get-BraveLockerRemainingCooldownSeconds -StatePath $script:statePath -NowUtc $script:now.AddSeconds(6) |
            Should -Be 0
    }

    It 'treats a corrupt state file as no failures rather than throwing' {
        New-Item -ItemType Directory -Path (Split-Path -Parent $script:statePath) -Force | Out-Null
        Set-Content -Path $script:statePath -Value 'not json at all' -Encoding utf8
        (Get-BraveLockerState -StatePath $script:statePath).FailureCount | Should -Be 0
    }
}
