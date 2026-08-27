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
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ProfilePath)

    Get-CimInstance Win32_Process -Filter "Name='brave.exe'" -ErrorAction SilentlyContinue |
        Where-Object { Test-BraveLockerCommandLineMatch -CommandLine $_.CommandLine -ProfilePath $ProfilePath }
}

function Start-BraveLockerBrowser {
    [CmdletBinding()]
    [OutputType([System.Diagnostics.Process])]
    param(
        [Parameter(Mandatory)][string]$BraveExe,
        [Parameter(Mandatory)][string]$ProfilePath
    )

    if (-not (Test-Path $BraveExe)) {
        throw "Brave Locker: Brave was not found at '$BraveExe'."
    }
    if (-not (Test-Path $ProfilePath)) {
        New-Item -ItemType Directory -Path $ProfilePath -Force | Out-Null
    }

    Start-Process -FilePath $BraveExe -ArgumentList "--user-data-dir=`"$ProfilePath`"" -PassThru
}

function Wait-BraveLockerBrowserExit {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProfilePath,
        [int]$PollSeconds = 2
    )

    # Brave forks helper processes and the process we launched can exit early,
    # so poll for anything still using this profile rather than waiting on a handle.
    while (@(Get-BraveLockerBrowserProcess -ProfilePath $ProfilePath).Count -gt 0) {
        Start-Sleep -Seconds $PollSeconds
    }
}

function Stop-BraveLockerBrowser {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$ProfilePath,
        [int]$TimeoutSeconds = 15
    )

    $processes = @(Get-BraveLockerBrowserProcess -ProfilePath $ProfilePath)
    if ($processes.Count -eq 0) { return $true }

    foreach ($process in $processes) {
        Stop-Process -Id $process.ProcessId -Force -ErrorAction SilentlyContinue
    }

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if (@(Get-BraveLockerBrowserProcess -ProfilePath $ProfilePath).Count -eq 0) { return $true }
        Start-Sleep -Milliseconds 500
    }
    return (@(Get-BraveLockerBrowserProcess -ProfilePath $ProfilePath).Count -eq 0)
}
