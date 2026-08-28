# The setup work itself, split into stages so both the console script and the
# GUI wizard drive the same code. Neither owns the logic; neither prints.
#
# Every stage reports through -Progress, a scriptblock taking (percent, text),
# so the caller decides whether that becomes Write-Host or a progress bar.

function Invoke-BraveLockerProgress {
    [CmdletBinding()]
    param(
        [AllowNull()][scriptblock]$Progress,
        [int]$Percent,
        [string]$Text
    )

    if ($null -ne $Progress) { & $Progress $Percent $Text }
}

function New-BraveLockerEncryptedVault {
    <#
        Creates the vault, encrypts it, and returns the recovery key.

        The key is returned to the caller and never written to disk - a recovery
        key stored on the machine would open the vault for anyone who finds it.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$VhdxPath,
        [Parameter(Mandatory)][int]$MaximumSizeMB,
        [Parameter(Mandatory)][securestring]$Passphrase,
        [string]$Provider = 'BitLocker',
        [AllowNull()][scriptblock]$Progress
    )

    if (Test-Path $VhdxPath) {
        throw "A vault already exists at '$VhdxPath'. Delete it first if you truly want to start over."
    }

    $letter = Get-BraveLockerFreeDriveLetter -Preferred 'V'
    $mount = "${letter}:"

    Invoke-BraveLockerProgress -Progress $Progress -Percent 10 -Text 'Creating the encrypted vault...'
    New-BraveLockerVault -VhdxPath $VhdxPath -MaximumSizeMB $MaximumSizeMB -DriveLetter $letter

    Invoke-BraveLockerProgress -Progress $Progress -Percent 25 -Text 'Encrypting it. This is quick while the vault is empty.'
    $recoveryKey = Protect-BraveLockerVolume -MountPoint $mount -Passphrase $Passphrase -Provider $Provider

    [pscustomobject]@{
        VhdxPath    = $VhdxPath
        DriveLetter = $letter
        MountPoint  = $mount
        RecoveryKey = $recoveryKey
    }
}

function Test-BraveLockerPassphraseRoundTrip {
    <#
        Seals the vault and reopens it with a passphrase the user has just
        TYPED. This is the check that was missing and cost three failed setups.

        Verifying against the SecureString already held in memory proves the
        vault works and says nothing about whether the passphrase can be
        reproduced. On a machine with more than one keyboard layout the same
        keys produce different characters, so a passphrase can be entered,
        confirmed against itself, stored, and be untypeable minutes later.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$MountPoint,
        [Parameter(Mandatory)][securestring]$Typed,
        [string]$Provider = 'BitLocker'
    )

    Lock-BraveLockerVolume -MountPoint $MountPoint -Provider $Provider

    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Typed)
    try {
        $plain = [Runtime.InteropServices.Marshal]::PtrToStringUni($bstr)
        $length = $plain.Length
        $nonAscii = @($plain.ToCharArray() | Where-Object { [int]$_ -gt 127 }).Count
    } finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }

    $unlocked = Unlock-BraveLockerVolume -MountPoint $MountPoint -Passphrase $Typed -Provider $Provider

    $hint = ''
    if (-not $unlocked) {
        if ($nonAscii -gt 0) {
            $hint = "Your keyboard produced $nonAscii non-English character(s). Switch to the English layout (Alt+Shift, or check the indicator by the clock says ENG) and try again."
        } else {
            $hint = 'Those are ordinary characters, so this looks like a typo rather than a keyboard layout problem.'
        }
    }

    [pscustomobject]@{
        Unlocked      = $unlocked
        TypedLength   = $length
        NonAsciiCount = $nonAscii
        Hint          = $hint
    }
}

function Invoke-BraveLockerProfileMigration {
    <#
        Copies the profile into the unlocked vault, moves the original aside,
        and leaves the vault mounted where Brave expects its profile.

        The original is RENAMED, never deleted. It is the rollback until the
        user has confirmed the vaulted Brave still has their logins - a check
        that has genuinely failed before.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$VhdxPath,
        [Parameter(Mandatory)][string]$MountPoint,
        [Parameter(Mandatory)][string]$ProfileMountPath,
        [AllowNull()][scriptblock]$Progress
    )

    $preMigrationPath = "$ProfileMountPath.premigration"
    if (Test-Path $preMigrationPath) {
        throw "'$preMigrationPath' already exists from an earlier setup. Move it out of the way first."
    }

    Invoke-BraveLockerProgress -Progress $Progress -Percent 45 -Text 'Copying your Brave profile into the vault...'

    & robocopy.exe $ProfileMountPath "$MountPoint\" /E /R:1 /W:1 /NFL /NDL /NJH /NJS | Out-Null
    $robocopyExit = $LASTEXITCODE
    if ($robocopyExit -ge 8) {
        throw "Copying the profile failed (robocopy exit $robocopyExit). Your original profile is untouched."
    }

    $sourceCount = @(Get-ChildItem -Path $ProfileMountPath -Recurse -File -ErrorAction SilentlyContinue).Count
    # System Volume Information belongs to the volume, not to Brave.
    $vaultCount = @(Get-ChildItem -Path "$MountPoint\" -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch '\\System Volume Information\\' }).Count

    Invoke-BraveLockerProgress -Progress $Progress -Percent 70 -Text "Verifying: $sourceCount files in, $vaultCount in the vault."

    if ($vaultCount -lt $sourceCount) {
        throw "Only $vaultCount of $sourceCount files reached the vault. Setup stopped; your original profile is untouched."
    }

    Invoke-BraveLockerProgress -Progress $Progress -Percent 78 -Text 'Sealing the vault...'
    Lock-BraveLockerVolume -MountPoint $MountPoint
    Dismount-BraveLockerVault -VhdxPath $VhdxPath

    Invoke-BraveLockerProgress -Progress $Progress -Percent 82 -Text 'Moving your original profile aside (renamed, not deleted)...'
    Rename-Item -Path $ProfileMountPath -NewName (Split-Path -Leaf $preMigrationPath) -ErrorAction Stop
    New-Item -ItemType Directory -Path $ProfileMountPath -Force | Out-Null

    [pscustomobject]@{
        PreMigrationPath = $preMigrationPath
        SourceCount      = $sourceCount
        VaultCount       = $vaultCount
    }
}

function Test-BraveLockerVaultMountsAtProfilePath {
    <#
        Proves the vault really does mount onto Brave's profile folder before
        setup claims success. Leaves the vault sealed either way.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$VhdxPath,
        [Parameter(Mandatory)][string]$ProfileMountPath,
        [Parameter(Mandatory)][securestring]$Passphrase
    )

    $verified = $false
    $detail = ''

    try {
        if (-not (Test-BraveLockerVaultMounted -VhdxPath $VhdxPath)) {
            Mount-DiskImage -ImagePath $VhdxPath -StorageType VHDX -ErrorAction Stop | Out-Null
        }
        $letter = Add-BraveLockerVaultDriveLetter -VhdxPath $VhdxPath

        if (-not (Unlock-BraveLockerVolume -MountPoint $letter -Passphrase $Passphrase)) {
            $detail = 'The vault would not unlock with the passphrase that was just set.'
        } else {
            Set-BraveLockerVaultAccessPath -VhdxPath $VhdxPath -AccessPath $ProfileMountPath
            Remove-BraveLockerVaultDriveLetter -VhdxPath $VhdxPath -DriveLetter $letter

            if (Test-Path (Join-Path $ProfileMountPath 'Local State')) {
                $verified = $true
                $detail = 'The vault mounts at Brave''s own profile path.'
            } else {
                $detail = "The vault mounted but 'Local State' was not visible at $ProfileMountPath."
            }
            Remove-BraveLockerVaultAccessPath -VhdxPath $VhdxPath -AccessPath $ProfileMountPath
        }
    } catch {
        $detail = $_.Exception.Message
    } finally {
        Dismount-BraveLockerVault -VhdxPath $VhdxPath
    }

    [pscustomobject]@{ IsVerified = $verified; Detail = $detail }
}

function Install-BraveLockerRuntime {
    <#
        Puts a protected copy of the tool under Program Files and registers the
        elevated mount helper.

        Program Files matters: the scheduled task runs its script as
        administrator, so if a non-administrator could write there they would
        have code execution as admin - the tool would create the very hole it
        exists to close. The ACL is read back and verified, not assumed.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SourceRoot,
        [Parameter(Mandatory)][string]$InstallRoot,
        [AllowNull()][scriptblock]$Progress
    )

    Invoke-BraveLockerProgress -Progress $Progress -Percent 5 -Text "Installing to $InstallRoot ..."

    # When the tool is already running FROM the install location - which is the
    # normal case once it ships as an installer - copying would mean deleting
    # the source directory and then copying it onto itself. That destroys the
    # tool mid-setup. Compare resolved paths, not the strings.
    $sourceFull = [System.IO.Path]::GetFullPath($SourceRoot).TrimEnd('\')
    $installFull = [System.IO.Path]::GetFullPath($InstallRoot).TrimEnd('\')
    $sameLocation = $sourceFull.Equals($installFull, [StringComparison]::OrdinalIgnoreCase)

    if ($sameLocation) {
        Write-Verbose 'Already running from the install location; nothing to copy.'
    } else {
        foreach ($sub in 'src', 'scripts') {
            $target = Join-Path $InstallRoot $sub
            if (Test-Path $target) { Remove-Item -Path $target -Recurse -Force }
            New-Item -ItemType Directory -Path $target -Force | Out-Null
            Copy-Item -Path (Join-Path $SourceRoot "$sub\*") -Destination $target -Recurse -Force
        }
    }

    Set-BraveLockerScriptAcl -Path $InstallRoot
    Register-BraveLockerMountTask -ScriptPath (Join-Path $InstallRoot 'scripts\Invoke-BraveLockerVaultTask.ps1')
}

function Save-BraveLockerConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$VhdxPath,
        [Parameter(Mandatory)][string]$ProfileMountPath,
        [Parameter(Mandatory)][string]$PreMigrationPath,
        [Parameter(Mandatory)][string]$BraveExe,
        [Parameter(Mandatory)][string]$InstallRoot,
        [string]$Provider = 'BitLocker'
    )

    $paths = Get-BraveLockerPaths
    if (-not (Test-Path $paths.StateRoot)) {
        New-Item -ItemType Directory -Path $paths.StateRoot -Force | Out-Null
    }

    [pscustomobject]@{
        VhdxPath         = $VhdxPath
        ProfileMountPath = $ProfileMountPath
        PreMigrationPath = $PreMigrationPath
        BraveExe         = $BraveExe
        InstallRoot      = $InstallRoot
        CryptoProvider   = $Provider
    } | ConvertTo-Json -Depth 5 | Set-Content -Path $paths.ConfigPath -Encoding utf8

    $paths.ConfigPath
}
