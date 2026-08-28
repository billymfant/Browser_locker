# Which browsers this tool can lock, and how to find them.
#
# Every Chromium-based browser keeps its profile the same way - a "User Data"
# folder holding Local State and one or more profile directories - and every
# one of them since Chromium 127 uses App-Bound Encryption, which is what
# forces the vault to be mounted onto the profile path rather than the profile
# being moved into the vault.
#
# Firefox is a different shape entirely and is listed as unsupported rather
# than omitted, so the setup screen can say why instead of silently not
# offering it.

function Get-BraveLockerBrowserCatalog {
    <#
        The browsers the tool knows about.

        ProfileRoot is relative to the named special folder, because Opera puts
        its profile under Roaming while the rest use Local.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param()

    $catalog = @(
        [pscustomobject]@{
            Id            = 'brave'
            Name          = 'Brave'
            Family        = 'Chromium'
            ExeName       = 'brave.exe'
            ProcessName   = 'brave'
            ProfileBase   = 'LocalAppData'
            ProfileRoot   = 'BraveSoftware\Brave-Browser\User Data'
            InstallHints  = @('BraveSoftware\Brave-Browser\Application\brave.exe')
            IsSupported   = $true
            Note          = ''
        }
        [pscustomobject]@{
            Id            = 'chrome'
            Name          = 'Google Chrome'
            Family        = 'Chromium'
            ExeName       = 'chrome.exe'
            ProcessName   = 'chrome'
            ProfileBase   = 'LocalAppData'
            ProfileRoot   = 'Google\Chrome\User Data'
            InstallHints  = @('Google\Chrome\Application\chrome.exe')
            IsSupported   = $true
            Note          = ''
        }
        [pscustomobject]@{
            Id            = 'edge'
            Name          = 'Microsoft Edge'
            Family        = 'Chromium'
            ExeName       = 'msedge.exe'
            ProcessName   = 'msedge'
            ProfileBase   = 'LocalAppData'
            ProfileRoot   = 'Microsoft\Edge\User Data'
            InstallHints  = @('Microsoft\Edge\Application\msedge.exe')
            IsSupported   = $true
            # Windows itself opens Edge for widgets, web search from the Start
            # menu, PDFs and help links. Those launches bypass the shortcut, so
            # they will open an empty profile while the vault is sealed.
            Note          = 'Windows launches Edge on its own for widgets, Start-menu web search and PDFs. Those bypass the passcode and will open an empty profile. Lock Edge only if you do not rely on any of that.'
        }
        [pscustomobject]@{
            Id            = 'vivaldi'
            Name          = 'Vivaldi'
            Family        = 'Chromium'
            ExeName       = 'vivaldi.exe'
            ProcessName   = 'vivaldi'
            ProfileBase   = 'LocalAppData'
            ProfileRoot   = 'Vivaldi\User Data'
            InstallHints  = @('Vivaldi\Application\vivaldi.exe')
            IsSupported   = $true
            Note          = ''
        }
        [pscustomobject]@{
            Id            = 'opera'
            Name          = 'Opera'
            Family        = 'Chromium'
            ExeName       = 'opera.exe'
            ProcessName   = 'opera'
            ProfileBase   = 'AppData'
            ProfileRoot   = 'Opera Software\Opera Stable'
            InstallHints  = @('Programs\Opera\opera.exe')
            IsSupported   = $true
            Note          = ''
        }
        [pscustomobject]@{
            Id            = 'firefox'
            Name          = 'Mozilla Firefox'
            Family        = 'Gecko'
            ExeName       = 'firefox.exe'
            ProcessName   = 'firefox'
            ProfileBase   = 'AppData'
            ProfileRoot   = 'Mozilla\Firefox'
            InstallHints  = @('Mozilla Firefox\firefox.exe')
            IsSupported   = $false
            # Listed rather than hidden so the reason can be shown. Firefox
            # stores profiles under randomly named directories indexed by
            # profiles.ini, and has no App-Bound Encryption, so it needs a
            # different migration and a different set of checks. Shipping it
            # untested would risk someone's profile.
            Note          = 'Not supported yet. Firefox arranges its profiles differently and needs its own migration path, which has not been built or tested.'
        }
    )

    # No comma-wrapping here: these are always multi-element, and ',$array'
    # returns a single object that IS the array, which reads as Count 1.
    $catalog
}

function Get-BraveLockerBrowserById {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Id,
        [object[]]$Catalog
    )

    if (-not $Catalog) { $Catalog = Get-BraveLockerBrowserCatalog }
    $Catalog | Where-Object { $_.Id -eq $Id } | Select-Object -First 1
}

function Get-BraveLockerBrowserProfileRoot {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][object]$Browser,
        [string]$LocalAppData = $env:LOCALAPPDATA,
        [string]$RoamingAppData = $env:APPDATA
    )

    $base = $(if ($Browser.ProfileBase -eq 'AppData') { $RoamingAppData } else { $LocalAppData })
    Join-Path $base $Browser.ProfileRoot
}

function Get-BraveLockerBrowserExePath {
    <#
        Where this browser is installed. The registry's App Paths key is
        checked first, because it survives per-user installs and browsers put
        on a drive nobody would guess.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][object]$Browser,
        [string[]]$SearchPath
    )

    if ($SearchPath) {
        foreach ($candidate in $SearchPath) {
            if ($candidate -and (Test-Path $candidate)) { return $candidate }
        }
        return ''
    }

    foreach ($hive in 'HKLM:', 'HKCU:') {
        $key = "$hive\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\$($Browser.ExeName)"
        if (-not (Test-Path $key)) { continue }
        $value = [string](Get-ItemProperty -Path $key -ErrorAction SilentlyContinue).'(default)'
        if ($value) {
            $value = $value.Trim('"')
            if (Test-Path $value) { return $value }
        }
    }

    $roots = @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:LOCALAPPDATA)
    foreach ($root in $roots) {
        if (-not $root) { continue }
        foreach ($hint in $Browser.InstallHints) {
            $candidate = Join-Path $root $hint
            if (Test-Path $candidate) { return $candidate }
        }
    }

    ''
}

function Get-BraveLockerInstalledBrowser {
    <#
        Every browser in the catalogue, annotated with whether it is installed
        on this machine and whether its profile looks usable.

        Returns all of them, not only the installed ones, so the setup screen
        can show "Firefox - not supported yet" rather than leaving someone
        wondering why their browser is missing from the list.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [object[]]$Catalog,
        [string]$LocalAppData = $env:LOCALAPPDATA,
        [string]$RoamingAppData = $env:APPDATA
    )

    if (-not $Catalog) { $Catalog = Get-BraveLockerBrowserCatalog }

    $results = foreach ($browser in $Catalog) {
        $exe = Get-BraveLockerBrowserExePath -Browser $browser
        $profileRoot = Get-BraveLockerBrowserProfileRoot -Browser $browser `
            -LocalAppData $LocalAppData -RoamingAppData $RoamingAppData
        $profileState = Test-BraveLockerProfileUsable -Path $profileRoot

        $canLock = ([bool]$exe) -and $browser.IsSupported -and $profileState.IsUsable

        $reason = ''
        if (-not $browser.IsSupported)      { $reason = $browser.Note }
        elseif (-not $exe)                  { $reason = 'Not installed on this PC.' }
        elseif (-not $profileState.IsUsable) { $reason = "Installed, but no usable profile yet. Open $($browser.Name) once, then run setup again." }

        [pscustomobject]@{
            Id           = $browser.Id
            Name         = $browser.Name
            Family       = $browser.Family
            ExeName      = $browser.ExeName
            ProcessName  = $browser.ProcessName
            ExePath      = $exe
            ProfileRoot  = $profileRoot
            IsInstalled  = [bool]$exe
            IsSupported  = $browser.IsSupported
            CanLock      = $canLock
            ProfileSize  = $profileState.SizeBytes
            ProfileCount = $profileState.ProfileCount
            Note         = $browser.Note
            Reason       = $reason
        }
    }

    @($results)
}
