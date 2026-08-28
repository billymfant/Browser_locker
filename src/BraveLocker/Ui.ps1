Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
Add-Type -AssemblyName System.Drawing -ErrorAction SilentlyContinue

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
    $form.ClientSize = New-Object System.Drawing.Size(400, 165)
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

    $noteLabel = New-Object System.Windows.Forms.Label
    $noteLabel.Text = $Note
    $noteLabel.Location = New-Object System.Drawing.Point(15, 76)
    $noteLabel.Size = New-Object System.Drawing.Size(370, 34)
    $noteLabel.ForeColor = [System.Drawing.Color]::FromArgb(180, 60, 0)
    $form.Controls.Add($noteLabel)

    $ok = New-Object System.Windows.Forms.Button
    $ok.Text = 'Open'
    $ok.Location = New-Object System.Drawing.Point(215, 120)
    $ok.Size = New-Object System.Drawing.Size(80, 28)
    $ok.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $form.Controls.Add($ok)

    $cancel = New-Object System.Windows.Forms.Button
    $cancel.Text = 'Cancel'
    $cancel.Location = New-Object System.Drawing.Point(305, 120)
    $cancel.Size = New-Object System.Drawing.Size(80, 28)
    $cancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $form.Controls.Add($cancel)

    $form.AcceptButton = $ok
    $form.CancelButton = $cancel
    $form.Add_Shown({ $form.Activate(); $box.Focus() | Out-Null })

    $result = $form.ShowDialog()

    $secure = $null
    if ($result -eq [System.Windows.Forms.DialogResult]::OK) {
        $secure = ConvertTo-BraveLockerSecureString -Text $box.Text
    }

    $box.Clear()
    $form.Dispose()
    $secure
}
