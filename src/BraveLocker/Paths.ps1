function Get-BraveLockerPaths {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [string]$StateRoot
    )

    if ([string]::IsNullOrWhiteSpace($StateRoot)) {
        $StateRoot = Join-Path $env:LOCALAPPDATA 'BraveLocker'
    }

    [pscustomobject]@{
        StateRoot    = $StateRoot
        ConfigPath   = Join-Path $StateRoot 'config.json'
        StatePath    = Join-Path $StateRoot 'state.json'
        RequestPath  = Join-Path $StateRoot 'request.json'
        ResponsePath = Join-Path $StateRoot 'response.json'
    }
}
