BeforeAll {
    Import-Module "$PSScriptRoot\..\src\BraveLocker\BraveLocker.psd1" -Force
}

Describe 'Get-BraveLockerBrowserCatalog' {
    It 'knows the Chromium browsers people actually use' {
        $ids = (Get-BraveLockerBrowserCatalog | ForEach-Object { $_.Id })
        foreach ($expected in 'brave', 'chrome', 'edge', 'vivaldi', 'opera') {
            $ids | Should -Contain $expected
        }
    }

    It 'lists Firefox rather than hiding it, so the reason can be shown' {
        # Silently omitting a browser leaves someone wondering whether the tool
        # is broken. Listing it with a reason is the difference between "not
        # offered" and "not supported yet, and here is why".
        $firefox = Get-BraveLockerBrowserById -Id 'firefox'
        $firefox            | Should -Not -BeNullOrEmpty
        $firefox.IsSupported | Should -BeFalse
        $firefox.Note        | Should -Match 'not supported yet|different'
    }

    It 'marks every Chromium browser as supported' {
        foreach ($browser in Get-BraveLockerBrowserCatalog | Where-Object { $_.Family -eq 'Chromium' }) {
            $browser.IsSupported | Should -BeTrue -Because "$($browser.Name) is Chromium-based"
        }
    }

    It 'warns about Edge, which Windows launches on its own' {
        # Widgets, Start-menu web search and PDFs all open Edge directly,
        # bypassing the shortcut and therefore the passcode.
        (Get-BraveLockerBrowserById -Id 'edge').Note | Should -Match 'widgets|Windows launches'
    }

    It 'gives every entry the fields the rest of the tool reads' {
        foreach ($browser in Get-BraveLockerBrowserCatalog) {
            foreach ($field in 'Id','Name','Family','ExeName','ProcessName','ProfileBase','ProfileRoot','IsSupported') {
                $browser.PSObject.Properties[$field] | Should -Not -BeNullOrEmpty -Because "$($browser.Id) needs $field"
            }
        }
    }

    It 'uses a process name with no .exe suffix, as Get-Process expects' {
        foreach ($browser in Get-BraveLockerBrowserCatalog) {
            $browser.ProcessName | Should -Not -Match '\.exe$'
        }
    }
}

Describe 'Get-BraveLockerBrowserProfileRoot' {
    It 'puts Chromium browsers under Local AppData' {
        $brave = Get-BraveLockerBrowserById -Id 'brave'
        Get-BraveLockerBrowserProfileRoot -Browser $brave -LocalAppData 'C:\L' -RoamingAppData 'C:\R' |
            Should -Be 'C:\L\BraveSoftware\Brave-Browser\User Data'
    }

    It 'puts Opera under Roaming, where it actually keeps its profile' {
        $opera = Get-BraveLockerBrowserById -Id 'opera'
        Get-BraveLockerBrowserProfileRoot -Browser $opera -LocalAppData 'C:\L' -RoamingAppData 'C:\R' |
            Should -Be 'C:\R\Opera Software\Opera Stable'
    }

    It 'resolves Chrome and Edge to their real locations' {
        (Get-BraveLockerBrowserProfileRoot -Browser (Get-BraveLockerBrowserById -Id 'chrome') -LocalAppData 'C:\L' -RoamingAppData 'C:\R') |
            Should -Be 'C:\L\Google\Chrome\User Data'
        (Get-BraveLockerBrowserProfileRoot -Browser (Get-BraveLockerBrowserById -Id 'edge') -LocalAppData 'C:\L' -RoamingAppData 'C:\R') |
            Should -Be 'C:\L\Microsoft\Edge\User Data'
    }
}

Describe 'Get-BraveLockerBrowserExePath' {
    It 'returns the first path that exists when given candidates' {
        $brave = Get-BraveLockerBrowserById -Id 'brave'
        $real = Join-Path $TestDrive 'brave.exe'
        Set-Content -Path $real -Value 'x' -Encoding ascii
        Get-BraveLockerBrowserExePath -Browser $brave -SearchPath @('C:\nothing\here.exe', $real) |
            Should -Be $real
    }

    It 'returns empty when nothing matches, rather than a made-up path' {
        Get-BraveLockerBrowserExePath -Browser (Get-BraveLockerBrowserById -Id 'brave') `
            -SearchPath @('C:\nope\brave.exe') | Should -Be ''
    }
}

Describe 'Get-BraveLockerInstalledBrowser' {
    BeforeEach {
        $script:work = Join-Path $TestDrive (New-Guid).Guid
        $script:local = Join-Path $script:work 'Local'
        $script:roaming = Join-Path $script:work 'Roaming'
        New-Item -ItemType Directory -Path $script:local, $script:roaming -Force | Out-Null
    }

    It 'returns every browser, not only the installed ones' {
        $found = Get-BraveLockerInstalledBrowser -LocalAppData $script:local -RoamingAppData $script:roaming
        @($found).Count | Should -Be @(Get-BraveLockerBrowserCatalog).Count
    }

    It 'cannot lock a browser with no usable profile, and says which' {
        $found = Get-BraveLockerInstalledBrowser -LocalAppData $script:local -RoamingAppData $script:roaming
        foreach ($browser in $found) {
            $browser.CanLock | Should -BeFalse
            $browser.Reason  | Should -Not -BeNullOrEmpty
        }
    }

    It 'never offers to lock Firefox even if a profile exists' {
        # An unsupported browser with a real profile is the dangerous case:
        # everything looks ready, and migrating it would be untested.
        $ff = Join-Path $script:roaming 'Mozilla\Firefox'
        New-Item -ItemType Directory -Path $ff -Force | Out-Null
        Set-Content -Path (Join-Path $ff 'Local State') -Value '{}' -Encoding utf8
        New-Item -ItemType Directory -Path (Join-Path $ff 'Default') -Force | Out-Null

        $firefox = Get-BraveLockerInstalledBrowser -LocalAppData $script:local -RoamingAppData $script:roaming |
            Where-Object { $_.Id -eq 'firefox' }
        $firefox.CanLock | Should -BeFalse
    }

    It 'reports the profile size so setup can size the vault' {
        $chrome = Join-Path $script:local 'Google\Chrome\User Data'
        New-Item -ItemType Directory -Path (Join-Path $chrome 'Default') -Force | Out-Null
        Set-Content -Path (Join-Path $chrome 'Local State') -Value ('x' * 2048) -Encoding utf8

        $found = Get-BraveLockerInstalledBrowser -LocalAppData $script:local -RoamingAppData $script:roaming |
            Where-Object { $_.Id -eq 'chrome' }
        $found.ProfileSize  | Should -BeGreaterThan 0
        $found.ProfileCount | Should -Be 1
    }
}
