#Requires -Version 5.1
<#
    Builds the distributable installer.

    Runs the unit suite first and refuses to package on a red build - shipping
    a tool that migrates browser profiles off untested code is not a trade
    worth making.

    Needs Inno Setup 6 (https://jrsoftware.org/isdl.php). Without it the script
    still runs the tests and reports what is missing.
#>
[CmdletBinding()]
param(
    [switch]$SkipTests,
    [string]$IsccPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$dist = Join-Path $root 'dist'

Write-Host ''
Write-Host 'Browser Locker - build' -ForegroundColor Cyan
Write-Host '===================='
Write-Host ''

# --- 1. Tests ---------------------------------------------------------------
if (-not $SkipTests) {
    Write-Host 'Running the unit suite...'
    Import-Module Pester -MinimumVersion 5.0 -ErrorAction Stop
    $result = Invoke-Pester -Path (Join-Path $root 'tests') -PassThru -Output Normal
    if ($result.FailedCount -gt 0) {
        throw "$($result.FailedCount) test(s) failed. Refusing to package a red build."
    }
    Write-Host "  $($result.PassedCount) tests passed." -ForegroundColor Green
}

# --- 2. Syntax check every shipped script ----------------------------------
Write-Host ''
Write-Host 'Parsing every script that will ship...'
$broken = 0
foreach ($file in Get-ChildItem -Path (Join-Path $root 'src'), (Join-Path $root 'scripts'), (Join-Path $root 'gui') -Filter *.ps1 -Recurse) {
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$errors)
    if ($errors) {
        $broken++
        Write-Host "  SYNTAX: $($file.Name)" -ForegroundColor Red
        $errors | ForEach-Object { Write-Host "    $($_.Message)" -ForegroundColor Red }
    }
}
if ($broken -gt 0) { throw "$broken script(s) do not parse." }
Write-Host '  all scripts parse.' -ForegroundColor Green

# --- 3. The wizard's XAML has to load, not just parse ----------------------
Write-Host ''
Write-Host 'Loading the wizard XAML...'
Add-Type -AssemblyName PresentationFramework
$wizardSource = Get-Content (Join-Path $root 'gui\BrowserLockerWizard.ps1') -Raw
$match = [regex]::Match($wizardSource, "(?s)\`$xaml = @'\r?\n(.*?)\r?\n'@")
if (-not $match.Success) { throw 'Could not find the XAML block in the wizard.' }
$reader = New-Object System.Xml.XmlNodeReader ([xml]$match.Groups[1].Value)
$null = [Windows.Markup.XamlReader]::Load($reader)
Write-Host '  XAML loads.' -ForegroundColor Green

# --- 4. Package -------------------------------------------------------------
if (-not (Test-Path $dist)) { New-Item -ItemType Directory -Path $dist -Force | Out-Null }

if (-not $IsccPath) {
    foreach ($candidate in @(
        (Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe')
        (Join-Path $env:ProgramFiles 'Inno Setup 6\ISCC.exe')
        # winget installs Inno Setup per-user by default, which is not on
        # either Program Files path.
        (Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 6\ISCC.exe')
    )) {
        if ($candidate -and (Test-Path $candidate)) { $IsccPath = $candidate; break }
    }
}

Write-Host ''
if (-not $IsccPath -or -not (Test-Path $IsccPath)) {
    Write-Host 'Inno Setup 6 was not found, so no installer was produced.' -ForegroundColor Yellow
    Write-Host 'Everything else passed. Install it from https://jrsoftware.org/isdl.php' -ForegroundColor Yellow
    Write-Host 'and run this again, or pass -IsccPath.' -ForegroundColor Yellow
    return
}

Write-Host "Compiling the installer with $IsccPath ..."
& $IsccPath (Join-Path $PSScriptRoot 'BrowserLocker.iss')
if ($LASTEXITCODE -ne 0) { throw "Inno Setup failed (exit $LASTEXITCODE)." }

Write-Host ''
Write-Host 'Build complete.' -ForegroundColor Green
Get-ChildItem -Path $dist -Filter '*.exe' | ForEach-Object {
    Write-Host ('  {0}  ({1:N2} MB)' -f $_.Name, ($_.Length / 1MB))
}

Write-Host ''
Write-Host 'Before distributing this, read the signing note in build\SIGNING.md.' -ForegroundColor Yellow
Write-Host 'An unsigned installer that relocates a browser profile WILL be flagged' -ForegroundColor Yellow
Write-Host 'by SmartScreen and antivirus.' -ForegroundColor Yellow
