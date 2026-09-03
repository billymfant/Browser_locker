<#
    Breaks the launcher in several ways and checks that each one produces a way
    out rather than silence.

    Fully isolated from the live install:
      - the repo is copied to a scratch folder
      - Ui.ps1 is replaced with a stub that LOGS what it would have shown,
        so nothing pops up over the user's screen and the run is automatable
      - $env:LOCALAPPDATA is redirected, so Get-BraveLockerPaths reads a fake
        config and never sees the real one
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Resolved from this file's location: tests\manual\ -> repo root.
$repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$scratch = Join-Path $env:TEMP ('brave-locker-deadend-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $scratch -Force | Out-Null
$sandbox = Join-Path $scratch 'sandbox'

if (Test-Path $sandbox) { Remove-Item $sandbox -Recurse -Force }
New-Item -ItemType Directory -Path $sandbox -Force | Out-Null
Copy-Item (Join-Path $repo 'src') (Join-Path $sandbox 'src') -Recurse -Force
Copy-Item (Join-Path $repo 'scripts') (Join-Path $sandbox 'scripts') -Recurse -Force

# --- Stub the UI so the run is headless ------------------------------------
$uiStub = @'
Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue

function Write-StubLog {
    param([string]$Line)
    Add-Content -Path $env:BRAVELOCKER_TESTLOG -Encoding utf8 -Value $Line
}

function ConvertTo-BraveLockerSecureString {
    param([Parameter(Mandatory)][AllowEmptyString()][AllowNull()][string]$Text)
    $s = New-Object System.Security.SecureString
    if ($Text) { foreach ($c in $Text.ToCharArray()) { $s.AppendChar($c) } }
    $s.MakeReadOnly(); $s
}

function Show-BraveLockerMessage {
    param(
        [Parameter(Mandatory)][string]$Message,
        [string]$Title = '', [string]$Icon = 'Info'
    )
    Write-StubLog "MESSAGE[$Icon] $($Message -replace '\s+', ' ')"
}

function Show-BraveLockerPassphrasePrompt {
    param([string]$Title = '', [string]$IconSource = '', [string]$Note = '')
    Write-StubLog "PASSPHRASE-PROMPT shown"
    $null   # behave as if cancelled: we are testing the paths BEFORE the vault
}

function Show-BraveLockerRecoveryChoice {
    param(
        [Parameter(Mandatory)][string]$Message,
        [string]$Title = '', [string]$Detail = '', [string]$IconSource = '',
        [switch]$NoOpenUnlocked
    )
    Write-StubLog "RECOVERY-CHOICE: $($Message -replace '\s+', ' ')"
    Write-StubLog "   detail: $($Detail -replace '\s+', ' ')"
    Write-StubLog "   offers-open-unlocked: $(-not $NoOpenUnlocked)"
    'Close'
}
'@
Set-Content -Path (Join-Path $sandbox 'src\BraveLocker\Ui.ps1') -Value $uiStub -Encoding utf8

$launcher = Join-Path $sandbox 'scripts\Start-BraveLocked.ps1'
$fakeLocal = Join-Path $sandbox 'localappdata'
$stateRoot = Join-Path $fakeLocal 'BraveLocker'

function Reset-Sandbox {
    if (Test-Path $fakeLocal) { Remove-Item $fakeLocal -Recurse -Force }
    New-Item -ItemType Directory -Path $stateRoot -Force | Out-Null
}

function Invoke-Scenario {
    param([string]$Name, [scriptblock]$Setup)

    Reset-Sandbox
    & $Setup

    $log = Join-Path $sandbox 'testlog.txt'
    if (Test-Path $log) { Remove-Item $log -Force }
    New-Item -ItemType File -Path $log -Force | Out-Null

    # A child process, so $env:LOCALAPPDATA can be redirected without
    # disturbing this session.
    $psi = "`$env:LOCALAPPDATA='$fakeLocal'; `$env:BRAVELOCKER_TESTLOG='$log'; & '$launcher'"
    $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($psi))
    $p = Start-Process -FilePath 'powershell.exe' -Wait -PassThru -WindowStyle Hidden -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $enc)

    $lines = @()
    if (Test-Path $log) { $lines = @(Get-Content $log) }

    Write-Host ""
    Write-Host "=== $Name ===" -ForegroundColor Cyan
    Write-Host "  launcher exit code: $($p.ExitCode)"
    if ($lines.Count -eq 0) {
        Write-Host "  *** SILENCE - NOTHING WAS SHOWN ***" -ForegroundColor Red
    } else {
        foreach ($l in $lines) { Write-Host "  $l" }
    }
    $lines
}

$results = @{}

# 1. The config is corrupt. Nothing anticipates this - it must hit the
#    catch-all and still produce a way out.
$results['corrupt-config'] = Invoke-Scenario 'Corrupt config (unanticipated error)' {
    Set-Content -Path (Join-Path $stateRoot 'config.json') -Value '{ this is not json' -Encoding utf8
}

# 2. A config from an older version with no mount path.
$results['no-mountpath'] = Invoke-Scenario 'Config with no ProfileMountPath' {
    @{ VhdxPath = 'D:\nope\vault.vhdx'; BraveExe = 'C:\nope\brave.exe' } |
        ConvertTo-Json | Set-Content -Path (Join-Path $stateRoot 'config.json') -Encoding utf8
}

# 3. Locked out by the cooldown.
$results['cooldown'] = Invoke-Scenario 'Cooldown lockout' {
    @{
        VhdxPath = 'D:\nope\vault.vhdx'
        ProfileMountPath = (Join-Path $sandbox 'profile')
        BraveExe = 'C:\nope\brave.exe'
    } | ConvertTo-Json | Set-Content -Path (Join-Path $stateRoot 'config.json') -Encoding utf8

    @{ FailureCount = 5; LastFailureUtc = (Get-Date).ToUniversalTime().ToString('o') } |
        ConvertTo-Json | Set-Content -Path (Join-Path $stateRoot 'state.json') -Encoding utf8
}

# 4. The module itself is broken - the last-resort path, which must not depend
#    on the module it is reporting the failure of.
$results['broken-module'] = Invoke-Scenario 'Broken module (last resort)' {
    @{ VhdxPath = 'x'; ProfileMountPath = 'y'; BraveExe = 'z' } |
        ConvertTo-Json | Set-Content -Path (Join-Path $stateRoot 'config.json') -Encoding utf8
    Set-Content -Path (Join-Path $sandbox 'src\BraveLocker\BraveLocker.psd1') `
        -Value '@{ this is not a manifest' -Encoding utf8
}

Write-Host ""
Write-Host "============ VERDICT ============" -ForegroundColor Yellow
foreach ($key in 'corrupt-config', 'no-mountpath', 'cooldown') {
    $lines = $results[$key]
    $gotChoice = @($lines | Where-Object { $_ -match 'RECOVERY-CHOICE' }).Count -gt 0
    $status = if ($gotChoice) { 'PASS - offered a way out' } else { 'FAIL - dead end' }
    $colour = if ($gotChoice) { 'Green' } else { 'Red' }
    Write-Host ("{0,-18} {1}" -f $key, $status) -ForegroundColor $colour
}

# The broken-module case cannot log through the stub - the stub is inside the
# module that will not load. It writes to the launcher's own error log instead.
$errLog = Join-Path $stateRoot 'launcher-error.log'
$brokenHandled = Test-Path $errLog
Write-Host ("{0,-18} {1}" -f 'broken-module',
    $(if ($brokenHandled) { 'PASS - logged, did not die silently' } else { 'CHECK - see below' })) `
    -ForegroundColor $(if ($brokenHandled) { 'Green' } else { 'Yellow' })
if ($brokenHandled) { Get-Content $errLog | ForEach-Object { Write-Host "    $_" } }
