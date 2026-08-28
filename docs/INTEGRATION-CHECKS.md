# Integration checks

The unit tests cover the logic. These cover the parts that only a real machine
can prove: BitLocker, VHDX attach/detach, Task Scheduler and Brave itself.

Run in order. Record the actual output. A check is not passed until its output
has been seen — not assumed.

| # | Check | How | Pass condition | Result |
|---|-------|-----|----------------|--------|
| 1 | `Get-DiskImage` works unelevated | `Get-DiskImage -ImagePath 'D:\apps\brave_locker\vault.vhdx'` in a normal shell | Returns the image, or "file not found" — **not** "access denied" | **PASS** — returned "cannot find the file", so no elevation needed |
| 2 | `Unlock-BitLocker` works unelevated | After check 3, run the launcher as a normal user | Vault unlocks with no UAC prompt | **FAIL** — unelevated unlock returns "Access denied". Fallback applied: the elevated task performs the unlock, passphrase passed DPAPI-protected |
| 3 | Setup completes | Run `Install-BraveLocker.ps1` from an **elevated** shell | Recovery key displayed, profile copied, file counts match, shortcut created | **PASS** — 11576 files in, 11576 in vault; task registered; shortcut created |
| 4 | Vault is really encrypted | `Get-BitLockerVolume` while mounted | `Protection On`, `FullyEncrypted` | **PASS** — verified during the passphrase diagnostic |
| 5 | Locked vault is unreadable | With Brave closed, try to read the mount folder | Empty — the profile is not there | **PASS** — `User Data` shows 0 entries when sealed |
| 6 | No plaintext leaks into the vault file | Scan the raw `vault.vhdx` for `facebook`, `gmail`, `password`, `Login Data`, `Local State`, `Profile 3` | No matches | **PASS** — 1.44 GB scanned, **0 hits for every pattern**, including the NTFS-level names `Login Data` and `BraveProfile` |
| 7 | Correct passphrase opens Brave **with logins intact** | Shortcut, enter passphrase | Brave opens, still signed into Facebook, saved cards present | **PASS** — after the App-Bound Encryption fix. **FAILED twice before it**, see check 16 |
| 8 | Wrong passphrase never mounts | Shortcut, type garbage | "Incorrect passphrase"; `Attached: False`; nothing deleted | **PASS** — observed during the layout failures; vault stayed sealed, nothing lost |
| 9 | Cooldown escalates | Three wrong attempts in a row | 5s, then 30s, then 5m enforced | **PASS** — 5s reported after the first failure, state file showed `FailureCount: 2` |
| 10 | Failures are reported | Correct passphrase after failures | "N failed attempt(s) … most recent …" shown | pending |
| 11 | Normal close seals the vault | Close Brave | `Attached: False`, mount folder empty again | **PASS** |
| 12 | Crash recovery | `Stop-Process -Name brave -Force`, then relaunch | Launcher seals the vault left open, then proceeds | pending |
| 13 | Work browser is untouched | Chrome stays running throughout | Chrome unaffected | **PASS** — Brave is not the default browser here; `http` → Chrome, `.html` → Edge |
| 14 | No UAC on daily launch | Use the shortcut | No UAC prompt | **PASS** |
| 15 | Installed copy is hardened | `icacls "C:\Program Files\BraveLocker"` | `Users` have only `(RX)` | **PASS** — Users:(OI)(CI)(RX), SYSTEM and Administrators (F) |
| 16 | **Logins survive the move** | Open the vaulted Brave, check Facebook | Still signed in | **PASS** — only after the redesign. See below |
| 17 | **The passphrase can be retyped** | Setup seals the vault and reopens it with freshly typed input | Unlocks | **PASS** — now enforced by setup itself |
| 18 | Stray profile recovery | With the vault sealed, run `brave.exe` directly so it builds a profile in the mount folder, then launch through the locker | Stray profile moved to `stray-profile-<timestamp>`, vault mounts | pending |

Check 6 is the one that proves the encryption is doing its job. Check 16 is the
one that caught the design being wrong.

## Check 16: App-Bound Encryption — the finding that changed the design

The first two builds passed checks 3, 4, 6 and 15 and were still useless: Brave
opened from the vault signed out of everything.

Brave uses Chromium App-Bound Encryption. `Local State` holds an
`app_bound_encrypted_key` (`APPB` prefix, SYSTEM-wrapped) that only decrypts
when the profile sits at its original path.

Established by controlled experiment, not inspection:

- The legacy `encrypted_key` (`DPAPI` prefix) unwraps fine as the current user,
  so the Windows account key was intact and the vault had not broken DPAPI.
- A copy of the profile in a **plain, unencrypted folder** was logged out
  identically. **The vault was never the variable — the path was.**
- Brave does not re-key at the new path; `app_bound_encrypted_key` was byte
  identical after running there, so the data stays undecryptable.

The fix is to stop moving the profile: the vault mounts onto Brave's own profile
folder and Brave runs with no `--user-data-dir`.

**Any future change that moves the profile path reintroduces this bug.**

## Check 17: two failures that looked like one

The app-lock step once reported *"the vault would not unlock through the hidden
folder path"*, which was recorded as BitLocker refusing folder mount points.
That was wrong. It was failing **authentication**, and the folder-mount
technique had never actually been tested.

The real cause: a console `Read-Host` and a GUI dialog can sit on different
keyboard layouts, so the same keys produce different characters —
`mirmigimebira` on a Greek layout is `μιρμιγιμεβιρα`. Setup stored one and the
user later typed the other.

Two consequences, both now in the code:

- Every passphrase prompt goes through the GUI popup, never a console.
- Setup seals the vault and reopens it with freshly typed input before migrating
  anything. Verifying against the SecureString already held in memory proves the
  vault works and says nothing about whether the passphrase can be reproduced —
  which is how setup reported success three times for an unopenable vault.

Folder-mounting itself was then proved to work, in this order:

```
attach -> unlock via drive letter -> add folder access path -> drop the letter
```
