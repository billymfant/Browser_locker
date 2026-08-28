#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
    One-time setup. Creates the encrypted vault, moves the Brave profile into
    it, installs a protected copy of the tool, and registers the elevated mount
    helper.

    The vault is mounted onto Brave's OWN profile folder rather than the profile
    being copied somewhere else. That is not a stylistic choice. Brave's
    App-Bound Encryption ties cookies and saved passwords to the profile path,
    so a profile opened from any other path decrypts nothing and every account
    appears logged out. Keeping the path identical is the whole trick.

    The installed copy lives under Program Files because the scheduled task runs
    its script with administrator rights: if a non-administrator could write to
    that location, they could replace the script and run code as admin. Program
    Files already carries the right ACL, and it leaves the working folder editable.
#>
[CmdletBinding()]
param(
    # All of these are discovered on the machine setup is running on when left
    # empty. Nothing here may default to a path that happened to exist on the
    # developer's PC - this script has to work on a computer with no D: drive
    # and a browser installed somewhere unexpected.
    [string]$BrowserId = 'brave',
    [string]$VhdxPath = '',
    [int]$MaximumSizeMB = 0,
    [string]$BraveExe = '',
    [string]$ProfileMountPath = '',
    [string]$InstallRoot = (Join-Path $env:ProgramFiles 'BraveLocker'),
    # A file holding the passphrase DPAPI-protected under this account, as
    # written by ConvertFrom-SecureString. Used instead of the popup so the
    # stored passphrase cannot be altered by whatever keyboard layout happens
    # to be active. The file is deleted as soon as it has been read.
    [string]$PassphraseFile = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $repoRoot 'src\BraveLocker\BraveLocker.psd1') -Force

# --- 0. Work out where everything is on THIS machine ------------------------
$browser = Get-BraveLockerBrowserById -Id $BrowserId
if ($null -eq $browser) {
    $known = ((Get-BraveLockerBrowserCatalog | ForEach-Object { $_.Id }) -join ', ')
    throw "Unknown browser '$BrowserId'. Known browsers: $known"
}
if (-not $browser.IsSupported) {
    throw "$($browser.Name) is not supported yet. $($browser.Note)"
}

if (-not $BraveExe)         { $BraveExe = Get-BraveLockerBrowserExePath -Browser $browser }
if (-not $ProfileMountPath) { $ProfileMountPath = Get-BraveLockerBrowserProfileRoot -Browser $browser }

if (-not $BraveExe) {
    throw "$($browser.Name) could not be found on this PC. Install it first, or pass -BraveExe."
}

$profileState = Test-BraveLockerProfileUsable -Path $ProfileMountPath
if (-not $profileState.IsUsable) {
    throw "No usable $($browser.Name) profile at '$ProfileMountPath' ($($profileState.Reason)). Open $($browser.Name) once, then run setup again."
}

if (-not $MaximumSizeMB) {
    $MaximumSizeMB = Get-BraveLockerVaultSizeMB -ProfileSizeBytes $profileState.SizeBytes
}

if (-not $VhdxPath) {
    $needed = [int64]($profileState.SizeBytes * 2) + 1GB
    $vaultDrive = Select-BraveLockerVaultDrive -Volume @(Get-Volume -ErrorAction SilentlyContinue) -RequiredBytes $needed
    if (-not $vaultDrive) {
        throw 'No NTFS drive has enough free space for the vault. Free some space, or pass -VhdxPath.'
    }
    $VhdxPath = Get-BraveLockerDefaultVaultPath -DriveLetter $vaultDrive
}

$preMigrationPath = "$ProfileMountPath.premigration"

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
Write-Host "Browser Locker setup - $($browser.Name)" -ForegroundColor Cyan
Write-Host '========================================'
Write-Host ''
# Built first, then printed: "Write-Host '...' -f x" binds -f to
# -ForegroundColor, not the format operator.
$profileLine = '  profile : {0}  ({1:N2} GB)' -f $ProfileMountPath, ($profileState.SizeBytes / 1GB)
$vaultLine   = '  vault   : {0}  (up to {1} GB)' -f $VhdxPath, [int]($MaximumSizeMB / 1024)
Write-Host "  browser : $BraveExe"
Write-Host $profileLine
Write-Host $vaultLine
Write-Host ''

# --- 1. Preconditions -------------------------------------------------------
if (Test-Path $VhdxPath)         { throw "A vault already exists at '$VhdxPath'. Delete it first if you truly want to start over." }
if (Test-Path $preMigrationPath) { throw "'$preMigrationPath' already exists. A previous setup left it behind - move it out of the way first." }

if (@(Get-Process -Name $browser.ProcessName -ErrorAction SilentlyContinue).Count -gt 0) {
    throw "Close $($browser.Name) completely before running setup, so the profile is copied in a consistent state."
}

# --- 2. Passphrase ----------------------------------------------------------
# Asked through the same popup the launcher uses, never through this console.
# A console window can be on a different keyboard layout than a dialog, so the
# same keys produce different characters - which silently sets a passphrase the
# popup can never reproduce. That happened on this machine.
Write-Host 'Your passphrase is the only thing standing between someone with this PC'
Write-Host 'and your accounts. Anyone who copies the vault file can attack it offline,'
Write-Host 'where the lockout cannot reach them, so length matters more than cleverness.'
Write-Host 'A few unrelated words you will actually remember beats a short cryptic one.'
Write-Host ''
Write-Host 'A popup will ask for it - type it THERE, not in this window.' -ForegroundColor Yellow
Write-Host ''

$passphrase = $null

if ($PassphraseFile) {
    if (-not (Test-Path $PassphraseFile)) {
        throw "No passphrase file at '$PassphraseFile'."
    }
    $blob = (Get-Content -Path $PassphraseFile -Raw).Trim()
    $passphrase = ConvertTo-SecureString -String $blob -ErrorAction Stop
    Remove-Item -Path $PassphraseFile -Force -ErrorAction SilentlyContinue
    Remove-Variable blob

    $plainSupplied = Read-BraveLockerPlainText -Secure $passphrase
    $suppliedCheck = Test-BraveLockerPassphrase -Passphrase $plainSupplied
    if (-not $suppliedCheck.IsValid) {
        throw "The supplied passphrase is not usable ($($suppliedCheck.Reason))."
    }
    Write-Host ('Passphrase supplied directly ({0} characters) - no keyboard involved.' -f $plainSupplied.Length) -ForegroundColor Green
    Remove-Variable plainSupplied
}

while ($null -eq $passphrase) {
    $first = Show-BraveLockerPassphrasePrompt -Title 'Brave Locker setup' `
        -Prompt 'Choose a vault passphrase (at least 8 characters)' `
        -Note 'A few unrelated words beats a short cryptic one.'
    if ($null -eq $first) { throw 'Setup cancelled. Nothing was changed.' }

    $again = Show-BraveLockerPassphrasePrompt -Title 'Brave Locker setup' `
        -Prompt 'Type it again to confirm'
    if ($null -eq $again) { throw 'Setup cancelled. Nothing was changed.' }

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

    Write-Host ('Passphrase accepted ({0} characters).' -f $plainFirst.Length) -ForegroundColor Green
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
Write-Host "Creating the vault at $VhdxPath (temporarily on $mount) ..."
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
Write-Host 'Do not paste it into a chat window either - it opens the vault on its own,'
Write-Host 'without your passphrase.'
Write-Host 'If you lose both the passphrase and this key, the profile is gone for good.'
Write-Host ''

$confirm = Read-Host 'Type STORED once you have saved it somewhere off this PC'
if ($confirm -ne 'STORED') {
    Lock-BitLocker -MountPoint $mount -ErrorAction SilentlyContinue | Out-Null
    Dismount-BraveLockerVault -VhdxPath $VhdxPath
    Remove-Item -Path $VhdxPath -Force -ErrorAction SilentlyContinue
    throw 'Setup cancelled and the vault deleted, because the recovery key was not stored. Your Brave profile was not touched.'
}
Clear-Variable recoveryKey

# --- 5b. Prove the passphrase can be RETYPED -------------------------------
# Verifying the vault opens with the SecureString already held in memory proves
# nothing about whether the user can reproduce it. On a machine with more than
# one keyboard layout the same keys produce different characters - "correct-horse-battery"
# typed on a Greek layout is "σορρεχτ-ηορσε-βαττερυ" - so a passphrase can be stored,
# confirmed twice, and still be untypeable afterwards. That happened here, three
# times, and each time setup reported success.
#
# So the vault is sealed and reopened with a freshly typed passphrase before any
# data goes into it. If that cannot be done, the vault is useless and is deleted
# now rather than after the profile has been migrated into it.
Write-Host ''
Write-Host 'Checking you can actually type that passphrase' -ForegroundColor Cyan
Write-Host '---------------------------------------------'
Write-Host 'The vault is about to be sealed and reopened with what you type, so a'
Write-Host 'passphrase that cannot be reproduced is caught now rather than later.'
Write-Host ''

Lock-BitLocker -MountPoint $mount -ErrorAction SilentlyContinue | Out-Null

$typedOk = $false
for ($attempt = 1; $attempt -le 3 -and -not $typedOk; $attempt++) {
    $typed = Show-BraveLockerPassphrasePrompt -Title 'Brave Locker setup' `
        -Prompt "Type your passphrase to confirm (attempt $attempt of 3)" `
        -Note 'This must be typed, not remembered - it is the real test.'
    if ($null -eq $typed) {
        Dismount-BraveLockerVault -VhdxPath $VhdxPath
        Remove-Item -Path $VhdxPath -Force -ErrorAction SilentlyContinue
        throw 'Setup cancelled at the passphrase check, and the vault deleted. Your Brave profile was not touched.'
    }

    $plainTyped = Read-BraveLockerPlainText -Secure $typed
    $nonAscii = @($plainTyped.ToCharArray() | Where-Object { [int]$_ -gt 127 }).Count
    $typedLength = $plainTyped.Length
    Remove-Variable plainTyped

    if (Unlock-BraveLockerVault -MountPoint $mount -Passphrase $typed) {
        $typedOk = $true
        Write-Host '  Confirmed - the passphrase you typed opens the vault.' -ForegroundColor Green
        break
    }

    Write-Host ''
    Write-Host ("  Rejected. What you typed was $typedLength characters, $nonAscii of them non-ASCII.") -ForegroundColor Yellow
    if ($nonAscii -gt 0) {
        Write-Host ''
        Write-Host '  Your keyboard is producing non-English characters.' -ForegroundColor Red
        Write-Host '  Press Alt+Shift (or Win+Space) to switch to the English layout,' -ForegroundColor Yellow
        Write-Host '  check the language indicator by the clock says ENG, and try again.' -ForegroundColor Yellow
    } else {
        Write-Host '  Those are ordinary characters, so this looks like a typo.' -ForegroundColor Yellow
    }
    Write-Host ''
}

if (-not $typedOk) {
    Dismount-BraveLockerVault -VhdxPath $VhdxPath
    Remove-Item -Path $VhdxPath -Force -ErrorAction SilentlyContinue
    throw 'The passphrase could not be typed back correctly, so the vault was deleted rather than left unopenable. Your Brave profile was not touched.'
}

# --- 6. Copy the profile to the VAULT ROOT ---------------------------------
# Root, not a subfolder: the vault gets mounted onto Brave's profile folder, so
# the volume root has to BE that folder's contents.
Write-Host ''
Write-Host 'Copying your Brave profile into the vault. Around 1.2 GB, so give it a minute.'

& robocopy.exe $ProfileMountPath "$mount\" /E /R:1 /W:1 /NFL /NDL /NJH /NJS | Out-Null
$robocopyExit = $LASTEXITCODE
if ($robocopyExit -ge 8) {
    throw "robocopy reported errors (exit $robocopyExit). The vault is left in place for inspection; your original profile is untouched."
}

$sourceCount = @(Get-ChildItem -Path $ProfileMountPath -Recurse -File -ErrorAction SilentlyContinue).Count
# System Volume Information belongs to the volume, not to Brave, so it is not
# part of the comparison.
$vaultCount = @(Get-ChildItem -Path "$mount\" -Recurse -File -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -notmatch '\\System Volume Information\\' }).Count
Write-Host "Verification: $sourceCount files in the original, $vaultCount in the vault."

if ($vaultCount -lt $sourceCount) {
    Lock-BitLocker -MountPoint $mount -ErrorAction SilentlyContinue | Out-Null
    Dismount-BraveLockerVault -VhdxPath $VhdxPath
    Remove-Item -Path $VhdxPath -Force -ErrorAction SilentlyContinue
    throw "Only $vaultCount of $sourceCount files arrived in the vault. Setup stopped and the vault deleted. Your original profile is untouched."
}

Lock-BitLocker -MountPoint $mount -ErrorAction SilentlyContinue | Out-Null
Dismount-BraveLockerVault -VhdxPath $VhdxPath

# --- 7. Put the vault where Brave looks ------------------------------------
# The original is RENAMED, never deleted. It stays as the rollback until the
# user has confirmed the vaulted Brave really does have their logins.
Write-Host ''
Write-Host 'Moving your original profile aside (renamed, not deleted)...'
Rename-Item -Path $ProfileMountPath -NewName (Split-Path -Leaf $preMigrationPath) -ErrorAction Stop
New-Item -ItemType Directory -Path $ProfileMountPath -Force | Out-Null
Write-Host "  original kept at: $preMigrationPath"

# --- 8. Save config ---------------------------------------------------------
$paths = Get-BraveLockerPaths
if (-not (Test-Path $paths.StateRoot)) {
    New-Item -ItemType Directory -Path $paths.StateRoot -Force | Out-Null
}
Save-BraveLockerConfig -VhdxPath $VhdxPath -ProfileMountPath $ProfileMountPath `
    -PreMigrationPath $preMigrationPath -BraveExe $BraveExe -InstallRoot $InstallRoot `
    -BrowserId $browser.Id -BrowserName $browser.Name -BrowserExeName $browser.ExeName | Out-Null

# --- 9. Register the elevated helper ---------------------------------------
$installedTaskScript = Join-Path $InstallRoot 'scripts\Invoke-BraveLockerVaultTask.ps1'
Register-BraveLockerMountTask -ScriptPath $installedTaskScript
Write-Host 'Registered the mount helper, so launching Brave will not prompt for UAC.'

# --- 10. Prove the mount works before claiming success ---------------------
Write-Host ''
Write-Host 'Checking the vault really does mount onto Brave''s profile folder...'
Mount-DiskImage -ImagePath $VhdxPath -StorageType VHDX -ErrorAction Stop | Out-Null
$tempLetter = Add-BraveLockerVaultDriveLetter -VhdxPath $VhdxPath

if (-not (Unlock-BraveLockerVault -MountPoint $tempLetter -Passphrase $passphrase)) {
    Dismount-BraveLockerVault -VhdxPath $VhdxPath
    throw 'The vault would not unlock with the passphrase just set. Setup stopped; your original profile is at ' + $preMigrationPath
}

Set-BraveLockerVaultAccessPath -VhdxPath $VhdxPath -AccessPath $ProfileMountPath
Remove-BraveLockerVaultDriveLetter -VhdxPath $VhdxPath -DriveLetter $tempLetter

$localState = Join-Path $ProfileMountPath 'Local State'
$mountVerified = Test-Path $localState

Remove-BraveLockerVaultAccessPath -VhdxPath $VhdxPath -AccessPath $ProfileMountPath
Dismount-BraveLockerVault -VhdxPath $VhdxPath

if (-not $mountVerified) {
    throw "The vault mounted but 'Local State' was not visible at $ProfileMountPath. Your original profile is at $preMigrationPath"
}
Write-Host '  verified: the vault mounts at Brave''s own profile path.' -ForegroundColor Green

# --- 11. Shortcut -----------------------------------------------------------
New-BraveLockerShortcut -InstallRoot $InstallRoot -BraveExe $BraveExe -AlsoStartMenu | Out-Null

Write-Host ''
Write-Host 'Setup complete.' -ForegroundColor Green
Write-Host ''
Write-Host 'Next, and this part matters:' -ForegroundColor Yellow
Write-Host '  1. Open Brave and enter your passphrase.'
Write-Host '  2. Check Facebook, your email and brave://settings/payments for your cards.'
Write-Host '     Your logins should ALL still be there. If they are not, stop and say so.'
Write-Host '  3. Once satisfied, run Complete-BraveLockerMigration.ps1.'
Write-Host ''
Write-Host 'Until step 3 is done, your ORIGINAL unprotected profile is still on disk at' -ForegroundColor Yellow
Write-Host "  $preMigrationPath" -ForegroundColor Yellow
Write-Host 'and this tool is protecting nothing. That copy is also your rollback.' -ForegroundColor Yellow
