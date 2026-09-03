# Browser Locker - Emergency Card

**Print this. Keep it with your recovery key, not on this PC.**

Your data is not trapped. The vault is an ordinary Windows BitLocker drive, and
Windows can open it on its own - no Browser Locker, no special tools, no expert.
Everything below has been run on this machine, not guessed.

---

## First: the one thing not to do

**Do not delete the vault file.** It is not a copy of your data. Until you have
deliberately moved your profile out of it, it *is* your data.

```
D:\apps\brave_locker\vault.vhdx
```

Deleting it without the passphrase or recovery key destroys your logins, saved
passwords and cards permanently. Nothing else on this card can go that wrong.

---

## Level 1 - The browser will not open

Click your browser icon. You should get either the passphrase box or a browser
window. If you get **a dialog offering choices**, take one:

| Choice | What it does |
|---|---|
| **Try again** | Runs the whole thing again from scratch. |
| **Open without the lock** | Gets you a working browser now. Your locked profile stays sealed - you will not see your usual tabs or logins. Nothing is lost. |
| **Turn the lock off...** | Copies your profile out of the vault and stops using the lock. Asks for your passphrase. |

If you get **nothing at all** - no box, no browser, no error - go to Level 2.

---

## Level 2 - Run the repair

Double-click:

```
C:\Program Files\BraveLocker\scripts\Repair-BraveLocker.ps1
```

If double-clicking opens it in Notepad instead of running it, right-click it and
choose **Run with PowerShell**. Click **Yes** to the admin prompt.

It fixes the two faults that have actually happened on this machine:

- a browser update quietly pointing your shortcut back at the browser, so the
  passphrase box never appeared
- a mount point left behind by a session that never closed properly, which
  stopped the vault opening and which **no amount of restarting will fix**

It will not fix everything. That is what Level 3 is for.

---

## Level 3 - Turn the lock off and take your profile back

Right-click -> **Run with PowerShell**:

```
C:\Program Files\BraveLocker\scripts\Unlock-BraveLockerPermanently.ps1
```

Needs your passphrase. It copies your profile out of the vault, puts it back as
an ordinary folder, restores your original browser shortcut, and stops the
locker running. **It does not delete the vault** - that stays as an encrypted
backup until you delete it yourself.

Afterwards your browser opens normally with no passphrase, and anyone using this
PC can see your profile. That is the trade you are making.

---

## Level 4 - Open the vault with nothing but Windows

Use this when Browser Locker is broken, deleted, or this PC has been rebuilt.
It needs no Browser Locker files at all - only the vault file and your
passphrase. **It works on any Windows PC**, not just this one.

**You need an administrator account.** Mounting a virtual disk is an
administrator action - verified on this machine: a standard user gets
*"A required privilege is not held by the client."* If your account cannot
approve an admin prompt, you need someone whose can.

1. Copy `vault.vhdx` to the PC if it is not already there.
2. **Right-click the file -> Mount.** Approve the admin prompt.
   (If "Mount" is missing, the file has the wrong extension - it must end
   `.vhdx`.)
3. A new drive appears in **This PC** with a **padlock** on it.
4. **Double-click that drive.** Windows asks for the password - this is your
   Browser Locker passphrase. Type it and click Unlock.
   - Forgotten it? Click **More options -> Enter recovery key** and use the
     48-digit recovery key from setup.
5. The drive opens. Your browser profile is the contents - `Default`,
   `Local State`, and so on. **Copy it somewhere safe.**
6. When finished: right-click the drive -> **Eject**.

### If you prefer typing commands

In an **administrator** PowerShell:

```powershell
Mount-DiskImage -ImagePath 'D:\apps\brave_locker\vault.vhdx'
# find the new drive letter, then unlock it:
manage-bde -unlock X: -password
# or, with the recovery key:
manage-bde -unlock X: -RecoveryPassword 123456-123456-...
Dismount-DiskImage -ImagePath 'D:\apps\brave_locker\vault.vhdx'    # when done
```

---

## Getting your logins back into a browser

The profile you recover is a *browser profile folder*. To use it, close the
browser completely, then replace the contents of

```
C:\Users\USER\AppData\Local\BraveSoftware\Brave-Browser\User Data
```

with what you copied out.

**One warning that costs people their saved passwords:** the browser ties saved
passwords and cookies to the profile's *path*. Copied back to the exact path
above, they work. Opened from anywhere else - a USB stick, a folder on your
desktop - you will find every account logged out and the saved passwords
unreadable. Bookmarks, history and downloads are fine either way.

---

## The recovery key

Setup showed it once and deliberately never saved it on this PC - a recovery key
stored next to the thing it unlocks protects nobody.

**If you have lost both the passphrase and the recovery key, the data is gone.**
Not "gone until an expert looks at it". Gone. That is what encryption is. No one
- not the person who wrote this tool, not Microsoft - can open it for you.

If you still have the passphrase, you can write down a fresh recovery key at any
time. Mount and unlock the vault as in Level 4, then in an administrator
PowerShell:

```powershell
manage-bde -protectors -add X: -RecoveryPassword
manage-bde -protectors -get X:
```

Copy the 48-digit number that prints, and keep it off this PC.

---

## Facts about this install

| | |
|---|---|
| Vault file | `D:\apps\brave_locker\vault.vhdx` |
| Profile appears at | `C:\Users\USER\AppData\Local\BraveSoftware\Brave-Browser\User Data` |
| Program files | `C:\Program Files\BraveLocker` |
| Settings & logs | `C:\Users\USER\AppData\Local\BraveLocker` |
| Original shortcut backups | `C:\Users\USER\AppData\Local\BraveLocker\shortcut-backup` |
| Scheduled tasks | `BraveLocker-Mount`, `BraveLocker-ShortcutGuard` |
| Pre-lock profile copy | `...\Brave-Browser\User Data.premigration` |

That last one is a **second, unencrypted copy** of your profile from before the
lock was set up. It is a safety net, and it is also a copy of your browsing data
that no passphrase protects. Delete it once you are confident - but not before.

---

## If the browser is fine and you just want the lock gone

Level 3. Not `Uninstall-BraveLocker.ps1` - that restores the pre-lock copy of
your profile and deletes the vault, throwing away everything you have done in
the browser since setup.
