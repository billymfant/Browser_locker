# Signing, SmartScreen and antivirus

Read this before distributing the installer to anyone.

## Why this tool will be flagged

Brave Locker does, in order: relocates a browser profile, handles a password,
registers a scheduled task that runs as administrator, and mounts an encrypted
volume over the folder Brave reads its cookies from.

That is, almost exactly, the behavioural fingerprint of an infostealer. It is
not a coincidence. Chromium's App-Bound Encryption — the feature that forced
this tool's whole design — exists specifically to stop software relocating a
browser profile to read the cookies out of it.

Expect, on an unsigned build:

- **SmartScreen**: "Windows protected your PC" on first run, for every user,
  until the installer builds reputation.
- **Antivirus**: heuristic detections, particularly on the profile-copy and
  scheduled-task steps. Some engines will quarantine mid-migration, which is
  worse than refusing outright because it can interrupt the copy.
- **Browser download warnings** on the `.exe`.

None of these are bugs to fix in the code. They are the cost of the category.

## What actually helps

**Code signing certificate.** An OV certificate (roughly $200–400/year) stops
the "unknown publisher" text and gives AV vendors an identity to whitelist. An
EV certificate (roughly $300–500/year, hardware token) gets SmartScreen
reputation immediately rather than after some number of installs. Neither is
free, and neither can be faked — self-signed certificates do nothing here
because the trust comes from the CA, not the signature.

Sign both the installer and, ideally, the payload:

```powershell
signtool sign /fd SHA256 /tr http://timestamp.digicert.com /td SHA256 `
    /f mycert.pfx /p <password> dist\BraveLockerSetup-1.0.0.exe
```

Timestamping matters: without `/tr`, signatures stop validating when the
certificate expires.

**Submit for analysis.** Once signed, submit the installer to Microsoft
(https://www.microsoft.com/wdsi/filesubmission) and to the major AV vendors as a
false-positive report. This is ordinary practice for security tooling and is
usually resolved in days.

**Publish the source.** For a tool that asks people to trust it with their
browser profile, a public repository is worth more than any certificate. Anyone
suspicious can read exactly what it does. Ship checksums with each release.

## If you distribute unsigned

It is legitimate to release unsigned as an open-source project. If you do:

- Say plainly in the README that it is unsigned and SmartScreen will warn.
- Publish SHA-256 checksums for every release artefact.
- Tell people how to verify: `Get-FileHash dist\BraveLockerSetup-1.0.0.exe`.
- Do **not** tell people to disable their antivirus. Anyone willing to do that
  for a stranger's installer is exactly the person who should not run this.

## What must never be done to get around a detection

Obfuscating the scripts, packing the installer to evade signatures, or
instructing users to add exclusions before installing. All three make the tool
indistinguishable from the malware it resembles, and the second is what actual
malware does. If an engine flags it, get it reviewed — do not hide from it.
