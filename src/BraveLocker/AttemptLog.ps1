function Get-BraveLockerCooldownSeconds {
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Mandatory)][int]$FailureCount)

    if ($FailureCount -le 0) { return 0 }
    if ($FailureCount -eq 1) { return 5 }
    if ($FailureCount -eq 2) { return 30 }
    return 300
}

function Get-BraveLockerPropertyValue {
    <#
        Strict mode turns a missing property into a terminating error, and the
        state file is user-writable, so every read of it goes through here.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowNull()]$InputObject,
        [Parameter(Mandatory)][string]$Name
    )

    if ($null -eq $InputObject) { return $null }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    $property.Value
}

function Get-BraveLockerState {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string]$StatePath)

    $empty = [pscustomobject]@{ FailureCount = 0; LastFailureUtc = '' }
    if (-not (Test-Path $StatePath)) { return $empty }

    try {
        $obj = Get-Content -Path $StatePath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    } catch {
        # A corrupt or hand-edited state file must never lock the user out of
        # their own browser. Treat it as no recorded failures.
        return $empty
    }

    $rawCount = Get-BraveLockerPropertyValue -InputObject $obj -Name 'FailureCount'
    $rawLast  = Get-BraveLockerPropertyValue -InputObject $obj -Name 'LastFailureUtc'

    $count = 0
    if ($null -ne $rawCount) {
        try { $count = [int]$rawCount } catch { $count = 0 }
    }

    $last = ''
    if ($null -ne $rawLast) { $last = [string]$rawLast }

    [pscustomobject]@{ FailureCount = $count; LastFailureUtc = $last }
}

function Save-BraveLockerState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$StatePath,
        [Parameter(Mandatory)][pscustomobject]$State
    )

    $dir = Split-Path -Parent $StatePath
    if ($dir -and -not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $State | ConvertTo-Json -Depth 5 | Set-Content -Path $StatePath -Encoding utf8
}

function Add-BraveLockerFailedAttempt {
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)][string]$StatePath,
        [Parameter(Mandatory)][datetime]$NowUtc
    )

    $state = Get-BraveLockerState -StatePath $StatePath
    $next = [pscustomobject]@{
        FailureCount   = $state.FailureCount + 1
        LastFailureUtc = $NowUtc.ToUniversalTime().ToString('o')
    }
    Save-BraveLockerState -StatePath $StatePath -State $next
    $next.FailureCount
}

function Clear-BraveLockerFailedAttempts {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string]$StatePath)

    $prior = Get-BraveLockerState -StatePath $StatePath
    Save-BraveLockerState -StatePath $StatePath -State ([pscustomobject]@{
        FailureCount   = 0
        LastFailureUtc = ''
    })
    $prior
}

function Get-BraveLockerRemainingCooldownSeconds {
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)][string]$StatePath,
        [Parameter(Mandatory)][datetime]$NowUtc
    )

    $state = Get-BraveLockerState -StatePath $StatePath
    if ($state.FailureCount -le 0) { return 0 }
    if ([string]::IsNullOrWhiteSpace($state.LastFailureUtc)) { return 0 }

    try {
        $lastFailure = ([datetime]$state.LastFailureUtc).ToUniversalTime()
    } catch {
        return 0
    }

    $cooldown = Get-BraveLockerCooldownSeconds -FailureCount $state.FailureCount
    $elapsed = ($NowUtc.ToUniversalTime() - $lastFailure).TotalSeconds
    $remaining = [int][math]::Ceiling($cooldown - $elapsed)
    if ($remaining -lt 0) { return 0 }
    $remaining
}
