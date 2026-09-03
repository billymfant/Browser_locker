<#
    Proves Unlock-BraveLockerPermanently.ps1 actually works, against a real
    BitLocker-encrypted vault built for the purpose.

    Nothing here touches the user's vault, profile, shortcuts or config. It
    builds its own encrypted VHDX, its own fake profile, and its own
    LOCALAPPDATA, and points the script under test at those.

    The script under test is NOT modified. Only two things are substituted, and
    both are genuine external dependencies rather than logic:
      - the passphrase dialog, stubbed to return a known passphrase
      - stdin, fed with the "OFF" confirmation the script demands

    Must be run elevated: BitLocker and VHDX attach both require it.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Resolved from this file's location: tests\manual\ -> repo root.
$repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$scratch = Join-Path $env:TEMP ('brave-locker-escape-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $scratch -Force | Out-Null
$sandbox = Join-Path $scratch 'escape'
$passphrase = 'test-passphrase-not-the-real-one'

function Write-Check {
    param([string]$Name, [bool]$Ok, [string]$Detail = '')
    $mark = if ($Ok) { 'PASS' } else { 'FAIL' }
    $colour = if ($Ok) { 'Green' } else { 'Red' }
    Write-Host ("  [{0}] {1}" -f $mark, $Name) -ForegroundColor $colour
    if ($Detail) { Write-Host "         $Detail" -ForegroundColor DarkGray }
    $Ok
}

$results = New-Object System.Collections.Generic.List[bool]

# --- Build the sandbox ------------------------------------------------------
if (Test-Path $sandbox) { Remove-Item $sandbox -Recurse -Force }
New-Item -ItemType Directory -Path $sandbox -Force | Out-Null

Copy-Item (Join-Path $repo 'src') (Join-Path $sandbox 'src') -Recurse -Force
Copy-Item (Join-Path $repo 'scripts') (Join-Path $sandbox 'scripts') -Recurse -Force

# Stub ONLY the passphrase dialog. Everything else is the real module.
$ui = Get-Content (Join-Path $repo 'src\BraveLocker\Ui.ps1') -Raw
$ui += @"

# --- TEST STUB -------------------------------------------------------------
function Show-BraveLockerPassphrasePrompt {
    param([string]`$Title = '', [string]`$IconSource = '', [string]`$Note = '')
    ConvertTo-BraveLockerSecureString -Text '$passphrase'
}
"@
Set-Content -Path (Join-Path $sandbox 'src\BraveLocker\Ui.ps1') -Value $ui -Encoding utf8

$testVhdx = Join-Path $sandbox 'testvault.vhdx'
$profileDir = Join-Path $sandbox 'BrowserProfile'
$fakeLocal = Join-Path $sandbox 'localappdata'
$stateRoot = Join-Path $fakeLocal 'BraveLocker'
New-Item -ItemType Directory -Path $stateRoot -Force | Out-Null

Write-Host ''
Write-Host 'Building a real encrypted test vault' -ForegroundColor Cyan

# --- Create, attach, format ------------------------------------------------
$dp = Join-Path $sandbox 'make.txt'
@(
    "create vdisk file=`"$testVhdx`" maximum=256 type=expandable"
    "select vdisk file=`"$testVhdx`""
    "attach vdisk"
    "create partition primary"
    "format fs=ntfs quick label=TESTVAULT"
    "exit"
) | Set-Content -Path $dp -Encoding ascii
& diskpart.exe /s $dp | Out-Null
Start-Sleep -Seconds 2

$part = Get-DiskImage -ImagePath $testVhdx | Get-Disk | Get-Partition |
    Where-Object { $_.Type -ne 'Reserved' } | Select-Object -First 1
$letter = $part.DriveLetter
if (-not $letter) {
    Add-PartitionAccessPath -DiskNumber $part.DiskNumber -PartitionNumber $part.PartitionNumber -AssignDriveLetter
    Start-Sleep -Seconds 2
    $part = Get-DiskImage -ImagePath $testVhdx | Get-Disk | Get-Partition |
        Where-Object { $_.Type -ne 'Reserved' } | Select-Object -First 1
    $letter = $part.DriveLetter
}
Write-Host "  test vault mounted at ${letter}:"

# --- Put a believable profile inside it ------------------------------------
Set-Content -Path "${letter}:\Local State" -Value '{"test":"profile"}' -Encoding utf8
New-Item -ItemType Directory -Path "${letter}:\Default" -Force | Out-Null
Set-Content -Path "${letter}:\Default\Preferences" -Value '{"pref":1}' -Encoding utf8
Set-Content -Path "${letter}:\Default\CANARY.txt" -Value 'this must survive the round trip' -Encoding utf8
1..30 | ForEach-Object { Set-Content -Path "${letter}:\Default\file$_.dat" -Value "payload $_" -Encoding utf8 }
$expectedCount = @(Get-ChildItem "${letter}:\" -Recurse -Force).Count
Write-Host "  wrote a fake profile: $expectedCount items"

# --- Encrypt it -------------------------------------------------------------
Write-Host '  encrypting with BitLocker...'
$secure = ConvertTo-SecureString -String $passphrase -AsPlainText -Force
Enable-BitLocker -MountPoint "${letter}:" -PasswordProtector -Password $secure `
    -EncryptionMethod Aes128 -UsedSpaceOnly -SkipHardwareTest -ErrorAction Stop | Out-Null

do {
    Start-Sleep -Seconds 2
    $bl = Get-BitLockerVolume -MountPoint "${letter}:"
    Write-Host "    $($bl.VolumeStatus) $($bl.EncryptionPercentage)%"
} while ($bl.VolumeStatus -eq 'EncryptionInProgress')

Dismount-DiskImage -ImagePath $testVhdx | Out-Null
Write-Host '  vault sealed and detached'

# --- A shortcut for the script to restore ----------------------------------
$backupDir = Join-Path $stateRoot 'shortcut-backup'
New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
$shortcut = Join-Path $sandbox 'TestBrowser.lnk'
$shell = New-Object -ComObject WScript.Shell
$lnk = $shell.CreateShortcut($shortcut)
$lnk.TargetPath = 'C:\Windows\System32\notepad.exe'   # stands in for the browser
$lnk.Save()
Copy-Item $shortcut (Join-Path $backupDir 'TestBrowser.original.lnk') -Force

Import-Module (Join-Path $repo 'src\BraveLocker\BraveLocker.psd1') -Force
$backupPath = Get-BraveLockerShortcutBackupPath -ShortcutPath $shortcut -BackupDir $backupDir
Copy-Item $shortcut $backupPath -Force
ConvertTo-Json -InputObject ([string[]]@($shortcut)) | Set-Content -Path (Join-Path $backupDir 'shortcuts.json') -Encoding utf8

# Now hijack the shortcut, so restoring it is observable.
$lnk = $shell.CreateShortcut($shortcut)
$lnk.TargetPath = 'C:\Windows\System32\wscript.exe'
$lnk.Save()

# --- The fake config --------------------------------------------------------
@{
    VhdxPath         = $testVhdx
    ProfileMountPath = $profileDir
    BrowserExe       = 'C:\Windows\System32\notepad.exe'
    BrowserExeName   = 'notarealbrowser.exe'
    BrowserName      = 'TestBrowser'
    InstallRoot      = $sandbox
    AppLocked        = $true
} | ConvertTo-Json | Set-Content -Path (Join-Path $stateRoot 'config.json') -Encoding utf8

# --- Run the script under test ---------------------------------------------
Write-Host ''
Write-Host 'Running Unlock-BraveLockerPermanently.ps1 for real' -ForegroundColor Cyan
Write-Host '---------------------------------------------------'

$script = Join-Path $sandbox 'scripts\Unlock-BraveLockerPermanently.ps1'

$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = 'powershell.exe'
$psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$script`" -Elevated"
$psi.UseShellExecute = $false
$psi.RedirectStandardInput = $true
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true
$psi.EnvironmentVariables['LOCALAPPDATA'] = $fakeLocal

$proc = [System.Diagnostics.Process]::Start($psi)
$proc.StandardInput.WriteLine('OFF')     # the confirmation it demands
$proc.StandardInput.WriteLine('')        # the final "press Enter"
$proc.StandardInput.Close()
$out = $proc.StandardOutput.ReadToEnd()
$err = $proc.StandardError.ReadToEnd()
$proc.WaitForExit()

$out -split "`r?`n" | ForEach-Object { if ($_.Trim()) { Write-Host "  | $_" -ForegroundColor DarkGray } }
if ($err.Trim()) {
    Write-Host '  STDERR:' -ForegroundColor Yellow
    $err -split "`r?`n" | ForEach-Object { if ($_.Trim()) { Write-Host "  ! $_" -ForegroundColor Yellow } }
}

# --- Verify -----------------------------------------------------------------
Write-Host ''
Write-Host 'Checks' -ForegroundColor Cyan

$results.Add((Write-Check 'the profile is back as an ordinary folder' (Test-Path $profileDir) $profileDir))

$canary = Join-Path $profileDir 'Default\CANARY.txt'
$results.Add((Write-Check 'the actual file contents survived' `
    ((Test-Path $canary) -and ((Get-Content $canary -Raw) -match 'must survive')) ))

if (Test-Path $profileDir) {
    $got = @(Get-ChildItem $profileDir -Recurse -Force).Count
    $results.Add((Write-Check 'everything came out of the vault' ($got -ge $expectedCount) `
        "expected at least $expectedCount items, found $got"))
} else { $results.Add((Write-Check 'everything came out of the vault' $false)) }

$results.Add((Write-Check 'the folder is NOT a mount point any more' `
    ((Test-Path $profileDir) -and -not ((Get-Item $profileDir -Force).Attributes -band [System.IO.FileAttributes]::ReparsePoint)) ))

$results.Add((Write-Check 'THE VAULT WAS NOT DELETED' (Test-Path $testVhdx) $testVhdx))

$results.Add((Write-Check 'the vault is detached afterwards' `
    (-not (Get-DiskImage -ImagePath $testVhdx -ErrorAction SilentlyContinue).Attached) ))

$restoredTarget = $shell.CreateShortcut($shortcut).TargetPath
$results.Add((Write-Check 'the original shortcut was restored' `
    ($restoredTarget -match 'notepad\.exe$') "target is now: $restoredTarget"))

$results.Add((Write-Check 'the config was stood down, not deleted' `
    ((-not (Test-Path (Join-Path $stateRoot 'config.json'))) -and
     (@(Get-ChildItem $stateRoot -Filter 'config.turned-off-*.json').Count -eq 1)) ))

# The vault must still be genuinely encrypted - not quietly left open.
$stillEncrypted = $false
try {
    Mount-DiskImage -ImagePath $testVhdx -ErrorAction Stop | Out-Null
    Start-Sleep -Seconds 2
    $p2 = Get-DiskImage -ImagePath $testVhdx | Get-Disk | Get-Partition |
        Where-Object { $_.Type -ne 'Reserved' } | Select-Object -First 1
    if ($p2.DriveLetter) {
        $bl2 = Get-BitLockerVolume -MountPoint "$($p2.DriveLetter):" -ErrorAction SilentlyContinue
        $stillEncrypted = $bl2 -and $bl2.LockStatus -eq 'Locked'
        if (-not $stillEncrypted -and $bl2) { $stillEncrypted = $bl2.VolumeStatus -match 'Encrypted' }
    } else {
        $stillEncrypted = $true   # no letter assigned because the volume is locked
    }
    Dismount-DiskImage -ImagePath $testVhdx | Out-Null
} catch {
    Write-Host "    (re-check failed: $($_.Exception.Message))" -ForegroundColor DarkGray
}
$results.Add((Write-Check 'the leftover vault is still encrypted' $stillEncrypted))

# --- Clean up ---------------------------------------------------------------
Dismount-DiskImage -ImagePath $testVhdx -ErrorAction SilentlyContinue | Out-Null

Write-Host ''
$passed = @($results | Where-Object { $_ }).Count
$total = $results.Count
Write-Host ("VERDICT: {0}/{1} checks passed" -f $passed, $total) `
    -ForegroundColor $(if ($passed -eq $total) { 'Green' } else { 'Red' })
Write-Host ''
Write-Host 'Cleaning up the sandbox...'
Start-Sleep -Seconds 2
Remove-Item $scratch -Recurse -Force -ErrorAction SilentlyContinue
Write-Host "sandbox removed: $(-not (Test-Path $scratch))"
