#Requires -Version 5.1
<#
    Brave Locker setup wizard.

    Self-elevates, then walks through: system checks, vault location,
    passphrase, recovery key, a typed-passphrase check, migration, done.

    All the work is done by the BraveLocker module. This file is presentation
    only - if logic starts appearing here, it belongs in src\BraveLocker\Setup.ps1
    so the console path and the wizard cannot drift apart.
#>
[CmdletBinding()]
param(
    [switch]$Elevated
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot

# --- Self-elevate -----------------------------------------------------------
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$isAdmin = (New-Object Security.Principal.WindowsPrincipal($identity)).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin -and -not $Elevated) {
    Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
        '-File', "`"$PSCommandPath`"", '-Elevated'
    )
    return
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms
Import-Module (Join-Path $root 'src\BraveLocker\BraveLocker.psd1') -Force

$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Brave Locker Setup" Height="560" Width="720"
        WindowStartupLocation="CenterScreen" ResizeMode="NoResize"
        Background="#FF1B1B1F" FontFamily="Segoe UI">
  <Grid>
    <Grid.RowDefinitions>
      <RowDefinition Height="88"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="64"/>
    </Grid.RowDefinitions>

    <Border Grid.Row="0" Background="#FF25252B">
      <StackPanel Margin="28,16,28,0">
        <TextBlock x:Name="HeadTitle" Text="Brave Locker" FontSize="22" FontWeight="SemiBold" Foreground="#FFF5F5F7"/>
        <TextBlock x:Name="HeadSub" Text="A passcode for your browser" FontSize="13" Foreground="#FF9A9AA6" Margin="0,4,0,0" TextWrapping="Wrap"/>
      </StackPanel>
    </Border>

    <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto" Padding="28,20,28,10">
      <Grid>
        <!-- Welcome -->
        <StackPanel x:Name="PageWelcome" Visibility="Visible">
          <TextBlock Foreground="#FFD8D8E0" FontSize="14" TextWrapping="Wrap" LineHeight="22" Text="Brave Locker puts a passcode on Brave. Your browser profile - logins, cookies, saved passwords - is kept inside an encrypted vault that only opens while Brave is running."/>
          <TextBlock Foreground="#FFD8D8E0" FontSize="14" TextWrapping="Wrap" LineHeight="22" Margin="0,14,0,0" Text="When Brave is closed, that data is an unreadable encrypted file. Anyone who copies it, takes ownership of it, or reads the disk directly gets nothing - including someone with administrator rights."/>
          <Border Background="#FF2E2A1C" BorderBrush="#FF6B5A1F" BorderThickness="1" CornerRadius="4" Padding="14" Margin="0,22,0,0">
            <StackPanel>
              <TextBlock Foreground="#FFE8C86A" FontWeight="SemiBold" Text="Before you start"/>
              <TextBlock Foreground="#FFD8D8E0" TextWrapping="Wrap" Margin="0,6,0,0" LineHeight="20" Text="Close Brave completely. Setup copies your profile, and copying it while it is being written to risks a damaged copy."/>
              <TextBlock Foreground="#FFD8D8E0" TextWrapping="Wrap" Margin="0,6,0,0" LineHeight="20" Text="Your existing profile is copied, never deleted. It stays on disk as a rollback until you confirm everything works."/>
            </StackPanel>
          </Border>
        </StackPanel>

        <!-- Checks -->
        <StackPanel x:Name="PageChecks" Visibility="Collapsed">
          <TextBlock Foreground="#FF9A9AA6" FontSize="13" Margin="0,0,0,14" TextWrapping="Wrap" Text="Everything below must pass before setup can safely change anything."/>
          <ItemsControl x:Name="CheckList">
            <ItemsControl.ItemTemplate>
              <DataTemplate>
                <Border Background="#FF25252B" CornerRadius="4" Padding="12" Margin="0,0,0,8">
                  <Grid>
                    <Grid.ColumnDefinitions>
                      <ColumnDefinition Width="30"/>
                      <ColumnDefinition Width="*"/>
                    </Grid.ColumnDefinitions>
                    <TextBlock Grid.Column="0" Text="{Binding Glyph}" Foreground="{Binding Colour}" FontSize="16" FontWeight="Bold"/>
                    <StackPanel Grid.Column="1">
                      <TextBlock Text="{Binding Name}" Foreground="#FFF5F5F7" FontWeight="SemiBold"/>
                      <TextBlock Text="{Binding Detail}" Foreground="#FF9A9AA6" TextWrapping="Wrap" Margin="0,3,0,0"/>
                    </StackPanel>
                  </Grid>
                </Border>
              </DataTemplate>
            </ItemsControl.ItemTemplate>
          </ItemsControl>
          <Button x:Name="BtnRecheck" Content="Check again" Width="120" Height="30" HorizontalAlignment="Left" Margin="0,10,0,0"/>
        </StackPanel>

        <!-- Location -->
        <StackPanel x:Name="PageLocation" Visibility="Collapsed">
          <TextBlock Foreground="#FFD8D8E0" FontSize="14" TextWrapping="Wrap" LineHeight="22" Text="The vault is a single encrypted file. Put it on a drive with room to spare - it grows as you browse."/>
          <TextBlock Foreground="#FFF5F5F7" Margin="0,20,0,6" Text="Vault file"/>
          <Grid>
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <TextBox x:Name="TxtVaultPath" Grid.Column="0" Height="32" Padding="8,6" Background="#FF2E2E36" Foreground="#FFF5F5F7" BorderBrush="#FF44444F"/>
            <Button x:Name="BtnBrowse" Grid.Column="1" Content="Browse..." Width="90" Height="32" Margin="8,0,0,0"/>
          </Grid>
          <TextBlock x:Name="LblVaultInfo" Foreground="#FF9A9AA6" Margin="0,10,0,0" TextWrapping="Wrap"/>
        </StackPanel>

        <!-- Passphrase -->
        <StackPanel x:Name="PagePass" Visibility="Collapsed">
          <TextBlock Foreground="#FFD8D8E0" FontSize="14" TextWrapping="Wrap" LineHeight="22" Text="This passcode is the only thing standing between someone with this PC and your accounts. Length matters far more than cleverness - a few unrelated words you will actually remember beats a short cryptic one."/>
          <TextBlock Foreground="#FFF5F5F7" Margin="0,20,0,6" Text="Passcode"/>
          <PasswordBox x:Name="TxtPass1" Height="32" Padding="8,6" Background="#FF2E2E36" Foreground="#FFF5F5F7" BorderBrush="#FF44444F"/>
          <TextBlock Foreground="#FFF5F5F7" Margin="0,14,0,6" Text="Type it again"/>
          <PasswordBox x:Name="TxtPass2" Height="32" Padding="8,6" Background="#FF2E2E36" Foreground="#FFF5F5F7" BorderBrush="#FF44444F"/>
          <TextBlock x:Name="LblPassInfo" Foreground="#FF9A9AA6" Margin="0,14,0,0" TextWrapping="Wrap"/>
          <Border Background="#FF2E2A1C" BorderBrush="#FF6B5A1F" BorderThickness="1" CornerRadius="4" Padding="12" Margin="0,16,0,0">
            <TextBlock Foreground="#FFD8D8E0" TextWrapping="Wrap" LineHeight="20" Text="Check your keyboard language before typing. If you have more than one layout installed, the same keys produce different characters - and a passcode stored on one layout cannot be typed on another. The indicator by the clock should show the layout you will use every day."/>
          </Border>
        </StackPanel>

        <!-- Recovery key -->
        <StackPanel x:Name="PageRecovery" Visibility="Collapsed">
          <TextBlock Foreground="#FFFF8B8B" FontSize="15" FontWeight="SemiBold" Text="Write this down now. It is shown once."/>
          <Border Background="#FF25252B" BorderBrush="#FF44444F" BorderThickness="1" CornerRadius="4" Padding="16" Margin="0,14,0,0">
            <TextBox x:Name="TxtRecovery" IsReadOnly="True" TextWrapping="Wrap" FontFamily="Consolas" FontSize="15"
                     Background="Transparent" Foreground="#FFF5F5F7" BorderThickness="0"/>
          </Border>
          <Button x:Name="BtnCopyKey" Content="Copy to clipboard" Width="150" Height="30" HorizontalAlignment="Left" Margin="0,12,0,0"/>
          <TextBlock Foreground="#FFD8D8E0" TextWrapping="Wrap" LineHeight="20" Margin="0,16,0,0" Text="This key opens the vault on its own, without your passcode. It is deliberately not saved anywhere on this PC - a recovery key sitting on the machine would let anyone who finds it in. Put it on your phone or in a password manager, and do not paste it into a chat window."/>
          <TextBlock Foreground="#FFFF8B8B" TextWrapping="Wrap" LineHeight="20" Margin="0,10,0,0" Text="If you lose both the passcode and this key, the profile is gone permanently. That is what encryption means."/>
          <CheckBox x:Name="ChkStored" Margin="0,18,0,0" Foreground="#FFF5F5F7" Content="I have saved this key somewhere off this PC"/>
        </StackPanel>

        <!-- Typed check -->
        <StackPanel x:Name="PageVerify" Visibility="Collapsed">
          <TextBlock Foreground="#FFD8D8E0" FontSize="14" TextWrapping="Wrap" LineHeight="22" Text="Now type the passcode again. The vault will be sealed and reopened with exactly what you type."/>
          <TextBlock Foreground="#FF9A9AA6" FontSize="13" TextWrapping="Wrap" LineHeight="20" Margin="0,12,0,0" Text="This is not a formality. Confirming a passcode against a second copy of itself cannot catch a keyboard layout problem, because both copies come from the same keystrokes. This check reopens the real vault, so a passcode that cannot be reproduced is caught now - before your profile is inside it."/>
          <TextBlock Foreground="#FFF5F5F7" Margin="0,20,0,6" Text="Passcode"/>
          <PasswordBox x:Name="TxtVerify" Height="32" Padding="8,6" Background="#FF2E2E36" Foreground="#FFF5F5F7" BorderBrush="#FF44444F"/>
          <TextBlock x:Name="LblVerifyInfo" Foreground="#FFFF8B8B" Margin="0,14,0,0" TextWrapping="Wrap" LineHeight="20"/>
        </StackPanel>

        <!-- Progress -->
        <StackPanel x:Name="PageWork" Visibility="Collapsed">
          <TextBlock x:Name="LblWork" Foreground="#FFF5F5F7" FontSize="14" TextWrapping="Wrap" Text="Working..."/>
          <ProgressBar x:Name="Bar" Height="8" Margin="0,18,0,0" Minimum="0" Maximum="100" Foreground="#FF7B61FF" Background="#FF2E2E36" BorderThickness="0"/>
          <TextBlock x:Name="LblWorkSub" Foreground="#FF9A9AA6" Margin="0,14,0,0" TextWrapping="Wrap" LineHeight="20"/>
        </StackPanel>

        <!-- Done -->
        <StackPanel x:Name="PageDone" Visibility="Collapsed">
          <TextBlock Foreground="#FF7BE495" FontSize="17" FontWeight="SemiBold" Text="Brave Locker is set up."/>
          <TextBlock Foreground="#FFD8D8E0" FontSize="14" TextWrapping="Wrap" LineHeight="22" Margin="0,14,0,0" Text="Click Brave the way you always do. It will ask for your passcode, then open with everything exactly as you left it. Close Brave and the vault seals itself."/>
          <Border Background="#FF2E2A1C" BorderBrush="#FF6B5A1F" BorderThickness="1" CornerRadius="4" Padding="14" Margin="0,20,0,0">
            <StackPanel>
              <TextBlock Foreground="#FFE8C86A" FontWeight="SemiBold" Text="One step left"/>
              <TextBlock x:Name="LblDoneWarn" Foreground="#FFD8D8E0" TextWrapping="Wrap" Margin="0,6,0,0" LineHeight="20"/>
            </StackPanel>
          </Border>
          <TextBlock Foreground="#FF9A9AA6" TextWrapping="Wrap" LineHeight="20" Margin="0,16,0,0" Text="Press Win+L whenever you step away. While Brave is open the profile is decrypted by design - that is the one gap, and locking your screen closes it."/>
        </StackPanel>

        <!-- Blocked -->
        <StackPanel x:Name="PageBlocked" Visibility="Collapsed">
          <TextBlock x:Name="LblBlocked" Foreground="#FFFF8B8B" FontSize="15" FontWeight="SemiBold" TextWrapping="Wrap"/>
          <TextBlock x:Name="LblBlockedDetail" Foreground="#FFD8D8E0" TextWrapping="Wrap" LineHeight="22" Margin="0,14,0,0"/>
          <TextBlock Foreground="#FF9A9AA6" TextWrapping="Wrap" LineHeight="20" Margin="0,18,0,0" Text="Nothing on this PC has been changed."/>
        </StackPanel>
      </Grid>
    </ScrollViewer>

    <Border Grid.Row="2" Background="#FF25252B">
      <Grid Margin="28,0">
        <TextBlock x:Name="LblStep" VerticalAlignment="Center" Foreground="#FF9A9AA6" FontSize="12"/>
        <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center">
          <Button x:Name="BtnBack" Content="Back" Width="92" Height="32" Margin="0,0,8,0"/>
          <Button x:Name="BtnNext" Content="Next" Width="112" Height="32" Margin="0,0,8,0"/>
          <Button x:Name="BtnCancel" Content="Cancel" Width="92" Height="32"/>
        </StackPanel>
      </Grid>
    </Border>
  </Grid>
</Window>
'@

$reader = New-Object System.Xml.XmlNodeReader ([xml]$xaml)
$window = [Windows.Markup.XamlReader]::Load($reader)

$ui = @{}
foreach ($name in @(
    'HeadTitle','HeadSub','PageWelcome','PageChecks','CheckList','BtnRecheck','PageLocation',
    'TxtVaultPath','BtnBrowse','LblVaultInfo','PagePass','TxtPass1','TxtPass2','LblPassInfo',
    'PageRecovery','TxtRecovery','BtnCopyKey','ChkStored','PageVerify','TxtVerify','LblVerifyInfo',
    'PageWork','LblWork','Bar','LblWorkSub','PageDone','LblDoneWarn','PageBlocked','LblBlocked',
    'LblBlockedDetail','BtnBack','BtnNext','BtnCancel','LblStep')) {
    $ui[$name] = $window.FindName($name)
}

$state = @{
    Page        = 'Welcome'
    Requirement = $null
    VaultPath   = ''
    Passphrase  = $null
    RecoveryKey = ''
    MountPoint  = ''
    VhdxPath    = ''
    PreMigration= ''
    SizeMB      = 8192
}

function Sync-Ui {
    $null = $window.Dispatcher.Invoke([Windows.Threading.DispatcherPriority]::Render, [action] {})
}

function Show-Page {
    param([string]$Name)

    foreach ($page in 'Welcome','Checks','Location','Pass','Recovery','Verify','Work','Done','Blocked') {
        $ui["Page$page"].Visibility = 'Collapsed'
    }
    $ui["Page$Name"].Visibility = 'Visible'
    $state.Page = $Name

    $titles = @{
        Welcome  = @('Brave Locker', 'A passcode for your browser')
        Checks   = @('System check', 'Making sure this PC can do it safely')
        Location = @('Where the vault goes', 'One encrypted file, on a drive of your choosing')
        Pass     = @('Choose your passcode', 'You will need this every time you open Brave')
        Recovery = @('Recovery key', 'Your only way back in if the passcode is lost')
        Verify   = @('Type it back', 'Proving the passcode actually works')
        Work     = @('Setting up', 'This takes a minute or two')
        Done     = @('All set', 'Brave now asks for your passcode')
        Blocked  = @('Cannot continue', 'Nothing has been changed')
    }
    $ui.HeadTitle.Text = $titles[$Name][0]
    $ui.HeadSub.Text = $titles[$Name][1]

    $steps = @{ Welcome='Step 1 of 6'; Checks='Step 2 of 6'; Location='Step 3 of 6'; Pass='Step 4 of 6'; Recovery='Step 5 of 6'; Verify='Step 6 of 6'; Work=''; Done=''; Blocked='' }
    $ui.LblStep.Text = $steps[$Name]

    $ui.BtnBack.IsEnabled = ($Name -in @('Checks','Location','Pass'))
    $ui.BtnNext.Visibility = $(if ($Name -in @('Work','Blocked')) { 'Collapsed' } else { 'Visible' })
    $ui.BtnNext.Content = switch ($Name) {
        'Welcome'  { 'Start' }
        'Verify'   { 'Verify and install' }
        'Done'     { 'Finish' }
        default    { 'Next' }
    }
    $ui.BtnCancel.Content = $(if ($Name -eq 'Done') { 'Close' } else { 'Cancel' })
}

function Read-PasswordBox {
    param($Box)
    ConvertTo-BraveLockerSecureString -Text $Box.Password
}

function Update-Checks {
    $state.Requirement = Test-BraveLockerRequirement
    $items = New-Object System.Collections.ObjectModel.ObservableCollection[object]
    foreach ($check in $state.Requirement.Checks) {
        $items.Add([pscustomobject]@{
            Glyph  = $(if ($check.IsOk) { [char]0x2713 } else { [char]0x2715 })
            Colour = $(if ($check.IsOk) { '#FF7BE495' } else { '#FFFF8B8B' })
            Name   = $check.Name
            Detail = $check.Detail
        })
    }
    $ui.CheckList.ItemsSource = $items
    $ui.BtnNext.IsEnabled = $state.Requirement.CanProceed

    if ($state.Requirement.CanProceed -and -not $state.VaultPath) {
        $state.VaultPath = Get-BraveLockerDefaultVaultPath -DriveLetter $state.Requirement.VaultDrive
        $ui.TxtVaultPath.Text = $state.VaultPath
        $state.SizeMB = Get-BraveLockerVaultSizeMB -ProfileSizeBytes $state.Requirement.ProfileSize
        $ui.LblVaultInfo.Text = "Your profile is {0:N2} GB. The vault can grow to {1} GB and only uses what it needs." -f `
            ($state.Requirement.ProfileSize / 1GB), [int]($state.SizeMB / 1024)
    }
}

function Set-Work {
    param([int]$Percent, [string]$Text, [string]$Sub = '')
    $ui.Bar.Value = $Percent
    $ui.LblWork.Text = $Text
    if ($Sub) { $ui.LblWorkSub.Text = $Sub }
    Sync-Ui
}

function Show-Blocked {
    param([string]$Title, [string]$Detail)
    $ui.LblBlocked.Text = $Title
    $ui.LblBlockedDetail.Text = $Detail
    Show-Page 'Blocked'
}

# --- Page handlers ----------------------------------------------------------
$ui.BtnRecheck.Add_Click({ Update-Checks })

$ui.BtnBrowse.Add_Click({
    $dialog = New-Object System.Windows.Forms.SaveFileDialog
    $dialog.Title = 'Where should the vault file go?'
    $dialog.Filter = 'Vault file (*.vhdx)|*.vhdx'
    $dialog.FileName = 'vault.vhdx'
    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $ui.TxtVaultPath.Text = $dialog.FileName
    }
})

$ui.BtnCopyKey.Add_Click({
    Set-Clipboard -Value $ui.TxtRecovery.Text
    $ui.BtnCopyKey.Content = 'Copied'
})

$ui.TxtPass1.Add_PasswordChanged({
    $text = $ui.TxtPass1.Password
    $check = Test-BraveLockerPassphrase -Passphrase $text
    if ($text.Length -eq 0) {
        $ui.LblPassInfo.Text = ''
    } elseif (-not $check.IsValid) {
        $ui.LblPassInfo.Text = "$($text.Length) characters - at least 8 needed."
    } elseif ($check.IsWeak) {
        $ui.LblPassInfo.Text = "$($text.Length) characters. Usable, but short: someone who copies the vault file can attack it offline where no lockout applies. Twelve or more closes that gap."
    } else {
        $ui.LblPassInfo.Text = "$($text.Length) characters. Good."
    }
})

$ui.BtnCancel.Add_Click({ $window.Close() })

$ui.BtnBack.Add_Click({
    switch ($state.Page) {
        'Checks'   { Show-Page 'Welcome' }
        'Location' { Show-Page 'Checks' }
        'Pass'     { Show-Page 'Location' }
    }
})

$ui.BtnNext.Add_Click({
    switch ($state.Page) {

        'Welcome' { Show-Page 'Checks'; Update-Checks }

        'Checks' {
            if (-not $state.Requirement.CanProceed) { return }
            Show-Page 'Location'
        }

        'Location' {
            $path = $ui.TxtVaultPath.Text.Trim()
            if (-not $path) { $ui.LblVaultInfo.Text = 'Choose where the vault file should go.'; return }
            if (Test-Path $path) {
                $ui.LblVaultInfo.Text = 'A file already exists there. Choose a different name, or delete it first.'
                return
            }
            $state.VaultPath = $path
            Show-Page 'Pass'
        }

        'Pass' {
            $p1 = $ui.TxtPass1.Password
            $p2 = $ui.TxtPass2.Password
            if ($p1 -ne $p2) { $ui.LblPassInfo.Text = 'Those two do not match.'; return }
            $check = Test-BraveLockerPassphrase -Passphrase $p1
            if (-not $check.IsValid) { $ui.LblPassInfo.Text = 'Too short - at least 8 characters.'; return }

            $state.Passphrase = Read-PasswordBox $ui.TxtPass1

            Show-Page 'Work'
            try {
                Set-Work 5 'Installing Brave Locker...' 'Putting a protected copy under Program Files, where only administrators can change it.'
                Install-BraveLockerRuntime -SourceRoot $root -InstallRoot 'C:\Program Files\BraveLocker' `
                    -Progress { param($p, $t) Set-Work $p $t }

                Set-Work 10 'Creating the encrypted vault...'
                $vault = New-BraveLockerEncryptedVault -VhdxPath $state.VaultPath -MaximumSizeMB $state.SizeMB `
                    -Passphrase $state.Passphrase -Progress { param($p, $t) Set-Work $p $t }

                $state.VhdxPath = $vault.VhdxPath
                $state.MountPoint = $vault.MountPoint
                $state.RecoveryKey = $vault.RecoveryKey

                $ui.TxtRecovery.Text = $state.RecoveryKey
                $ui.ChkStored.IsChecked = $false
                Show-Page 'Recovery'
            } catch {
                Show-Blocked 'Setup could not create the vault' $_.Exception.Message
            }
        }

        'Recovery' {
            if (-not $ui.ChkStored.IsChecked) {
                [System.Windows.MessageBox]::Show(
                    "Save the recovery key first. It is shown once and never written to this PC.`n`nIf you lose both the passcode and this key, the profile is gone permanently.",
                    'Brave Locker', 'OK', 'Warning') | Out-Null
                return
            }
            $ui.TxtVerify.Password = ''
            $ui.LblVerifyInfo.Text = ''
            Show-Page 'Verify'
        }

        'Verify' {
            $typed = Read-PasswordBox $ui.TxtVerify
            $result = Test-BraveLockerPassphraseRoundTrip -MountPoint $state.MountPoint -Typed $typed

            if (-not $result.Unlocked) {
                $ui.LblVerifyInfo.Text = "That did not open the vault. You typed $($result.TypedLength) character(s). $($result.Hint)"
                return
            }

            Show-Page 'Work'
            try {
                $migration = Invoke-BraveLockerProfileMigration -VhdxPath $state.VhdxPath `
                    -MountPoint $state.MountPoint -ProfileMountPath $state.Requirement.ProfilePath `
                    -Progress { param($p, $t) Set-Work $p $t }
                $state.PreMigration = $migration.PreMigrationPath

                Set-Work 88 'Checking the vault opens where Brave expects it...'
                $verify = Test-BraveLockerVaultMountsAtProfilePath -VhdxPath $state.VhdxPath `
                    -ProfileMountPath $state.Requirement.ProfilePath -Passphrase $state.Passphrase
                if (-not $verify.IsVerified) { throw $verify.Detail }

                Set-Work 94 'Saving settings and locking your Brave shortcuts...'
                Save-BraveLockerConfig -VhdxPath $state.VhdxPath `
                    -ProfileMountPath $state.Requirement.ProfilePath `
                    -PreMigrationPath $state.PreMigration `
                    -BraveExe $state.Requirement.BraveExe `
                    -InstallRoot 'C:\Program Files\BraveLocker' | Out-Null

                $vbs = 'C:\Program Files\BraveLocker\scripts\BraveLockerLauncher.vbs'
                $backupDir = Join-Path (Get-BraveLockerPaths).StateRoot 'shortcut-backup'
                foreach ($shortcut in @(Get-BraveLockerBraveShortcut -BraveExe $state.Requirement.BraveExe)) {
                    Set-BraveLockerShortcutToLauncher -ShortcutPath $shortcut -VbsPath $vbs `
                        -BraveExe $state.Requirement.BraveExe -BackupDir $backupDir
                }

                Set-Work 100 'Done.'
                $ui.LblDoneWarn.Text = "Your original profile is still on this PC, unencrypted, at:`n`n$($state.PreMigration)`n`nOpen Brave and check your logins are all there. Once you are sure, run Complete-BraveLockerMigration.ps1 to delete it. Until then it is both a security hole and your rollback."
                Show-Page 'Done'
            } catch {
                Show-Blocked 'Setup stopped' ("$($_.Exception.Message)`n`nYour Brave profile has not been deleted. If a folder named 'User Data.premigration' exists, that is your profile - rename it back to 'User Data' to undo everything.")
            }
        }

        'Done' { $window.Close() }
    }
})

Show-Page 'Welcome'
$window.ShowDialog() | Out-Null
