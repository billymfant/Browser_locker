#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
    One-time setup. Creates the encrypted vault, moves the Brave profile into it,
    installs a protected copy of the tool, and registers the elevated mount helper.

    The installed copy lives under Program Files because the scheduled task runs
    its script with administrator rights: if a non-administrator could write to
    that location, they could replace the script and run code as admin. Program
    Files already carries the right ACL, and it leaves the working folder editable.
#>
[CmdletBinding()]
param(
    [string]$VhdxPath = 'D:\apps\brave_locker\vault.vhdx',
    [int]$MaximumSizeMB = 32768,
    [string]$BraveExe = 'C:\Program Files\BraveSoftware\Brave-Browser\Application\brave.exe',
    [string]$SourceProfilePath = (Join-Path $env:LOCALAPPDATA 'BraveSoftware\Brave-Browser\User Data'),
    [string]$InstallRoot = 'C:\Program Files\BraveLocker'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $repoRoot 'src\BraveLocker\BraveLocker.psd1') -Force

function Read-BraveLockerPlainText {
    param([Parameter(Mandatory)][securestring]$Secure)

    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
    try {
        [Runtime.InteropServices.Marshal]::PtrToStringUni($bstr)
    } finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
}

Write-Host ''
Write-Host 'Brave Locker setup' -ForegroundColor Cyan
Write-Host '=================='
Write-Host ''

# --- 1. Preconditions -------------------------------------------------------
if (-not (Test-Path $BraveExe))          { throw "Brave was not found at '$BraveExe'." }
if (-not (Test-Path $SourceProfilePath)) { throw "No Brave profile found at '$SourceProfilePath'." }
if (Test-Path $VhdxPath)                 { throw "A vault already exists at '$VhdxPath'. Delete it first if you truly want to start over." }

if (@(Get-Process -Name 'brave' -ErrorAction SilentlyContinue).Count -gt 0) {
    throw 'Close Brave completely before running setup, so the profile is copied in a consistent state.'
}

# --- 2. Passphrase ----------------------------------------------------------
Write-Host 'Your passphrase is the only thing standing between someone with this PC'
Write-Host 'and your accounts. Anyone who copies the vault file can attack it offline,'
Write-Host 'where the lockout cannot reach them, so length matters more than cleverness.'
Write-Host 'A few unrelated words you will actually remember beats a short cryptic one.'
Write-Host ''

$passphrase = $null
while ($null -eq $passphrase) {
    $first = Read-Host -Prompt 'Choose a vault passphrase (at least 8 characters)' -AsSecureString
    $again = Read-Host -Prompt 'Type it again' -AsSecureString

    $plainFirst = Read-BraveLockerPlainText -Secure $first
    $plainAgain = Read-BraveLockerPlainText -Secure $again

    if ($plainFirst -ne $plainAgain) {
        Write-Host 'Those did not match. Try again.' -ForegroundColor Yellow
        continue
    }

    $check = Test-BraveLockerPassphrase -Passphrase $plainFirst
    if (-not $check.IsValid) {
        if ($check.Reason -eq 'TooShort') {
            Write-Host ('Too short - {0} characters. The minimum is 8.' -f $plainFirst.Length) -ForegroundColor Yellow
        } else {
            Write-Host 'Padding with spaces does not count. Use at least 8 real characters.' -ForegroundColor Yellow
        }
        continue
    }

    if ($check.IsWeak) {
        Write-Host ''
        Write-Host ('{0} characters is usable but short.' -f $plainFirst.Length) -ForegroundColor Yellow
        Write-Host 'It will stop someone opening Brave at your desk. It will not hold up if'
        Write-Host 'someone copies the vault file and attacks it offline with cracking software.'
        Write-Host 'Twelve or more closes that gap.' -ForegroundColor Yellow
        Write-Host ''
        $accept = Read-Host 'Use it anyway? (y/N)'
        if ($accept -ne 'y') { continue }
    }

    $passphrase = $first
}
Remove-Variable plainFirst, plainAgain -ErrorAction SilentlyContinue

# --- 3. Install a protected copy of the tool --------------------------------
Write-Host ''
Write-Host "Installing the tool to $InstallRoot ..."
foreach ($sub in 'src', 'scripts') {
    $target = Join-Path $InstallRoot $sub
    if (Test-Path $target) { Remove-Item -Path $target -Recurse -Force }
    New-Item -ItemType Directory -Path $target -Force | Out-Null
    Copy-Item -Path (Join-Path $repoRoot "$sub\*") -Destination $target -Recurse -Force
}
Set-BraveLockerScriptAcl -Path $InstallRoot
# Set-BraveLockerScriptAcl throws unless it has read the ACL back and confirmed
# it, so reaching this line means the permissions were actually verified.
Write-Host 'Verified: the installed copy is writable only by administrators.'

# --- 4. Create and encrypt the vault ---------------------------------------
$letter = Get-BraveLockerFreeDriveLetter -Preferred 'V'
$mount = "${letter}:"

Write-Host ''
Write-Host "Creating the vault at $VhdxPath (drive $mount) ..."
New-BraveLockerVault -VhdxPath $VhdxPath -MaximumSizeMB $MaximumSizeMB -DriveLetter $letter

Write-Host 'Encrypting it with BitLocker. This is quick because the vault is still empty.'
Enable-BitLocker -MountPoint $mount -PasswordProtector -Password $passphrase `
    -EncryptionMethod XtsAes256 -UsedSpaceOnly -ErrorAction Stop | Out-Null

$deadline = (Get-Date).AddMinutes(5)
while ((Get-Date) -lt $deadline) {
    $status = Get-BitLockerVolume -MountPoint $mount
    if ($status.VolumeStatus -eq 'FullyEncrypted') { break }
    Start-Sleep -Seconds 2
}

$recovery = Add-BitLockerKeyProtector -MountPoint $mount -RecoveryPasswordProtector -ErrorAction Stop
$recoveryKey = ($recovery.KeyProtector |
    Where-Object { $_.KeyProtectorType -eq 'RecoveryPassword' } |
    Select-Object -Last 1).RecoveryPassword

# --- 5. Recovery key: shown once, never written to disk ---------------------
Write-Host ''
Write-Host 'RECOVERY KEY - write this down now' -ForegroundColor Red
Write-Host ''
Write-Host "    $recoveryKey" -ForegroundColor White
Write-Host ''
Write-Host 'This is deliberately not saved anywhere on this PC. A recovery key sitting'
Write-Host 'on the machine would let anyone who finds it open the vault, which defeats'
Write-Host 'the whole point. Put it on your phone or in a password manager.'
Write-Host 'If you lose both the passphrase and this key, the profile is gone for good.'
Write-Host ''

$confirm = Read-Host 'Type STORED once you have saved it somewhere off this PC'
if ($confirm -ne 'STORED') {
    Dismount-BraveLockerVault -VhdxPath $VhdxPath
    Remove-Item -Path $VhdxPath -Force -ErrorAction SilentlyContinue
    throw 'Setup cancelled and the vault deleted, because the recovery key was not stored. Your Brave profile was not touched.'
}
Clear-Variable recoveryKey

# --- 6. Migrate the profile -------------------------------------------------
$profilePath = Join-Path $mount 'BraveProfile'
Write-Host ''
Write-Host 'Copying your Brave profile into the vault. Around 1.2 GB, so give it a minute.'
New-Item -ItemType Directory -Path $profilePath -Force | Out-Null

& robocopy.exe $SourceProfilePath $profilePath /E /R:1 /W:1 /NFL /NDL /NJH /NJS | Out-Null
$robocopyExit = $LASTEXITCODE
if ($robocopyExit -ge 8) {
    throw "robocopy reported errors (exit $robocopyExit). The vault is left in place for inspection; your original profile is untouched."
}

$sourceCount = @(Get-ChildItem -Path $SourceProfilePath -Recurse -File -ErrorAction SilentlyContinue).Count
$vaultCount  = @(Get-ChildItem -Path $profilePath -Recurse -File -ErrorAction SilentlyContinue).Count
Write-Host "Verification: $sourceCount files in the original, $vaultCount in the vault."

$migrationClean = $true
if ($vaultCount -lt $sourceCount) {
    $migrationClean = $false
    Write-Host 'Fewer files arrived than were sent. Your original profile is untouched - do NOT run the cleanup script until this is understood.' -ForegroundColor Yellow
}

# --- 7. Register the elevated helper ---------------------------------------
$installedTaskScript = Join-Path $InstallRoot 'scripts\Invoke-BraveLockerVaultTask.ps1'
Register-BraveLockerMountTask -ScriptPath $installedTaskScript
Write-Host 'Registered the mount helper, so launching Brave will not prompt for UAC.'

# --- 8. Save config ---------------------------------------------------------
$paths = Get-BraveLockerPaths
if (-not (Test-Path $paths.StateRoot)) {
    New-Item -ItemType Directory -Path $paths.StateRoot -Force | Out-Null
}
[pscustomobject]@{
    VhdxPath             = $VhdxPath
    ProfileDirName       = 'BraveProfile'
    BraveExe             = $BraveExe
    PreferredDriveLetter = $letter
    SourceProfilePath    = $SourceProfilePath
    InstallRoot          = $InstallRoot
} | ConvertTo-Json -Depth 5 | Set-Content -Path $paths.ConfigPath -Encoding utf8

# --- 9. Seal up and create the shortcut ------------------------------------
Lock-BitLocker -MountPoint $mount -ErrorAction SilentlyContinue | Out-Null
Dismount-BraveLockerVault -VhdxPath $VhdxPath

New-BraveLockerShortcut -InstallRoot $InstallRoot -BraveExe $BraveExe -AlsoStartMenu | Out-Null

Write-Host ''
Write-Host 'Setup complete.' -ForegroundColor Green
Write-Host ''
Write-Host 'Next, and this part matters:' -ForegroundColor Yellow
Write-Host '  1. Open "Brave (Private)" on your desktop.'
Write-Host '  2. Check Facebook, your email and brave://settings/payments for your cards.'
if ($migrationClean) {
    Write-Host '  3. Once satisfied, run Complete-BraveLockerMigration.ps1.'
} else {
    Write-Host '  3. The file counts did not match - work out why before running the cleanup script.' -ForegroundColor Yellow
}
Write-Host ''
Write-Host 'Until step 3 is done, your ORIGINAL unprotected profile is still on disk' -ForegroundColor Yellow
Write-Host 'and this tool is protecting nothing.' -ForegroundColor Yellow
