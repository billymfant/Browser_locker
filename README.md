# Brave Locker

Puts a passcode on Brave. The profile — logins, cookies, saved passwords, saved
cards — lives inside a BitLocker-encrypted virtual disk that is only mounted
while Brave is running. Everything is built into Windows 11 Pro; nothing
third-party is installed.

```
locked     vault.vhdx     an opaque encrypted file
unlocked   the vault is mounted onto Brave's own profile folder
```

You keep one Brave. Your usual Brave shortcuts are repointed at the locker, so
clicking Brave asks for the passcode and then opens Brave with everything where
you left it. There is no second browser and no "private" duplicate to remember.

## The one thing that makes this work

**The profile never moves.** The vault is mounted *onto* the folder Brave
already uses:

```
C:\Users\<you>\AppData\Local\BraveSoftware\Brave-Browser\User Data

  sealed    an empty folder
  unlocked  that folder IS the encrypted volume
```

Brave is launched with **no `--user-data-dir`** at all.

This is not a stylistic choice. Brave uses Chromium **App-Bound Encryption**:
cookies and saved passwords are encrypted with a key tied to the profile's
path. Copy the profile anywhere else — encrypted vault, plain folder, does not
matter — and Brave cannot decrypt any of it. You get a browser that opens fine
and is signed out of everything.

App-Bound Encryption exists precisely to defeat *"copy the profile folder
somewhere else and read the cookies"*, which is what malware does to steal
sessions. Moving a profile into a vault is that same operation. So the vault
comes to the profile instead.

This was found the hard way: a copy of the profile in a plain, unencrypted
folder is logged out identically to one in the vault. The vault was never the
variable — the path was.

## Setup

Run both, in order, from an **elevated** PowerShell (right-click → Run as
administrator), with Brave completely closed:

```powershell
cd D:\apps\brave_locker
.\scripts\Install-BraveLocker.ps1
.\scripts\Set-BraveLockerAppLock.ps1
```

Setup creates and encrypts the vault, shows a recovery key once, **makes you
type the passphrase back to prove it works**, copies your profile to the vault
root, renames your original to `User Data.premigration`, and verifies the vault
really does mount at Brave's path before reporting success.

`Set-BraveLockerAppLock.ps1` repoints your real Brave shortcuts at the launcher,
keeping their name and icon, and removes any leftover "Brave (Private)" ones.

Then, and this part is not optional:

1. Open Brave and enter your passcode.
2. Confirm your logins and saved cards are all there.
3. Run `.\scripts\Complete-BraveLockerMigration.ps1` to delete the original.

**Until step 3 is done, an unprotected copy of everything is still sitting in
`AppData` and this tool is protecting nothing.** That copy is also your
rollback, which is why it is not deleted automatically.

### Keyboard layouts will ruin your day

Setup seals the vault and reopens it with a **freshly typed** passphrase before
migrating anything, and refuses to continue if that fails.

That check exists because of a real failure. On a machine with more than one
keyboard layout the same keys produce different characters — `mirmigimebira`
typed on a Greek layout is `μιρμιγιμεβιρα`. A passphrase can be entered,
confirmed twice against itself, stored, and be untypeable five minutes later.
Confirming a passphrase against a second copy of itself cannot catch this,
because both copies come from the same keystrokes.

If the check rejects what you type, it reports how many characters were
non-ASCII. Anything above zero means the layout, not a typo — switch to English
(`Alt+Shift`, or check the indicator by the clock says `ENG`) and retype.

## Daily use

Click Brave. A popup asks for your passcode, then Brave opens. Close Brave and
the vault seals itself.

**Nothing runs at startup.** There is no service, no startup entry, and the
scheduled task has no triggers. A virtual disk does not stay attached across a
reboot, so the vault is sealed every time the machine starts. Protection is the
resting state, not something a background process has to maintain — if the
locker never ran at all, the data would still be encrypted.

## What this protects against

Anyone with access to the PC — including a technically capable colleague, and
including someone with administrator rights — who tries to read the profile
while the vault is sealed. Browsing to it, copying `vault.vhdx`, taking
ownership, or inspecting the disk offline all get them an encrypted blob.

Administrator rights decide who may *open a file*. Encryption decides whether
its contents mean anything. There is no key on the machine to take.

## What it does not protect against

- **Anyone using the machine while Brave is open.** The profile is decrypted
  during a session, by design. Press `Win+L` when you step away. That habit is
  part of the tool, not an optional extra.
- **Offline brute force on a weak passphrase.** Someone can copy `vault.vhdx`
  and attack it on their own machine, where the cooldown cannot reach them.
  Length is the defence; setup enforces at least 8 characters and warns below 12.
- **Malware or keyloggers already running** on the account.
- **Launching `brave.exe` directly.** No passcode is asked, because the passcode
  is on the shortcut, not the executable. It opens an *empty* profile — no
  logins, no cards — because the real one is sealed in the vault. Nothing leaks;
  it just looks confusing. The locker moves that stray profile aside (never
  deletes it) next time you open Brave properly.
- **Your screen.** It locks data at rest, not what is on the monitor.

## Wrong passcode

Nothing is ever destroyed. The vault refuses to open, any Brave using it is
closed, the vault is sealed, and the next attempt is delayed — 5 seconds, then
30, then 5 minutes. Failed attempts are logged and reported the next time you
open it successfully, so you can tell if somebody tried.

A destructive killswitch was considered and rejected: it would let a mistype, or
a colleague typing junk three times, wipe every account and card you own.

## The recovery key

Shown once during setup and deliberately never written to this PC — a recovery
key stored on the machine would let anyone who finds it open the vault. Keep it
on your phone or in a password manager, and do not paste it into a chat window:
it opens the vault on its own, without the passphrase.

**Lose both the passcode and the recovery key and the profile is gone
permanently.** That is what encryption means.

## Changing the passcode

Only possible **before** you run `Complete-BraveLockerMigration.ps1`:

```powershell
.\scripts\Reset-BraveLocker.ps1
```

It rebuilds the vault from your original profile — which is exactly why it stops
working once the cleanup has deleted that profile. At that point the vault is
the only copy of your data and there is nothing to rebuild from, so the script
refuses rather than destroy it.

**So: if you want a different passcode, set it before running the cleanup.**

## Uninstalling

```powershell
.\scripts\Uninstall-BraveLocker.ps1
```

Restores your real Brave shortcuts from their backups, removes the scheduled
task, deletes the vault, and renames `User Data.premigration` back into place.
It refuses to run if that folder is missing, because the vault would then be the
only copy of your logins and cards.

## The scripts

| Script | What it does |
|---|---|
| `Install-BraveLocker.ps1` | One-time setup. Elevated. |
| `Set-BraveLockerAppLock.ps1` | Puts the lock on Brave's own shortcuts. Elevated. |
| `Complete-BraveLockerMigration.ps1` | Deletes the original unprotected profile. Irreversible. |
| `Start-BraveLocked.ps1` | The everyday launcher, started invisibly by `BraveLockerLauncher.vbs`. |
| `Invoke-BraveLockerVaultTask.ps1` | The elevated helper. The only code here holding admin rights. |
| `Update-BraveLockerInstall.ps1` | Refreshes the installed copy after code changes. Elevated. |
| `Reset-BraveLocker.ps1` | Start over with a new passcode. Only before the cleanup. Elevated. |
| `Uninstall-BraveLocker.ps1` | Puts the machine back how it was. Elevated. |

## How it is put together

```
src\BraveLocker\     the logic, unit-tested with Pester
scripts\             setup, launcher, cleanup, and the elevated mount helper
tests\               113 unit tests
docs\                design spec, implementation plan, integration checks
```

A copy of `src` and `scripts` is installed to `C:\Program Files\BraveLocker`, and
the scheduled task runs from there. That matters: the task runs with
administrator rights, so its script must live somewhere non-administrators
cannot write. Setup reads the permissions back to confirm it before continuing.

### Mount order

Attaching a virtual disk and unlocking BitLocker both need administrator rights,
which would mean a UAC prompt on every launch. The scheduled task, registered
once during setup, does that work instead — UAC once, not daily. The passcode
reaches it DPAPI-protected under your account, and the request file is deleted
the moment the task has read it.

The order is not arbitrary:

```
attach -> assign a drive letter -> UNLOCK -> mount onto Brave's folder -> drop the letter
```

The vault is unlocked through a drive letter and only then moved onto its
folder, so it never appears in Explorer as a drive in normal use.

Windows only mounts a volume over an **empty** directory. That is a feature: a
stray profile can never be silently shadowed by the vault. It does mean the
launcher checks the folder before every mount and sets anything it finds aside.

## Tests

```powershell
Invoke-Pester -Path .\tests -Output Detailed
```

Unit tests cover the logic. The machine-level behaviour — BitLocker, mounting,
Task Scheduler, Brave — is covered by `docs\INTEGRATION-CHECKS.md`, which has to
be worked through on the real machine.
