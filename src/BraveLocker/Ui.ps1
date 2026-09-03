Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
Add-Type -AssemblyName System.Drawing -ErrorAction SilentlyContinue

# Taking the keyboard from a process that is not already in the foreground.
#
# Activate() only asks. A form raised from a process that does not own the
# foreground - exactly what the launcher is, started from a shortcut or the
# scheduled task - appears on top while the keystrokes keep going to whatever
# had focus before. The user sees the box, types, and the characters land
# somewhere else. That is how this vault came to be sealed with a fragment of a
# passphrase instead of the whole thing.
#
# SetForegroundWindow on its own is not enough either: Windows refuses it from a
# process that is not already foreground, and returns false. Verified here - the
# popup stayed behind a browser window and collected nothing.
#
# The way through is AttachThreadInput. Attaching this thread's input queue to
# the current foreground thread makes Windows treat the two as one input
# context, and the foreground lock no longer applies. Attach, take focus,
# detach - leaving them attached would tie this window's input to another
# process's for as long as it lives.
#
# The type is added once per session; -Force re-imports must not redefine it.
if (-not ('BraveLocker.Native' -as [type])) {
    Add-Type -Namespace 'BraveLocker' -Name 'Native' -MemberDefinition @'
[DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, IntPtr processId);
[DllImport("user32.dll")] public static extern bool AttachThreadInput(uint idAttach, uint idAttachTo, bool fAttach);
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
[DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr hWnd);
[DllImport("user32.dll")] public static extern IntPtr SetActiveWindow(IntPtr hWnd);
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
[DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();

public static bool ForceForeground(IntPtr hWnd)
{
    IntPtr foreground = GetForegroundWindow();
    uint foregroundThread = GetWindowThreadProcessId(foreground, IntPtr.Zero);
    uint thisThread = GetCurrentThreadId();
    bool attached = false;

    if (foregroundThread != 0 && foregroundThread != thisThread)
    {
        attached = AttachThreadInput(foregroundThread, thisThread, true);
    }
    try
    {
        ShowWindow(hWnd, 9);          // SW_RESTORE, in case it came up minimised
        BringWindowToTop(hWnd);
        SetActiveWindow(hWnd);
        return SetForegroundWindow(hWnd);
    }
    finally
    {
        if (attached) { AttachThreadInput(foregroundThread, thisThread, false); }
    }
}
'@ -ErrorAction SilentlyContinue
}

function ConvertTo-BraveLockerSecureString {
    <#
        Builds a SecureString a character at a time so the passphrase is never
        held in an ordinary string that lingers in memory.
    #>
    [CmdletBinding()]
    [OutputType([securestring])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][AllowNull()][string]$Text
    )

    $secure = New-Object System.Security.SecureString
    if (-not [string]::IsNullOrEmpty($Text)) {
        foreach ($char in $Text.ToCharArray()) { $secure.AppendChar($char) }
    }
    $secure.MakeReadOnly()
    $secure
}

function Show-BraveLockerMessage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Message,
        [string]$Title = 'Brave (Private)',
        [ValidateSet('Info', 'Warning', 'Error')][string]$Icon = 'Info'
    )

    $icons = @{
        Info    = [System.Windows.Forms.MessageBoxIcon]::Information
        Warning = [System.Windows.Forms.MessageBoxIcon]::Warning
        Error   = [System.Windows.Forms.MessageBoxIcon]::Error
    }

    [System.Windows.Forms.MessageBox]::Show(
        $Message, $Title,
        [System.Windows.Forms.MessageBoxButtons]::OK,
        $icons[$Icon]) | Out-Null
}

function Show-BraveLockerPassphrasePrompt {
    <#
        Returns a SecureString, or $null if the user cancelled.

        Two things here are load bearing, both learned the hard way.

        FOCUS. The box takes the foreground itself rather than trusting
        Activate(). Without that, keystrokes typed before Windows got round to
        moving focus went nowhere, and the box collected a fragment of the
        passphrase - observed live as 1 character out of 17, and again as 12.

        THE CHARACTER COUNT. Setup captures the passphrase through this same
        box, twice, and compares the two entries against each other. A box that
        drops keystrokes the same way twice produces two matching fragments, so
        the comparison passes, the round-trip check passes, and the vault is
        sealed with something the user has never knowingly typed. Every check
        setup performs is blind to this; a visible count is not. It shows the
        length only - never the passphrase.
    #>
    [CmdletBinding()]
    [OutputType([securestring])]
    param(
        [string]$Title = 'Brave (Private)',
        [string]$Prompt = 'Enter your vault passphrase',
        [string]$Note = '',
        [string]$IconSource = ''
    )

    $form = New-Object System.Windows.Forms.Form
    $form.Text = $Title
    $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.TopMost = $true
    $form.ClientSize = New-Object System.Drawing.Size(400, 196)
    $form.Font = New-Object System.Drawing.Font('Segoe UI', 9)

    if ($IconSource -and (Test-Path $IconSource)) {
        try {
            $form.Icon = [System.Drawing.Icon]::ExtractAssociatedIcon($IconSource)
        } catch {
            Write-Verbose "Could not load icon from '$IconSource'."
        }
    }

    $label = New-Object System.Windows.Forms.Label
    $label.Text = $Prompt
    $label.Location = New-Object System.Drawing.Point(15, 18)
    $label.Size = New-Object System.Drawing.Size(370, 20)
    $form.Controls.Add($label)

    $box = New-Object System.Windows.Forms.TextBox
    $box.UseSystemPasswordChar = $true
    $box.Location = New-Object System.Drawing.Point(15, 44)
    $box.Size = New-Object System.Drawing.Size(370, 26)
    $form.Controls.Add($box)

    # Length only, never the characters. This is the one signal that catches a
    # passphrase the box has quietly truncated.
    $countLabel = New-Object System.Windows.Forms.Label
    $countLabel.Text = '0 characters'
    $countLabel.Location = New-Object System.Drawing.Point(15, 74)
    $countLabel.Size = New-Object System.Drawing.Size(370, 18)
    $countLabel.ForeColor = [System.Drawing.Color]::FromArgb(90, 90, 90)
    $form.Controls.Add($countLabel)

    $box.Add_TextChanged({
        $n = $box.Text.Length
        $countLabel.Text = if ($n -eq 1) { '1 character' } else { "$n characters" }
    })

    $noteLabel = New-Object System.Windows.Forms.Label
    $noteLabel.Text = $Note
    $noteLabel.Location = New-Object System.Drawing.Point(15, 98)
    $noteLabel.Size = New-Object System.Drawing.Size(370, 34)
    $noteLabel.ForeColor = [System.Drawing.Color]::FromArgb(180, 60, 0)
    $form.Controls.Add($noteLabel)

    $ok = New-Object System.Windows.Forms.Button
    $ok.Text = 'Open'
    $ok.Location = New-Object System.Drawing.Point(215, 151)
    $ok.Size = New-Object System.Drawing.Size(80, 28)
    $ok.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $form.Controls.Add($ok)

    $cancel = New-Object System.Windows.Forms.Button
    $cancel.Text = 'Cancel'
    $cancel.Location = New-Object System.Drawing.Point(305, 151)
    $cancel.Size = New-Object System.Drawing.Size(80, 28)
    $cancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $form.Controls.Add($cancel)

    $form.AcceptButton = $ok
    $form.CancelButton = $cancel
    $form.Add_Shown({
        $form.Activate()
        # Activate() alone loses the race when the launcher is not already the
        # foreground process; this is what actually claims the keyboard.
        if ('BraveLocker.Native' -as [type]) {
            [BraveLocker.Native]::ForceForeground($form.Handle) | Out-Null
        }
        $box.Select()
        $box.Focus() | Out-Null
    })

    $result = $form.ShowDialog()

    $secure = $null
    if ($result -eq [System.Windows.Forms.DialogResult]::OK) {
        $secure = ConvertTo-BraveLockerSecureString -Text $box.Text
    }

    $box.Clear()
    $form.Dispose()
    $secure
}

function Show-BraveLockerRecoveryChoice {
    <#
        The way out of any failure, offered as choices rather than an apology.

        Returns one of: 'Retry', 'OpenUnlocked', 'TurnOffLock', 'Close'.

        This exists because the set of things that can go wrong cannot be
        written down in advance. Every fault this tool has actually hit was
        found on a broken machine, after the fact - so a recovery path that
        only handles anticipated faults is worth exactly as much as the
        guesswork behind it.

        What CAN be guaranteed is that the user is never left with nothing:
        whatever went wrong, there is a button that gets them into a browser,
        and a button that ends the lock's involvement entirely. Neither needs
        the failure to be understood first.

        Deliberately built from a form rather than MessageBox: the choices need
        sentences to explain their consequences, and the three-button
        MessageBox captions cannot carry that.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Message,
        [string]$Title = 'Brave',
        [string]$Detail = '',
        [string]$IconSource = '',
        # Hidden when the vault is already open, where "open without the lock"
        # would mean a second browser on a profile that is already mounted.
        [switch]$NoOpenUnlocked
    )

    $form = New-Object System.Windows.Forms.Form
    $form.Text = $Title
    $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.TopMost = $true
    $form.ClientSize = New-Object System.Drawing.Size(470, 300)
    $form.Font = New-Object System.Drawing.Font('Segoe UI', 9)

    if ($IconSource -and (Test-Path $IconSource)) {
        try {
            $form.Icon = [System.Drawing.Icon]::ExtractAssociatedIcon($IconSource)
        } catch {
            # An icon is decoration. Never let it stop the way out being shown.
        }
    }

    $heading = New-Object System.Windows.Forms.Label
    $heading.Text = $Message
    $heading.Location = New-Object System.Drawing.Point(15, 15)
    $heading.Size = New-Object System.Drawing.Size(440, 40)
    $heading.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
    $form.Controls.Add($heading)

    $detailBox = New-Object System.Windows.Forms.TextBox
    $detailBox.Text = $Detail
    $detailBox.Location = New-Object System.Drawing.Point(15, 58)
    $detailBox.Size = New-Object System.Drawing.Size(440, 52)
    $detailBox.Multiline = $true
    $detailBox.ReadOnly = $true
    $detailBox.ScrollBars = [System.Windows.Forms.ScrollBars]::Vertical
    $detailBox.BackColor = [System.Drawing.Color]::White
    $form.Controls.Add($detailBox)

    $reassure = New-Object System.Windows.Forms.Label
    $reassure.Text = 'Nothing has been deleted. Your vault and passphrase are unaffected.'
    $reassure.Location = New-Object System.Drawing.Point(15, 116)
    $reassure.Size = New-Object System.Drawing.Size(440, 18)
    $reassure.ForeColor = [System.Drawing.Color]::FromArgb(0, 110, 40)
    $form.Controls.Add($reassure)

    # Each choice is a wide button with its consequence written under it. A user
    # who is already locked out should not have to guess what a button does.
    $script:BraveLockerRecoveryChoice = 'Close'

    $y = 142
    $addChoice = {
        param($Caption, $Explanation, $Value)

        $button = New-Object System.Windows.Forms.Button
        $button.Text = $Caption
        $button.Location = New-Object System.Drawing.Point(15, $y)
        $button.Size = New-Object System.Drawing.Size(180, 30)
        $button.Tag = $Value
        $button.Add_Click({
            $script:BraveLockerRecoveryChoice = [string]$this.Tag
            $form.Close()
        }.GetNewClosure())
        $form.Controls.Add($button)

        $label = New-Object System.Windows.Forms.Label
        $label.Text = $Explanation
        $label.Location = New-Object System.Drawing.Point(205, ($y + 4))
        $label.Size = New-Object System.Drawing.Size(250, 34)
        $label.ForeColor = [System.Drawing.Color]::FromArgb(90, 90, 90)
        $form.Controls.Add($label)
    }

    & $addChoice 'Try again' 'Run through the whole thing once more.' 'Retry'
    $y += 40

    if (-not $NoOpenUnlocked) {
        & $addChoice 'Open Brave without the lock' `
            "Gets you a browser now. Your locked profile stays sealed - you will not see your usual tabs or logins." `
            'OpenUnlocked'
        $y += 40
    }

    & $addChoice 'Turn the lock off...' `
        'Copies your profile back out of the vault and stops using the lock. Asks for your passphrase.' `
        'TurnOffLock'
    $y += 40

    $close = New-Object System.Windows.Forms.Button
    $close.Text = 'Close'
    $close.Location = New-Object System.Drawing.Point(375, $y)
    $close.Size = New-Object System.Drawing.Size(80, 28)
    $close.Add_Click({
        $script:BraveLockerRecoveryChoice = 'Close'
        $form.Close()
    })
    $form.Controls.Add($close)
    $form.CancelButton = $close

    $form.ClientSize = New-Object System.Drawing.Size(470, ($y + 44))

    # Same foreground problem as the passphrase box: raised from a process that
    # does not own the foreground, this can appear behind the browser.
    $form.Add_Shown({
        $form.Activate()
        if ('BraveLocker.Native' -as [type]) {
            [BraveLocker.Native]::ForceForeground($form.Handle) | Out-Null
        }
    })

    $form.ShowDialog() | Out-Null
    $form.Dispose()

    $script:BraveLockerRecoveryChoice
}
