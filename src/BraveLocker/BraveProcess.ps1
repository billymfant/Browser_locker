function Test-BraveLockerCommandLineMatch {
    <#
        Ties a running brave.exe to *our* vault profile. Getting this wrong means
        the launcher kills the user's work Brave, so the match is exact on the
        resolved path rather than a substring search.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][AllowNull()][string]$CommandLine,
        [Parameter(Mandatory)][string]$ProfilePath
    )

    if ([string]::IsNullOrWhiteSpace($CommandLine)) { return $false }

    $wanted = $ProfilePath.TrimEnd('\').ToUpperInvariant()
    $pattern = '--user-data-dir=("?)([^"]*?)\1(\s|$)'

    foreach ($match in [regex]::Matches($CommandLine, $pattern)) {
        $value = $match.Groups[2].Value.Trim().TrimEnd('\').ToUpperInvariant()
        if ($value -eq $wanted) { return $true }
    }
    $false
}

function Get-BraveLockerBrowserProcess {
    <#
        -AnyProfile matches every brave.exe rather than only those carrying a
        matching --user-data-dir.

        That is correct once the vault is mounted onto Brave's own profile
        folder: Brave is launched with no override at all, so there is no switch
        to match on, and every running Brave is by definition using the vault.
        It does mean the command-line safety net is gone in that mode - there is
        no longer a way to tell "our" Brave from another one, because there is
        no other one.
    #>
    [CmdletBinding()]
    param(
        [string]$ProfilePath = '',
        [switch]$AnyProfile
    )

    $processes = Get-CimInstance Win32_Process -Filter "Name='brave.exe'" -ErrorAction SilentlyContinue
    if ($AnyProfile) { return $processes }

    if ([string]::IsNullOrWhiteSpace($ProfilePath)) {
        throw 'Brave Locker: Get-BraveLockerBrowserProcess needs either -ProfilePath or -AnyProfile.'
    }

    $processes | Where-Object { Test-BraveLockerCommandLineMatch -CommandLine $_.CommandLine -ProfilePath $ProfilePath }
}

function Start-BraveLockerBrowser {
    <#
        -UseDefaultProfile launches Brave with no --user-data-dir at all, so it
        opens its normal profile location - which is where the vault is mounted.

        Passing an explicit path instead is what broke the logins: Brave's
        App-Bound Encryption ties cookies and saved passwords to the profile
        path, so a profile reached by any other path decrypts nothing.
    #>
    [CmdletBinding()]
    [OutputType([System.Diagnostics.Process])]
    param(
        [Parameter(Mandatory)][string]$BraveExe,
        [string]$ProfilePath = '',
        [switch]$UseDefaultProfile
    )

    if (-not (Test-Path $BraveExe)) {
        throw "Brave Locker: Brave was not found at '$BraveExe'."
    }

    if ($UseDefaultProfile) {
        return Start-Process -FilePath $BraveExe -PassThru
    }

    if ([string]::IsNullOrWhiteSpace($ProfilePath)) {
        throw 'Brave Locker: Start-BraveLockerBrowser needs either -ProfilePath or -UseDefaultProfile.'
    }
    if (-not (Test-Path $ProfilePath)) {
        New-Item -ItemType Directory -Path $ProfilePath -Force | Out-Null
    }

    Start-Process -FilePath $BraveExe -ArgumentList "--user-data-dir=`"$ProfilePath`"" -PassThru
}

function Wait-BraveLockerBrowserExit {
    [CmdletBinding()]
    param(
        [string]$ProfilePath = '',
        [switch]$AnyProfile,
        [int]$PollSeconds = 2
    )

    # Brave forks helper processes and the process we launched can exit early,
    # so poll for anything still using this profile rather than waiting on a handle.
    while (@(Get-BraveLockerBrowserProcess -ProfilePath $ProfilePath -AnyProfile:$AnyProfile).Count -gt 0) {
        Start-Sleep -Seconds $PollSeconds
    }
}

function Stop-BraveLockerBrowser {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [string]$ProfilePath = '',
        [switch]$AnyProfile,
        [int]$TimeoutSeconds = 15
    )

    $processes = @(Get-BraveLockerBrowserProcess -ProfilePath $ProfilePath -AnyProfile:$AnyProfile)
    if ($processes.Count -eq 0) { return $true }

    foreach ($process in $processes) {
        Stop-Process -Id $process.ProcessId -Force -ErrorAction SilentlyContinue
    }

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if (@(Get-BraveLockerBrowserProcess -ProfilePath $ProfilePath -AnyProfile:$AnyProfile).Count -eq 0) { return $true }
        Start-Sleep -Milliseconds 500
    }
    return (@(Get-BraveLockerBrowserProcess -ProfilePath $ProfilePath -AnyProfile:$AnyProfile).Count -eq 0)
}
