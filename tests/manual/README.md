# Manual verification

Tests that cannot run in Pester because they need administrator rights, real
disk images, real BitLocker, or a real child process. They are here rather than
in a scratch folder because they are the only evidence that the recovery path
works, and evidence that lives in someone's temp directory is not evidence.

Both are self-contained: they build their own sandbox, touch nothing belonging
to a real install, and clean up after themselves.

## `Test-LauncherNeverDeadEnds.ps1`

Breaks the launcher four ways and asserts each produces a way out rather than
silence: corrupt config (an error nothing anticipates, so it must reach the
catch-all), a config with no mount path, a cooldown lockout, and a module that
will not import.

Runs unelevated. Redirects `$env:LOCALAPPDATA` at a fake state root and stubs
the UI so nothing pops up on screen.

```powershell
.\tests\manual\Test-LauncherNeverDeadEnds.ps1
```

## `Test-EscapeHatch.ps1`

Proves `Unlock-BraveLockerPermanently.ps1` works, against a genuine
BitLocker-encrypted VHDX it creates for the purpose. Checks that the profile
comes back out intact, that the folder is no longer a mount point, that the
original shortcut is restored, that the config is stood down rather than
deleted, and above all **that the vault is not deleted and is still encrypted**.

Needs an elevated PowerShell - BitLocker and attaching a VHDX both require it.

```powershell
.\tests\manual\Test-EscapeHatch.ps1
```

The script under test is not modified. Only two things are substituted, and
both are genuine external dependencies rather than logic: the passphrase dialog
(stubbed to return a known passphrase) and stdin (fed the "OFF" confirmation).
