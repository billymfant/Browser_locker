# Brave Locker

Keeps a Brave browser profile — logins, cookies, saved passwords, saved cards —
inside a BitLocker-encrypted virtual disk that is only mounted while Brave is
running. Everything is built into Windows 11 Pro; nothing third-party is installed.

```
locked   vault.vhdx        an opaque encrypted file
unlocked V:\BraveProfile   brave.exe --user-data-dir=V:\BraveProfile
```

Brave runs as your normal Windows account, so your existing profile moves in
intact — nothing gets logged out and no cards are lost.

## Setup

Run once, from an **elevated** PowerShell (right-click → Run as administrator),
with Brave completely closed:

```powershell
cd D:\apps\brave_locker
.\scripts\Install-BraveLocker.ps1
```

It will ask for a passphrase, show a recovery key once, copy your profile in,
register the mount helper, and add a **Brave (Private)** shortcut to your desktop
and Start menu.

Then, and this part is not optional:

1. Open **Brave (Private)**.
2. Confirm Facebook, your email and `brave://settings/payments` all look right.
3. Run `.\scripts\Complete-BraveLockerMigration.ps1` to delete the original.

**Until step 3 is done, an unprotected copy of everything is still sitting in
`AppData` and this tool is protecting nothing.**

## Daily use

Click **Brave (Private)** - on the desktop or in the Start menu. A small popup asks
for your passphrase, then Brave opens. Close Brave and the vault seals itself.

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

## Wrong passphrase

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

**Lose both the passphrase and the recovery key and the profile is gone permanently.**
That is what encryption means.

## How it is put together

```
src\BraveLocker\     the logic, unit-tested with Pester
scripts\             setup, launcher, cleanup, and the elevated mount helper
tests\               67 unit tests
docs\                design spec, implementation plan, integration checks
```

A copy of `src` and `scripts` is installed to `C:\Program Files\BraveLocker` at
setup, and the scheduled task runs from there. That matters: the task runs with
administrator rights, so its script must live somewhere non-administrators cannot
write. Program Files already has that ACL. Your working folder stays editable.

Attaching a virtual disk needs administrator rights, which would mean a UAC prompt
on every launch. The scheduled task, registered once during setup, does the attach
and detach instead — so you consent to UAC once, not daily.

## Uninstalling

```powershell
Unregister-ScheduledTask -TaskName 'BraveLocker-Mount' -Confirm:$false
Remove-Item "$env:LOCALAPPDATA\BraveLocker" -Recurse -Force
Remove-Item "C:\Program Files\BraveLocker" -Recurse -Force
Remove-Item "$([Environment]::GetFolderPath('Desktop'))\Brave (Private).lnk"
```

Copy your profile out of the mounted vault **before** deleting `vault.vhdx`, or you
lose it.

## Tests

```powershell
Invoke-Pester -Path .\tests -Output Detailed
```

Unit tests cover the logic. The machine-level behaviour — BitLocker, mounting,
Task Scheduler, Brave — is covered by `docs\INTEGRATION-CHECKS.md`, which has to be
worked through on the real machine.
