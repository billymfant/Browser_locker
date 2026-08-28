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
mounted only while Brave is running — **mounted onto the folder Brave already
uses**, so the profile path never changes.

```
locked   : D:\apps\brave_locker\vault.vhdx        -> opaque encrypted file
unlocked : %LOCALAPPDATA%\BraveSoftware\Brave-Browser\User Data
                                                   -> brave.exe   (no --user-data-dir)
```

### Why the profile must not move — App-Bound Encryption

**This is the central constraint of the design, and it was learned by getting it
wrong twice.**

The original plan copied the profile to `V:\BraveProfile` and launched Brave with
`--user-data-dir`. It reasoned that because cookies and passwords are DPAPI-
encrypted under the Windows account, and the account does not change, nothing
would be lost. That reasoning is obsolete.

Brave (Chromium 127+) uses **App-Bound Encryption**. `Local State` holds an
`app_bound_encrypted_key` — `APPB` prefix, wrapped by a SYSTEM-level service —
and it only decrypts when the profile sits at its original path. Move the profile
and Brave opens cleanly, signed out of everything, with the saved passwords
unreadable.

Established by controlled experiment:

- The legacy `encrypted_key` (`DPAPI` prefix) still unwraps fine as the current
  user, so the account key is intact and the vault does not break DPAPI.
- A copy of the profile in a **plain, unencrypted folder** is logged out
  identically to one in the vault. The vault is not the variable; the path is.
- Brave does not re-key at the new path — the app-bound key is byte identical
  after running there, so the data stays undecryptable rather than being rebuilt.

App-Bound Encryption exists to defeat *"copy the profile folder elsewhere and
read the cookies"*, which is how infostealer malware harvests sessions. Migrating
a profile into a vault is that same operation as far as Brave is concerned.

So the vault comes to the profile. Windows will only mount a volume over an empty
directory, which is what makes this safe rather than fragile: a stray profile can
never be silently shadowed.

Brave runs as the normal `User` account and the path it sees is unchanged, so the
existing profile migrates in intact.

Everything used is built into Windows 11 Pro — BitLocker and VHDX. No third-party
software to install.

### Mount order

BitLocker is unlocked through a drive letter and only then moved onto the folder:

```
attach -> assign drive letter -> UNLOCK -> add folder access path -> drop the letter
```

Verified on the machine. The reverse order — mount to the folder first, then
unlock through it — was tried and abandoned; see `docs/INTEGRATION-CHECKS.md`.

### Passphrase entry

All passphrase input goes through a GUI popup, never a console prompt. A console
window and a dialog can sit on different keyboard layouts, so the same keystrokes
produce different characters (`correct-horse-battery` on a Greek layout is
`σορρεχτ-ηορσε-βαττερυ`), silently storing a passphrase that cannot later be typed.

Setup therefore seals the vault and reopens it with **freshly typed** input before
migrating any data. Confirming a passphrase against a second copy of itself
cannot catch a layout mismatch, because both copies come from the same keystrokes
— which is how setup reported success three times for a vault nobody could open.

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
- Seals the vault and reopens it with a **freshly typed** passphrase before any
  data is migrated, and deletes the vault if that fails. A passphrase confirmed
  only against itself can still be untypeable afterwards.
- Copies the existing profile to the **vault root** and verifies the file count.
- Renames the original to `User Data.premigration` and leaves the now-empty
  folder as the vault's mount point.
- Proves the vault really mounts at Brave's path before reporting success.
- Registers the elevation helper task (below).
- Leaves the renamed original in place until the user confirms the vault works.

**2. `Start-BraveLocked.ps1`** — the everyday launcher.
- Prompts for the vault password.
- Clears the mount folder, moving any stray profile aside rather than deleting it.
- Mounts and unlocks the vault; on wrong password, retries without mounting anything.
- Launches Brave with **no `--user-data-dir`**, so it opens its normal profile
  location — which is where the vault is mounted.
- Waits for every Brave process to exit, then dismounts.

**3. `BraveLocker-Mount` scheduled task** — the elevation helper.
- Mounting a VHDX requires administrator rights, which would mean a UAC prompt on
  every single launch. Instead, setup registers a scheduled task that runs with
  highest privileges as this user; the launcher triggers that task to do the
  mount and dismount. UAC is consented once, at install, not daily.
- The task performs mount, unlock and dismount. Unlocking BitLocker requires
  elevation (verified on this machine: an unelevated unlock returns "Access
  denied", not "wrong password"), so the passphrase must reach the task. It
  travels DPAPI-protected under the current user, so no other account can read
  it, and the request file is deleted the moment the task has read it.
- On a wrong passphrase the task detaches the vault before returning, so a failed
  attempt never leaves the profile attached.

**4. Shortcut takeover** — Brave's own shortcuts are repointed at the launcher,
keeping their name and icon, so there is one Brave rather than a second "private"
one. A separate "Brave (Private)" shortcut was the original plan and was dropped:
users open the browser they already have.

## Daily flow

1. Click **Brave**, as usual.
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
- **Drive letter already in use:** the letter is only held while unlocking, then
  dropped, so a clash is transient; the highest free letter is picked instead.
- **Mount folder not empty:** Brave was started without the locker and built a
  stray profile there. It is moved aside — never deleted, it may hold a real
  session — and the mount proceeds.
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
