Set-StrictMode -Version Latest

foreach ($file in 'Paths', 'Passphrase', 'AttemptLog', 'DriveLetter', 'BraveProcess', 'Vault', 'Crypto', 'MountPoint', 'Discovery', 'Elevation', 'Ui', 'Install', 'Shortcuts') {
    $path = Join-Path $PSScriptRoot "$file.ps1"
    if (Test-Path $path) { . $path }
}

Export-ModuleMember -Function '*-BraveLocker*'
