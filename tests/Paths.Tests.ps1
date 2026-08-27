BeforeAll {
    Import-Module "$PSScriptRoot\..\src\BraveLocker\BraveLocker.psd1" -Force
}

Describe 'Get-BraveLockerPaths' {
    It 'defaults StateRoot to LOCALAPPDATA\BraveLocker' {
        $p = Get-BraveLockerPaths
        $p.StateRoot | Should -Be (Join-Path $env:LOCALAPPDATA 'BraveLocker')
    }

    It 'honours an explicit StateRoot' {
        $p = Get-BraveLockerPaths -StateRoot 'C:\tmp\bl'
        $p.StateRoot | Should -Be 'C:\tmp\bl'
    }

    It 'derives all four file paths from StateRoot' {
        $p = Get-BraveLockerPaths -StateRoot 'C:\tmp\bl'
        $p.ConfigPath   | Should -Be 'C:\tmp\bl\config.json'
        $p.StatePath    | Should -Be 'C:\tmp\bl\state.json'
        $p.RequestPath  | Should -Be 'C:\tmp\bl\request.json'
        $p.ResponsePath | Should -Be 'C:\tmp\bl\response.json'
    }
}
