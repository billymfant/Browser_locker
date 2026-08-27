$script:BraveLockerTaskName = 'BraveLocker-Mount'

function New-BraveLockerVaultRequest {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][ValidateSet('Mount', 'Dismount')][string]$Action,
        [Parameter(Mandatory)][string]$VhdxPath
    )

    [pscustomobject]@{
        RequestId  = [guid]::NewGuid().ToString()
        Action     = $Action
        VhdxPath   = $VhdxPath
        CreatedUtc = (Get-Date).ToUniversalTime().ToString('o')
    }
}

function Test-BraveLockerVaultResponse {
    <#
        Guards against acting on a leftover response file from an earlier launch.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][AllowNull()]$Response,
        [Parameter(Mandatory)][string]$RequestId
    )

    if ($null -eq $Response) { return $false }

    $id = Get-BraveLockerPropertyValue -InputObject $Response -Name 'RequestId'
    if ($null -eq $id) { return $false }

    ([string]$id) -eq $RequestId
}

function Test-BraveLockerAclHardened {
    <#
        The scheduled task runs a script from this directory with administrator
        rights. If a non-administrator can write here, they can replace that
        script and get code execution as admin - so the tool would create the
        very hole it exists to close.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][AllowEmptyCollection()][string[]]$IcaclsOutput)

    $risky = 'Users', 'Authenticated Users', 'Everyone', 'INTERACTIVE'

    foreach ($line in $IcaclsOutput) {
        foreach ($principal in $risky) {
            if ($line -notmatch ([regex]::Escape($principal) + '\s*:')) { continue }
            # (F)ull, (M)odify and (W)rite each let a non-admin replace the script.
            if ($line -match '\((F|M|W)\)') { return $false }
        }
    }
    $true
}

function Set-BraveLockerScriptAcl {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $output = & icacls.exe $Path /inheritance:r `
        /grant:r 'BUILTIN\Administrators:(OI)(CI)F' `
        'NT AUTHORITY\SYSTEM:(OI)(CI)F' `
        'BUILTIN\Users:(OI)(CI)RX' 2>&1

    if ($LASTEXITCODE -ne 0) {
        throw ("Brave Locker: failed to harden '$Path'.`r`n" + ($output -join "`r`n"))
    }

    $verify = & icacls.exe $Path 2>&1
    if (-not (Test-BraveLockerAclHardened -IcaclsOutput @($verify | ForEach-Object { [string]$_ }))) {
        throw "Brave Locker: '$Path' is still writable by non-administrators after hardening. Refusing to continue, because the elevated task would be hijackable."
    }
}

function Register-BraveLockerMountTask {
    [CmdletBinding()]
    param(
        [string]$TaskName = $script:BraveLockerTaskName,
        [Parameter(Mandatory)][string]$ScriptPath
    )

    if (-not (Test-Path $ScriptPath)) {
        throw "Brave Locker: cannot register the mount task; '$ScriptPath' does not exist."
    }

    $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
        -Argument ('-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}"' -f $ScriptPath)

    $principal = New-ScheduledTaskPrincipal -UserId ('{0}\{1}' -f $env:USERDOMAIN, $env:USERNAME) `
        -LogonType Interactive -RunLevel Highest

    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -ExecutionTimeLimit (New-TimeSpan -Minutes 5) -MultipleInstances IgnoreNew

    Register-ScheduledTask -TaskName $TaskName -Action $action -Principal $principal `
        -Settings $settings -Description 'Attaches and detaches the Brave Locker vault.' -Force | Out-Null
}

function Invoke-BraveLockerMountTask {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][ValidateSet('Mount', 'Dismount')][string]$Action,
        [Parameter(Mandatory)][string]$VhdxPath,
        [string]$TaskName = $script:BraveLockerTaskName,
        [int]$TimeoutSeconds = 60
    )

    $paths = Get-BraveLockerPaths
    if (-not (Test-Path $paths.StateRoot)) {
        New-Item -ItemType Directory -Path $paths.StateRoot -Force | Out-Null
    }

    Remove-Item -Path $paths.ResponsePath -Force -ErrorAction SilentlyContinue

    $request = New-BraveLockerVaultRequest -Action $Action -VhdxPath $VhdxPath
    $request | ConvertTo-Json -Depth 5 | Set-Content -Path $paths.RequestPath -Encoding utf8

    Start-ScheduledTask -TaskName $TaskName -ErrorAction Stop

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if (Test-Path $paths.ResponsePath) {
            $response = $null
            try {
                $response = Get-Content -Path $paths.ResponsePath -Raw -ErrorAction Stop |
                    ConvertFrom-Json -ErrorAction Stop
            } catch {
                $response = $null
            }

            if (Test-BraveLockerVaultResponse -Response $response -RequestId $request.RequestId) {
                $success   = Get-BraveLockerPropertyValue -InputObject $response -Name 'Success'
                $letter    = Get-BraveLockerPropertyValue -InputObject $response -Name 'DriveLetter'
                $errorText = Get-BraveLockerPropertyValue -InputObject $response -Name 'Error'

                return [pscustomobject]@{
                    Success     = [bool]$success
                    DriveLetter = [string]$letter
                    Error       = [string]$errorText
                }
            }
        }
        Start-Sleep -Milliseconds 300
    }

    [pscustomobject]@{
        Success     = $false
        DriveLetter = ''
        Error       = "The vault task did not respond within $TimeoutSeconds seconds."
    }
}
