Set-StrictMode -Version Latest

foreach ($file in 'Paths', 'Passphrase', 'AttemptLog', 'DriveLetter', 'BraveProcess', 'Vault', 'MountPoint', 'Elevation', 'Ui', 'Install', 'Shortcuts') {
    $path = Join-Path $PSScriptRoot "$file.ps1"
    if (Test-Path $path) { . $path }
}

Export-ModuleMember -Function '*-BraveLocker*'
