# Integration checks

The unit tests cover the logic. These cover the parts that only a real machine
can prove: BitLocker, VHDX attach/detach, Task Scheduler and Brave itself.

Run in order. Record the actual output. A check is not passed until its output
has been seen — not assumed.

| # | Check | How | Pass condition | Result |
|---|-------|-----|----------------|--------|
| 1 | `Get-DiskImage` works unelevated | `Get-DiskImage -ImagePath 'D:\apps\brave_locker\vault.vhdx'` in a normal shell | Returns the image, or "file not found" — **not** "access denied" | **PASS** — returned "cannot find the file", so no elevation needed |
| 2 | `Unlock-BitLocker` works unelevated | After check 3, run the launcher as a normal user | Vault unlocks with no UAC prompt. If it demands elevation, apply the fallback below | pending |
| 3 | Setup completes | Run `Install-BraveLocker.ps1` from an **elevated** shell | Recovery key displayed, profile copied, file counts match, desktop shortcut created | pending |
| 4 | Vault is really encrypted | `manage-bde -status V:` while mounted | `Protection On`, `Percentage Encrypted: 100%` | pending |
| 5 | Locked vault is unreadable | With Brave closed: `Get-ChildItem V:\` | Fails — drive not accessible | pending |
| 6 | No plaintext leaks into the vault file | `Select-String -Path vault.vhdx -Pattern 'facebook' -Encoding unicode` | No matches | pending |
| 7 | Correct passphrase opens Brave | Desktop shortcut | Brave opens, still logged into Facebook, cards listed at `brave://settings/payments` | pending |
| 8 | Wrong passphrase never mounts | Shortcut, type garbage | "Incorrect passphrase"; `Get-DiskImage` shows `Attached: False`; nothing deleted | pending |
| 9 | Cooldown escalates | Three wrong attempts in a row | 5s, then 30s, then 5m enforced | pending |
| 10 | Failures are reported | Correct passphrase after failures | "N failed attempt(s) … most recent …" shown | pending |
| 11 | Normal close seals the vault | Close Brave | Launcher prints "Vault sealed"; `Get-DiskImage` shows `Attached: False` | pending |
| 12 | Crash recovery | `Stop-Process -Name brave -Force`, then relaunch | Launcher reports it sealed a vault left open, then proceeds normally | pending |
| 13 | Work Brave is untouched | Open normal Brave; launch the private one; close the private one | The normal Brave keeps running throughout | pending |
| 14 | No UAC on daily launch | Use the shortcut | No UAC prompt | pending |
| 15 | Installed copy is hardened | `icacls "C:\Program Files\BraveLocker"` | `Users` have only `(RX)`; no `(F)`, `(M)` or `(W)` for Users, Authenticated Users or Everyone | pending |

Check 13 is the one that protects the working day: the launcher must never kill
the work Brave. Check 6 is the one that proves the encryption is doing its job.

## Fallback if check 2 fails

If `Unlock-BitLocker` turns out to need administrator rights, the elevated task
must perform the unlock, which means the passphrase has to reach it. In that case:

- Write the passphrase into the request file with `ConvertFrom-SecureString`
  (DPAPI, CurrentUser scope — the task runs as the same user).
- Have `Invoke-BraveLockerVaultTask.ps1` delete the request file immediately
  after reading it, in its `finally` block (it already does).
- Update the spec, which currently states the task never handles the password.
  That claim would no longer be true and must not be left standing.
