# Brave Locker

Puts a passcode on Brave. The profile — logins, cookies, saved passwords, saved
cards — lives inside a BitLocker-encrypted virtual disk that is only mounted
while Brave is running. Everything is built into Windows 11 Pro; nothing
third-party is installed.

```
locked     vault.vhdx      an opaque encrypted file
unlocked   the profile     brave.exe --user-data-dir=<vault>\BraveProfile
```

Brave runs as your normal Windows account, so your existing profile moves in
intact — nothing gets logged out and no cards are lost.

You keep one Brave. Your usual Brave shortcuts are repointed at the locker, so
clicking Brave asks for the passcode and then opens Brave. There is no second
browser and no "private" duplicate to remember to use.

## Setup

Run both, in order, from an **elevated** PowerShell (right-click → Run as
administrator), with Brave completely closed:

```powershell
cd D:\apps\brave_locker
.\scripts\Install-BraveLocker.ps1
.\scripts\Set-BraveLockerAppLock.ps1
```

`Install-BraveLocker.ps1` asks for a passphrase, shows a recovery key once,
copies your profile in, registers the mount helper, and installs a protected
copy of the tool to `C:\Program Files\BraveLocker`.

`Set-BraveLockerAppLock.ps1` puts the lock on Brave itself: it repoints your real
Brave shortcuts at the launcher (same name, same icon), removes the separate
"Brave (Private)" shortcuts, and hides the vault so it stops appearing as a drive
in Explorer. It asks for your passphrase to prove the vault still opens through
the hidden path, and puts everything back if it does not.

Then, and this part is not optional:

1. Open **Brave** the way you always do.
2. Confirm Facebook, your email and `brave://settings/payments` all look right.
3. Run `.\scripts\Complete-BraveLockerMigration.ps1` to delete the original.

**Until step 3 is done, an unprotected copy of everything is still sitting in
`AppData` and this tool is protecting nothing.**

## Daily use

Click Brave. A small popup asks for your passcode, then Brave opens. Close Brave
and the vault seals itself.

There is no console window and nothing to leave open. The launcher runs invisibly
in the background and exists only to seal the vault when you close Brave.

## What this protects against

Anyone with access to the PC — including a technically capable colleague, and
including someone with administrator rights — who tries to read the profile while
the vault is locked. Browsing to it, copying the folder, taking ownership, or
inspecting the disk offline all get them an encrypted blob.

## What it does not protect against

- **Anyone using the machine while Brave is open.** The profile is decrypted
  during a session, by design. Press `Win+L` when you step away. That habit is
  part of the tool, not an optional extra.
- **Offline brute force on a weak passphrase.** Someone can copy `vault.vhdx` and
  attack it on their own machine, where the cooldown cannot reach them. Length is
  the defence; setup enforces at least 8 characters and warns below 12. Under 12,
  treat this as "stops someone opening Brave at my desk" rather than "holds up
  against someone determined".
- **Malware or keyloggers already running** on the account.
- **Your screen.** It locks data at rest, not what is on the monitor.

## Wrong passcode

Nothing is ever destroyed. The vault refuses to open, any Brave using it is closed,
the vault is sealed, and the next attempt is delayed — 5 seconds, then 30, then 5
minutes. Failed attempts are logged and reported the next time you open it
successfully, so you can tell if somebody tried.

A destructive killswitch was considered and rejected: it would let a mistype, or a
colleague typing junk three times, wipe every account and card you own.

## The recovery key

Shown once during setup and deliberately never written to this PC — a recovery key
stored on the machine would let anyone who finds it open the vault. Keep it on your
phone or in a password manager.

**Lose both the passcode and the recovery key and the profile is gone permanently.**
That is what encryption means.

## Changing the passcode

Only possible **before** you run `Complete-BraveLockerMigration.ps1`:

```powershell
.\scripts\Reset-BraveLocker.ps1
```

That removes the current setup, builds a fresh vault with a new passphrase, and
puts the lock back on your shortcuts. It rebuilds the vault from your original
profile — which is exactly why it stops working once the migration cleanup has
deleted that profile. At that point the vault is the only copy of your data, and
there is nothing left to rebuild it from, so the script refuses rather than
destroy it.

**So: if you want a different passcode, set it before running the cleanup step.**
Afterwards, the recovery key is the only way in if the passcode is lost.

## Uninstalling

```powershell
.\scripts\Uninstall-BraveLocker.ps1
```

Restores your real Brave shortcuts from their backups, removes the scheduled task,
deletes the vault, and clears out `C:\Program Files\BraveLocker`. It refuses to run
if your original unencrypted profile is missing, because in that case the vault is
the only copy of your logins and cards — copy them out first.

## The scripts

| Script | What it does |
|---|---|
| `Install-BraveLocker.ps1` | One-time setup. Creates and encrypts the vault, copies the profile in, registers the mount helper. Elevated. |
| `Set-BraveLockerAppLock.ps1` | Puts the lock on Brave's own shortcuts and hides the vault drive. Elevated. |
| `Complete-BraveLockerMigration.ps1` | Deletes the original unprotected profile. Irreversible, and the point of the whole exercise. |
| `Start-BraveLocked.ps1` | The everyday launcher. Started invisibly by `BraveLockerLauncher.vbs`; you never run it by hand. |
| `Invoke-BraveLockerVaultTask.ps1` | The elevated helper, run by the scheduled task. The only code here that holds administrator rights. |
| `Update-BraveLockerInstall.ps1` | Refreshes the installed copy after the code changes. Leaves the vault, profile and passcode alone. Elevated. |
| `Reset-BraveLocker.ps1` | Start over with a new passcode. Only works before the migration cleanup. Elevated. |
| `Uninstall-BraveLocker.ps1` | Puts the machine back how it was. Elevated. |

## How it is put together

```
src\BraveLocker\     the logic, unit-tested with Pester
scripts\             setup, launcher, cleanup, and the elevated mount helper
tests\               94 unit tests
docs\                design spec, implementation plan, integration checks
```

A copy of `src` and `scripts` is installed to `C:\Program Files\BraveLocker` at
setup, and the scheduled task runs from there. That matters: the task runs with
administrator rights, so its script must live somewhere non-administrators cannot
write. Program Files already has that ACL, and setup reads the permissions back to
confirm it before continuing. Your working folder stays editable.

Attaching a virtual disk and unlocking BitLocker both need administrator rights,
which would mean a UAC prompt on every launch. The scheduled task, registered once
during setup, does that work instead — so you consent to UAC once, not daily. The
passcode reaches it DPAPI-protected under your own account, and the request file
is deleted the moment the task has read it.

## Tests

```powershell
Invoke-Pester -Path .\tests -Output Detailed
```

Unit tests cover the logic. The machine-level behaviour — BitLocker, mounting,
Task Scheduler, Brave — is covered by `docs\INTEGRATION-CHECKS.md`, which has to be
worked through on the real machine.
