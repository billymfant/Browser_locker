# VM test plan

Everything in this project has been verified on exactly one machine, with one
browser, by one person. That is not enough to hand it to strangers.

Chrome, Edge, Vivaldi and Opera are **code-complete and never run**. Detection
is verified and the unit tests pass, but no Chrome profile has ever been
migrated by this tool. The two worst bugs found so far — App-Bound Encryption
and the untypeable passphrase — were both invisible to unit tests and both
only appeared on a real machine, so treat "the tests pass" as meaning nothing
here.

## Before you start

- **Windows 11 Pro** VM. Home cannot run this and should be tested separately
  (see check 0).
- **Take a snapshot before every numbered section.** Several of these steps
  migrate a real profile; rolling back is the difference between a test and an
  afternoon.
- Use a **throwaway account** on whatever site you sign into. Do not test with
  an account you cannot afford to be locked out of.
- Record what actually happened, not what should have. A check is not passed
  until its output has been seen.

## 0. Windows Home refuses cleanly

On a **Home** VM, run the installer.

- [ ] It stops before copying anything
- [ ] The message names Pro/Enterprise/Education
- [ ] `C:\Program Files\BrowserLocker` was not created
- [ ] No scheduled task exists
- [ ] The browser still opens normally

The point of this check is that a Home user loses nothing by trying.

## 1. Fresh install, per browser

Repeat this whole section for **Chrome**, then **Edge**, then **Brave**.
Snapshot first each time.

**Setup:**
1. Install the browser. Open it. Sign into a throwaway account on two sites.
2. Save a password when offered. Add a bookmark. Close the browser.
3. Note the profile size and which profile directory holds the data — it is
   often `Default`, but not always. On the development machine it was
   `Profile 3`, which is precisely why that is not assumed anywhere.
4. **Snapshot.**

**Run:**
5. Run `BrowserLockerSetup-1.0.0.exe`. Expect a SmartScreen warning; it is
   unsigned.
6. Wizard: choose the browser. Check the list shows the right size and profile
   count, and that unsupported or missing browsers are greyed out with a reason.
7. Work through checks, vault location, passcode, recovery key.
8. **Write the recovery key down.** It is shown once.
9. At the typed check, type the passcode. It should unlock.

**Verify — this is the one that matters:**
- [ ] The browser opens after entering the passcode
- [ ] **You are still signed in to both sites**
- [ ] The saved password is still listed
- [ ] The bookmark is still there

If you are signed out, stop. That is the App-Bound Encryption failure
returning, and it means the vault mounted somewhere other than the browser's
own profile path. Roll back to the snapshot and report it.

## 2. The passcode actually gates it

- [ ] Close the browser; confirm the vault detaches and the profile folder is
      empty
- [ ] Click the browser shortcut; the passcode popup appears
- [ ] Cancel the popup; nothing opens, nothing changes
- [ ] Enter a **wrong** passcode: refused, vault stays sealed, nothing deleted
- [ ] Wrong twice more: the wait grows — 5s, then 30s, then 5 minutes
- [ ] Enter the correct passcode: it opens, and reports the failed attempts

## 3. Keyboard layout

Only meaningful on a VM with a second keyboard layout installed. Add Greek.

- [ ] Set a passcode with the English layout active
- [ ] At the typed check, switch to Greek and type the same keys
- [ ] It is refused, and the message says characters were non-ASCII rather than
      suggesting a typo

## 4. Stray profile recovery

With the vault sealed:

- [ ] Run the browser's `.exe` directly from Program Files
- [ ] It opens an **empty** profile — no logins. Confirm no real data is visible
- [ ] Close it, then launch through the shortcut
- [ ] The locker reports it moved a stray profile aside, and opens normally
- [ ] The stray profile still exists under
      `%LOCALAPPDATA%\BraveLocker\stray-profile-*` — it must be moved, never
      deleted

## 5. Crash recovery

- [ ] With the browser open, `Stop-Process -Name <browser> -Force`
- [ ] Relaunch through the shortcut
- [ ] It seals the vault left open, then asks for the passcode normally
- [ ] Logins are still intact afterwards

## 6. The encryption is real

With the vault sealed, from a normal (non-elevated) shell:

- [ ] `Get-ChildItem` on the profile folder shows it empty
- [ ] Scan the raw vault file for a site name you signed into, the string
      `Login Data`, and your passcode — **zero hits for all three**
- [ ] Copy the vault file to another machine and confirm it is unreadable there

## 7. Uninstall restores everything

- [ ] Uninstall from Add/Remove Programs
- [ ] Browser shortcuts point at the browser again, not the launcher
- [ ] The scheduled task is gone
- [ ] The browser opens with the original profile and no passcode
- [ ] **Your logins are still there**

## 8. The dangerous one: uninstall after cleanup

Snapshot first. This deliberately provokes the refusal.

- [ ] Complete a setup, then run `Complete-BraveLockerMigration.ps1`
- [ ] Now try to uninstall
- [ ] It **refuses**, saying the vault is the only copy of the data
- [ ] Nothing is deleted

If it does not refuse, stop and report it. That path destroys data.

## What to do with the results

Record outcomes in `docs/INTEGRATION-CHECKS.md` alongside the existing ones,
with the actual output. If a browser fails section 1, mark it unsupported in
`src/BraveLocker/Browsers.ps1` rather than shipping it hopefully — an
unsupported browser that says so is fine, and one that silently eats a profile
is not.
