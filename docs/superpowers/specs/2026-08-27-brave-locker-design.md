# Brave Locker — Design

**Date:** 2026-08-27
**Status:** Approved for planning

## Goal

Let the user browse privately in Brave on their everyday Windows account, so that
nobody else who sits down at the PC can reach the Facebook session, email, saved
passwords, or saved payment cards held in that Brave profile.

## Threat model

**Defends against:** anyone with access to the machine, including a technically
capable colleague and including someone with administrator rights, who tries to
read the Brave profile while the vault is locked — by browsing to it in Explorer,
copying the folder, taking ownership of it, or inspecting the disk offline.

**Does not defend against:** someone using the machine while Brave is open and the
vault is unlocked. During a session the profile is decrypted by design. Locking the
Windows session (`Win+L`) when stepping away remains part of the routine.

Also out of scope: keyloggers, malware already running on the machine, and the
user's own employer if they control the OS image.

## Non-goals

- No second Windows account. The user stays logged into `User` all day. Explicitly ruled out.
- No change to the work Chrome setup.
- No sync, backup, or multi-machine support.
- No protection of the live screen while browsing.

## Approach

Store the Brave profile inside a BitLocker-encrypted virtual disk (VHDX) that is
mounted only while Brave is running.

```
locked   : D:\apps\brave_locker\vault.vhdx   -> opaque encrypted file
unlocked : V:\BraveProfile\                  -> brave.exe --user-data-dir=V:\BraveProfile
```

Brave runs as the normal `User` account, so the existing profile migrates in intact:
cookies and saved passwords are encrypted with the Windows account key (DPAPI), and
that account does not change. Nothing gets logged out and no cards are lost.

Everything used is built into Windows 11 Pro — BitLocker and VHDX. No third-party
software to install.

## Components

**1. `Install-BraveLocker.ps1`** — one-time setup, runs elevated.
- Creates a dynamically-expanding VHDX (32 GB max, ~1.2 GB actual to start).
- Formats it NTFS, enables BitLocker with a user-chosen password.
- Requires a passphrase of at least 8 characters, refuses anything shorter, and
  warns when it is under 12, because the vault file can be attacked offline
  where no lockout applies.
- Displays the BitLocker recovery key and requires the user to confirm they have
  stored it **off this machine** (phone, password manager). It is deliberately not
  written to disk: a recovery key sitting on the PC defeats the whole vault.
- Copies the existing profile in and verifies the copy (file count plus size).
- Registers the elevation helper task (below).
- Leaves the original profile untouched until the user confirms the vault works.

**2. `Start-BraveLocked.ps1`** — the everyday launcher.
- Prompts for the vault password.
- Mounts and unlocks the vault; on wrong password, retries without mounting anything.
- Launches Brave against the in-vault profile.
- Waits for every Brave process using that profile to exit, then locks and dismounts.

**3. `BraveLocker-Mount` scheduled task** — the elevation helper.
- Mounting a VHDX requires administrator rights, which would mean a UAC prompt on
  every single launch. Instead, setup registers a scheduled task that runs with
  highest privileges as this user; the launcher triggers that task to do the
  mount and dismount. UAC is consented once, at install, not daily.
- The task performs only mount and dismount. It never handles the password, which
  is passed to BitLocker by the user's own unlock call.

**4. Desktop shortcut** — "Brave (Private)", pointing at the launcher, using Brave's icon.

## Daily flow

1. Click **Brave (Private)**.
2. Type the vault password.
3. Brave opens with Facebook, email and cards exactly as they are now.
4. Close Brave. The vault locks and dismounts on its own.

At rest, `vault.vhdx` is an unreadable encrypted blob.

## Failure handling

- **Wrong password:** handled by the failed-attempt policy below. Never destructive.
- **Brave crashes or the machine reboots with the vault mounted:** the launcher checks
  at startup for an already-mounted vault. If found with no Brave running, it dismounts
  and relocks before doing anything else, so a crash cannot silently leave the profile
  exposed. Dismount on reboot happens anyway; the check covers the crash case.
- **Brave will not close:** the launcher waits, warns, and refuses to force-dismount a
  volume with open handles. Forcing it risks profile corruption.
- **Drive letter `V:` already in use:** pick the highest free letter instead.
- **Vault file missing or corrupt:** report clearly and point at the recovery key. Do
  not attempt automatic repair.

## Failed-attempt policy

A wrong password is already a complete block — nothing mounts and nothing decrypts,
so there is no partial access to revoke. The policy exists to slow down someone
guessing at the keyboard and to tell the user it happened. It never destroys data:
a destructive killswitch would let a mistype, or a colleague typing junk, wipe every
account and card. That was considered and deliberately rejected.

On each wrong password:

1. Refuse entry. The vault is never mounted on a failed unlock.
2. Force-close any Brave process using the vault profile, and dismount.
3. Impose an escalating cooldown before the next attempt is accepted:
   5 seconds, then 30 seconds, then 5 minutes, holding at 5 minutes thereafter.
4. Append the timestamp to an attempt log.

On the next successful unlock, report any failures since the last success:
`3 failed attempts, most recent Tue 14:22`.

The cooldown and log live outside the vault, since they must be reachable while it is
locked. Someone with admin rights can therefore delete the log or reset the cooldown.
This is accepted: both are there to inform the user and to slow keyboard guessing, not
to stop a determined attacker. The encryption does that.

## Migration and rollback

Setup copies rather than moves. The original profile stays at
`%LOCALAPPDATA%\BraveSoftware\Brave-Browser\User Data` until the user has opened the
vaulted Brave and confirmed their logins are intact.

Only then does a separate step, `Complete-BraveLockerMigration.ps1`, remove the
plaintext original — because leaving it in place would defeat the entire exercise.
That step is deliberately manual and irreversible, and says so before acting.

Rollback before that step: delete the VHDX and the shortcut. Nothing else changed.

## Testing

Verified by running, not by assertion:
- Vault creates, encrypts, and reports `ProtectionStatus: On`.
- With the vault locked, the profile is unreadable — confirmed by attempting to read
  it as the current admin user and getting denied.
- Brave launches against the in-vault profile and shows a migrated logged-in session.
- Closing Brave dismounts the vault; `vault.vhdx` is inaccessible afterward.
- Wrong password never mounts the volume.
- Simulated crash (kill Brave) leaves a state the next launch detects and cleans up.

## Known risks

- **Offline brute force is the real attack.** Anyone who copies `vault.vhdx` can grind
  at the password on their own machine, with no cooldown and no attempt limit. The
  on-screen policy cannot touch that. Passphrase length is the only defence, so setup
  enforces a minimum of 8 characters, warns below 12, and encourages a multi-word passphrase.
- **Password loss means data loss.** That is the point of encryption. The recovery key
  is the only backstop, and it lives off-machine.
- **BitLocker password unlock on fixed data drives** can be disabled by group policy.
  Checked on this machine: no policy present, defaults apply, so it is permitted. If a
  managed policy later blocks it, the fallback is VeraCrypt.
- **The vault is decrypted while Brave runs.** Unavoidable, stated plainly, mitigated
  by `Win+L`.
- **A scheduled task running with highest privileges** is a standing capability on the
  machine. It is scoped to mounting and dismounting this one file.
