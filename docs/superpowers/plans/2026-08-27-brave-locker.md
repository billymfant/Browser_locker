# Brave Locker Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Keep the user's Brave profile — Facebook session, email, saved passwords, saved cards — inside a BitLocker-encrypted VHDX that is mounted only while Brave is running, so nobody else with access to the PC can read it.

**Architecture:** A PowerShell module of small, single-responsibility files holds the logic; four entry-point scripts orchestrate it (install, launch, finish-migration, elevated vault task). Pure logic — passphrase rules, cooldown maths, attempt log, drive-letter choice, command-line matching, diskpart script generation, request/response serialisation — is unit-tested with Pester 5. The parts that touch BitLocker, VHDX and Brave itself are thin wrappers verified by a real integration run on this machine. Mounting a VHDX needs administrator rights, so install registers a highest-privileges scheduled task that performs mount/dismount on request; the user consents to UAC once at setup instead of every launch.

**Tech Stack:** Windows PowerShell 5.1, diskpart, manage-bde / BitLocker cmdlets, Task Scheduler, Pester 5 (test-only).

**Spec:** `docs/superpowers/specs/2026-08-27-brave-locker-design.md`

## Global Constraints

- **Windows PowerShell 5.1 only.** No PS7 syntax: no `&&`/`||`, no ternary, no `??`, no `?.`, no `ConvertFrom-Json -AsHashtable`.
- **No third-party software.** Pester 5 is the sole exception and is test-only, installed `-Scope CurrentUser`.
- **No Hyper-V module on this machine.** `New-VHD` does not exist. VHDX creation goes through `diskpart` script files.
- **Only Pester 3.4.0 is present** in `System32`. Tests need Pester 5.x installed to CurrentUser and imported with `-MinimumVersion 5.0`.
- **Passphrase minimum: 16 characters.** Setup refuses anything shorter.
- **A failed unlock is never destructive.** No wipe, no delete, ever. Refuse, seal, cool down, log.
- **The vault is never mounted on a failed unlock.**
- **The BitLocker recovery key is never written to disk.** Displayed once at setup; the user confirms off-machine storage.
- **Setup copies, never moves.** Deleting the plaintext original is a separate, explicit, manual script.
- Brave executable: `C:\Program Files\BraveSoftware\Brave-Browser\Application\brave.exe`
- Vault file: `D:\apps\brave_locker\vault.vhdx`
- Runtime state: `%LOCALAPPDATA%\BraveLocker\`
- Source profile: `%LOCALAPPDATA%\BraveSoftware\Brave-Browser\User Data`

## File Structure

```
D:\apps\brave_locker\
  src\BraveLocker\
    BraveLocker.psd1          module manifest
    BraveLocker.psm1          loader: dot-sources the files below, exports public functions
    Paths.ps1                 config + state path resolution
    Passphrase.ps1            passphrase rules
    AttemptLog.ps1            failed-attempt log + cooldown escalation
    DriveLetter.ps1           free drive-letter selection
    BraveProcess.ps1          find / start / wait / stop Brave by profile path
    Vault.ps1                 diskpart script generation, create/mount/unlock/dismount
    Elevation.ps1             scheduled-task request protocol, registration, ACL hardening
  scripts\
    Install-BraveLocker.ps1
    Start-BraveLocked.ps1
    Complete-BraveLockerMigration.ps1
    Invoke-BraveLockerVaultTask.ps1   runs elevated via Task Scheduler; mount/dismount only
  tests\
    Paths.Tests.ps1  Passphrase.Tests.ps1  AttemptLog.Tests.ps1
    DriveLetter.Tests.ps1  BraveProcess.Tests.ps1  Vault.Tests.ps1  Elevation.Tests.ps1
  docs\
    INTEGRATION-CHECKS.md     manual checks that cannot be unit-tested
  README.md
```

---

### Task 1: Scaffolding, module loader, path resolution

**Files:**
- Create: `src/BraveLocker/BraveLocker.psd1`, `src/BraveLocker/BraveLocker.psm1`, `src/BraveLocker/Paths.ps1`
- Create: `tests/Paths.Tests.ps1`, `.gitignore`

**Interfaces:**
- Consumes: nothing.
- Produces: `Get-BraveLockerPaths [-StateRoot <string>]` returning a `[pscustomobject]` with string properties `StateRoot`, `ConfigPath`, `StatePath`, `RequestPath`, `ResponsePath`. Every later task uses this.

- [ ] **Step 1: Initialise the repo and Pester 5**

```powershell
cd D:\apps\brave_locker
git init
Install-Module Pester -MinimumVersion 5.5.0 -Scope CurrentUser -Force -SkipPublisherCheck
Import-Module Pester -MinimumVersion 5.0 -Force
Get-Module Pester | Select-Object Version
```

Expected: Version 5.x. PSGallery is reachable from this machine (already verified).

Write `.gitignore`:

```
*.vhdx
state.json
request.json
response.json
```

- [ ] **Step 2: Write the failing test**

`tests/Paths.Tests.ps1`:

```powershell
BeforeAll {
    Import-Module "$PSScriptRoot\..\src\BraveLocker\BraveLocker.psd1" -Force
}

Describe 'Get-BraveLockerPaths' {
    It 'defaults StateRoot to LOCALAPPDATA\BraveLocker' {
        $p = Get-BraveLockerPaths
        $p.StateRoot | Should -Be (Join-Path $env:LOCALAPPDATA 'BraveLocker')
    }

    It 'honours an explicit StateRoot' {
        $p = Get-BraveLockerPaths -StateRoot 'C:\tmp\bl'
        $p.StateRoot | Should -Be 'C:\tmp\bl'
    }

    It 'derives all four file paths from StateRoot' {
        $p = Get-BraveLockerPaths -StateRoot 'C:\tmp\bl'
        $p.ConfigPath   | Should -Be 'C:\tmp\bl\config.json'
        $p.StatePath    | Should -Be 'C:\tmp\bl\state.json'
        $p.RequestPath  | Should -Be 'C:\tmp\bl\request.json'
        $p.ResponsePath | Should -Be 'C:\tmp\bl\response.json'
    }
}
```

- [ ] **Step 3: Run it and confirm it fails**

Run: `Invoke-Pester tests\Paths.Tests.ps1 -Output Detailed`
Expected: FAIL — module manifest not found.

- [ ] **Step 4: Write the module**

`src/BraveLocker/Paths.ps1`:

```powershell
function Get-BraveLockerPaths {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [string]$StateRoot
    )

    if ([string]::IsNullOrWhiteSpace($StateRoot)) {
        $StateRoot = Join-Path $env:LOCALAPPDATA 'BraveLocker'
    }

    [pscustomobject]@{
        StateRoot    = $StateRoot
        ConfigPath   = Join-Path $StateRoot 'config.json'
        StatePath    = Join-Path $StateRoot 'state.json'
        RequestPath  = Join-Path $StateRoot 'request.json'
        ResponsePath = Join-Path $StateRoot 'response.json'
    }
}
```

`src/BraveLocker/BraveLocker.psm1`:

```powershell
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
foreach ($file in 'Paths','Passphrase','AttemptLog','DriveLetter','BraveProcess','Vault','Elevation') {
    $path = Join-Path $here "$file.ps1"
    if (Test-Path $path) { . $path }
}
Export-ModuleMember -Function '*-BraveLocker*'
```

`src/BraveLocker/BraveLocker.psd1`:

```powershell
@{
    RootModule        = 'BraveLocker.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = '4f2b8c31-9d7a-4e55-b0c6-1a2d3e4f5a6b'
    Author            = 'Brave Locker'
    Description       = 'Password-protected encrypted vault for a Brave browser profile.'
    PowerShellVersion = '5.1'
    FunctionsToExport = '*'
}
```

- [ ] **Step 5: Run the tests and confirm they pass**

Run: `Invoke-Pester tests\Paths.Tests.ps1 -Output Detailed`
Expected: 3 passed.

- [ ] **Step 6: Commit**

```bash
git add .gitignore src tests docs
git commit -m "feat: scaffold BraveLocker module with path resolution"
```

---

### Task 2: Passphrase rules

**Files:**
- Create: `src/BraveLocker/Passphrase.ps1`, `tests/Passphrase.Tests.ps1`

**Interfaces:**
- Consumes: nothing.
- Produces: `Test-BraveLockerPassphrase -Passphrase <string>` returning `[pscustomobject]` with `[bool]$IsValid` and `[string]$Reason` (one of `OK`, `TooShort`, `Whitespace`). Task 8 calls this before creating the vault.

Length is the only defence that matters here, because an attacker who copies `vault.vhdx` can attack it offline where no cooldown applies.

- [ ] **Step 1: Write the failing test**

`tests/Passphrase.Tests.ps1`:

```powershell
BeforeAll {
    Import-Module "$PSScriptRoot\..\src\BraveLocker\BraveLocker.psd1" -Force
}

Describe 'Test-BraveLockerPassphrase' {
    It 'rejects a passphrase shorter than 16 characters' {
        $r = Test-BraveLockerPassphrase -Passphrase 'short-one-123'
        $r.IsValid | Should -BeFalse
        $r.Reason  | Should -Be 'TooShort'
    }

    It 'accepts exactly 16 characters' {
        $r = Test-BraveLockerPassphrase -Passphrase '1234567890123456'
        $r.IsValid | Should -BeTrue
        $r.Reason  | Should -Be 'OK'
    }

    It 'accepts a long multi-word passphrase' {
        $r = Test-BraveLockerPassphrase -Passphrase 'correct horse battery staple'
        $r.IsValid | Should -BeTrue
    }

    It 'rejects whitespace padding used to reach the minimum' {
        $r = Test-BraveLockerPassphrase -Passphrase 'abc                     '
        $r.IsValid | Should -BeFalse
        $r.Reason  | Should -Be 'Whitespace'
    }

    It 'rejects an empty passphrase' {
        (Test-BraveLockerPassphrase -Passphrase '').IsValid | Should -BeFalse
    }
}
```

- [ ] **Step 2: Run it and confirm it fails**

Run: `Invoke-Pester tests\Passphrase.Tests.ps1 -Output Detailed`
Expected: FAIL — `Test-BraveLockerPassphrase` is not recognised.

- [ ] **Step 3: Implement**

`src/BraveLocker/Passphrase.ps1`:

```powershell
$script:BraveLockerMinPassphraseLength = 16

function Test-BraveLockerPassphrase {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Passphrase
    )

    $min = $script:BraveLockerMinPassphraseLength

    if ($Passphrase.Length -lt $min) {
        return [pscustomobject]@{ IsValid = $false; Reason = 'TooShort' }
    }
    if ($Passphrase.Trim().Length -lt $min) {
        return [pscustomobject]@{ IsValid = $false; Reason = 'Whitespace' }
    }
    [pscustomobject]@{ IsValid = $true; Reason = 'OK' }
}
```

- [ ] **Step 4: Run and confirm pass**

Run: `Invoke-Pester tests\Passphrase.Tests.ps1 -Output Detailed`
Expected: 5 passed.

- [ ] **Step 5: Commit**

```bash
git add src/BraveLocker/Passphrase.ps1 tests/Passphrase.Tests.ps1
git commit -m "feat: enforce 16-character minimum passphrase"
```

---

### Task 3: Failed-attempt log and cooldown escalation

**Files:**
- Create: `src/BraveLocker/AttemptLog.ps1`, `tests/AttemptLog.Tests.ps1`

**Interfaces:**
- Consumes: `Get-BraveLockerPaths` (Task 1).
- Produces:
  - `Get-BraveLockerCooldownSeconds -FailureCount <int>` -> `[int]` (0, 5, 30, then 300)
  - `Get-BraveLockerState -StatePath <string>` -> `[pscustomobject]` with `[int]$FailureCount`, `[string]$LastFailureUtc`
  - `Save-BraveLockerState -StatePath <string> -State <pscustomobject>` -> `[void]`
  - `Add-BraveLockerFailedAttempt -StatePath <string> -NowUtc <datetime>` -> `[int]` the new failure count
  - `Clear-BraveLockerFailedAttempts -StatePath <string>` -> `[pscustomobject]` the state *before* clearing, so the launcher can report it
  - `Get-BraveLockerRemainingCooldownSeconds -StatePath <string> -NowUtc <datetime>` -> `[int]`

- [ ] **Step 1: Write the failing test**

`tests/AttemptLog.Tests.ps1`:

```powershell
BeforeAll {
    Import-Module "$PSScriptRoot\..\src\BraveLocker\BraveLocker.psd1" -Force
}

Describe 'Get-BraveLockerCooldownSeconds' {
    It 'is zero with no failures'      { Get-BraveLockerCooldownSeconds -FailureCount 0 | Should -Be 0 }
    It 'is 5 seconds after one'        { Get-BraveLockerCooldownSeconds -FailureCount 1 | Should -Be 5 }
    It 'is 30 seconds after two'       { Get-BraveLockerCooldownSeconds -FailureCount 2 | Should -Be 30 }
    It 'is 5 minutes after three'      { Get-BraveLockerCooldownSeconds -FailureCount 3 | Should -Be 300 }
    It 'holds at 5 minutes after many' { Get-BraveLockerCooldownSeconds -FailureCount 9 | Should -Be 300 }
}

Describe 'attempt log' {
    BeforeEach {
        $script:statePath = Join-Path $TestDrive ((New-Guid).Guid + '\state.json')
        $script:now = [datetime]::new(2026, 8, 27, 14, 22, 0, [datetimekind]::Utc)
    }

    It 'reports zero failures when no state file exists' {
        (Get-BraveLockerState -StatePath $script:statePath).FailureCount | Should -Be 0
    }

    It 'increments the failure count and persists it' {
        Add-BraveLockerFailedAttempt -StatePath $script:statePath -NowUtc $script:now | Should -Be 1
        Add-BraveLockerFailedAttempt -StatePath $script:statePath -NowUtc $script:now | Should -Be 2
        (Get-BraveLockerState -StatePath $script:statePath).FailureCount | Should -Be 2
    }

    It 'records the most recent failure time' {
        Add-BraveLockerFailedAttempt -StatePath $script:statePath -NowUtc $script:now | Out-Null
        $s = Get-BraveLockerState -StatePath $script:statePath
        ([datetime]$s.LastFailureUtc).ToUniversalTime().Hour | Should -Be 14
    }

    It 'returns the prior state when cleared, then resets to zero' {
        Add-BraveLockerFailedAttempt -StatePath $script:statePath -NowUtc $script:now | Out-Null
        (Clear-BraveLockerFailedAttempts -StatePath $script:statePath).FailureCount | Should -Be 1
        (Get-BraveLockerState -StatePath $script:statePath).FailureCount | Should -Be 0
    }

    It 'reports remaining cooldown immediately after a failure' {
        Add-BraveLockerFailedAttempt -StatePath $script:statePath -NowUtc $script:now | Out-Null
        Get-BraveLockerRemainingCooldownSeconds -StatePath $script:statePath -NowUtc $script:now | Should -Be 5
    }

    It 'reports no remaining cooldown once it has elapsed' {
        Add-BraveLockerFailedAttempt -StatePath $script:statePath -NowUtc $script:now | Out-Null
        Get-BraveLockerRemainingCooldownSeconds -StatePath $script:statePath -NowUtc $script:now.AddSeconds(6) |
            Should -Be 0
    }

    It 'treats a corrupt state file as no failures rather than throwing' {
        New-Item -ItemType Directory -Path (Split-Path -Parent $script:statePath) -Force | Out-Null
        Set-Content -Path $script:statePath -Value 'not json at all' -Encoding utf8
        (Get-BraveLockerState -StatePath $script:statePath).FailureCount | Should -Be 0
    }
}
```

That last case matters: a corrupt or hand-edited state file must never lock the user out of their own browser.

- [ ] **Step 2: Run it and confirm it fails**

Run: `Invoke-Pester tests\AttemptLog.Tests.ps1 -Output Detailed`
Expected: FAIL — commands not recognised.

- [ ] **Step 3: Implement**

`src/BraveLocker/AttemptLog.ps1`:

```powershell
function Get-BraveLockerCooldownSeconds {
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Mandatory)][int]$FailureCount)

    if ($FailureCount -le 0) { return 0 }
    if ($FailureCount -eq 1) { return 5 }
    if ($FailureCount -eq 2) { return 30 }
    return 300
}

function Get-BraveLockerState {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string]$StatePath)

    $empty = [pscustomobject]@{ FailureCount = 0; LastFailureUtc = '' }
    if (-not (Test-Path $StatePath)) { return $empty }

    try {
        $obj = Get-Content -Path $StatePath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    } catch {
        return $empty
    }

    $count = 0
    if ($null -ne $obj.FailureCount) { $count = [int]$obj.FailureCount }
    $last = ''
    if ($null -ne $obj.LastFailureUtc) { $last = [string]$obj.LastFailureUtc }

    [pscustomobject]@{ FailureCount = $count; LastFailureUtc = $last }
}

function Save-BraveLockerState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$StatePath,
        [Parameter(Mandatory)][pscustomobject]$State
    )

    $dir = Split-Path -Parent $StatePath
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $State | ConvertTo-Json -Depth 5 | Set-Content -Path $StatePath -Encoding utf8
}

function Add-BraveLockerFailedAttempt {
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)][string]$StatePath,
        [Parameter(Mandatory)][datetime]$NowUtc
    )

    $state = Get-BraveLockerState -StatePath $StatePath
    $next = [pscustomobject]@{
        FailureCount   = $state.FailureCount + 1
        LastFailureUtc = $NowUtc.ToUniversalTime().ToString('o')
    }
    Save-BraveLockerState -StatePath $StatePath -State $next
    $next.FailureCount
}

function Clear-BraveLockerFailedAttempts {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string]$StatePath)

    $prior = Get-BraveLockerState -StatePath $StatePath
    Save-BraveLockerState -StatePath $StatePath -State ([pscustomobject]@{
        FailureCount = 0; LastFailureUtc = ''
    })
    $prior
}

function Get-BraveLockerRemainingCooldownSeconds {
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)][string]$StatePath,
        [Parameter(Mandatory)][datetime]$NowUtc
    )

    $state = Get-BraveLockerState -StatePath $StatePath
    if ($state.FailureCount -le 0) { return 0 }
    if ([string]::IsNullOrWhiteSpace($state.LastFailureUtc)) { return 0 }

    $cooldown = Get-BraveLockerCooldownSeconds -FailureCount $state.FailureCount
    $elapsed = ($NowUtc.ToUniversalTime() - ([datetime]$state.LastFailureUtc).ToUniversalTime()).TotalSeconds
    $remaining = [int][math]::Ceiling($cooldown - $elapsed)
    if ($remaining -lt 0) { return 0 }
    $remaining
}
```

- [ ] **Step 4: Run and confirm pass**

Run: `Invoke-Pester tests\AttemptLog.Tests.ps1 -Output Detailed`
Expected: 12 passed.

- [ ] **Step 5: Commit**

```bash
git add src/BraveLocker/AttemptLog.ps1 tests/AttemptLog.Tests.ps1
git commit -m "feat: non-destructive failed-attempt log with escalating cooldown"
```

---

### Task 4: Free drive-letter selection

**Files:**
- Create: `src/BraveLocker/DriveLetter.ps1`, `tests/DriveLetter.Tests.ps1`

**Interfaces:**
- Consumes: nothing.
- Produces: `Get-BraveLockerFreeDriveLetter [-Preferred <string>] [-UsedLetters <string[]>]` -> `[string]`, a single uppercase letter. Omitting `-UsedLetters` queries the live system; passing it makes the function pure and testable. Throws if nothing from E to Z is free.

- [ ] **Step 1: Write the failing test**

`tests/DriveLetter.Tests.ps1`:

```powershell
BeforeAll {
    Import-Module "$PSScriptRoot\..\src\BraveLocker\BraveLocker.psd1" -Force
}

Describe 'Get-BraveLockerFreeDriveLetter' {
    It 'returns the preferred letter when it is free' {
        Get-BraveLockerFreeDriveLetter -Preferred 'V' -UsedLetters @('C','D') | Should -Be 'V'
    }

    It 'falls back to the highest free letter when the preferred one is taken' {
        Get-BraveLockerFreeDriveLetter -Preferred 'V' -UsedLetters @('C','D','V','Z','Y') | Should -Be 'X'
    }

    It 'is case-insensitive about used letters' {
        Get-BraveLockerFreeDriveLetter -Preferred 'v' -UsedLetters @('c','v') | Should -Be 'Z'
    }

    It 'throws when every letter from E to Z is taken' {
        $used = 69..90 | ForEach-Object { [string][char]$_ }
        { Get-BraveLockerFreeDriveLetter -Preferred 'V' -UsedLetters $used } |
            Should -Throw -ExpectedMessage '*no free drive letter*'
    }
}
```

- [ ] **Step 2: Run it and confirm it fails**

Run: `Invoke-Pester tests\DriveLetter.Tests.ps1 -Output Detailed`
Expected: FAIL — command not recognised.

- [ ] **Step 3: Implement**

`src/BraveLocker/DriveLetter.ps1`:

```powershell
function Get-BraveLockerFreeDriveLetter {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [string]$Preferred = 'V',
        [string[]]$UsedLetters
    )

    if ($null -eq $UsedLetters) {
        $UsedLetters = @(Get-PSDrive -PSProvider FileSystem | ForEach-Object { $_.Name })
    }

    $used = @($UsedLetters | ForEach-Object { $_.ToString().ToUpperInvariant() })
    $want = $Preferred.ToString().ToUpperInvariant()

    if ($want -and ($used -notcontains $want)) { return $want }

    # Walk down from Z so the vault lands clear of anything the user plugs in.
    foreach ($code in 90..69) {
        $letter = [string][char]$code
        if ($used -notcontains $letter) { return $letter }
    }

    throw 'Brave Locker: no free drive letter between E and Z is available for the vault.'
}
```

- [ ] **Step 4: Run and confirm pass**

Run: `Invoke-Pester tests\DriveLetter.Tests.ps1 -Output Detailed`
Expected: 4 passed.

- [ ] **Step 5: Commit**

```bash
git add src/BraveLocker/DriveLetter.ps1 tests/DriveLetter.Tests.ps1
git commit -m "feat: select a free drive letter for the mounted vault"
```

---

### Task 5: Finding, starting, waiting on and stopping Brave

**Files:**
- Create: `src/BraveLocker/BraveProcess.ps1`, `tests/BraveProcess.Tests.ps1`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `Test-BraveLockerCommandLineMatch -CommandLine <string> -ProfilePath <string>` -> `[bool]` (pure; the unit-tested core)
  - `Get-BraveLockerBrowserProcess -ProfilePath <string>` -> CIM process objects
  - `Start-BraveLockerBrowser -BraveExe <string> -ProfilePath <string>` -> `[System.Diagnostics.Process]`
  - `Wait-BraveLockerBrowserExit -ProfilePath <string> [-PollSeconds <int>]` -> `[void]`
  - `Stop-BraveLockerBrowser -ProfilePath <string> [-TimeoutSeconds <int>]` -> `[bool]`, true when nothing is left running

Command-line matching is what ties a Brave process to *our* vault profile. Get it wrong and the launcher kills the user's work Brave, so it is tested hard: quoted and unquoted forms, trailing backslash, case, and the prefix case where `V:\BraveProfileBackup` must not match `V:\BraveProfile`.

- [ ] **Step 1: Write the failing test**

`tests/BraveProcess.Tests.ps1`:

```powershell
BeforeAll {
    Import-Module "$PSScriptRoot\..\src\BraveLocker\BraveLocker.psd1" -Force
}

Describe 'Test-BraveLockerCommandLineMatch' {
    It 'matches an unquoted user-data-dir' {
        Test-BraveLockerCommandLineMatch -ProfilePath 'V:\BraveProfile' `
            -CommandLine '"C:\brave.exe" --user-data-dir=V:\BraveProfile' | Should -BeTrue
    }

    It 'matches a quoted user-data-dir among other switches' {
        Test-BraveLockerCommandLineMatch -ProfilePath 'V:\BraveProfile' `
            -CommandLine '"C:\brave.exe" --user-data-dir="V:\BraveProfile" --type=renderer' | Should -BeTrue
    }

    It 'matches regardless of a trailing backslash' {
        Test-BraveLockerCommandLineMatch -ProfilePath 'V:\BraveProfile' `
            -CommandLine '"C:\brave.exe" --user-data-dir=V:\BraveProfile\' | Should -BeTrue
    }

    It 'is case-insensitive' {
        Test-BraveLockerCommandLineMatch -ProfilePath 'V:\BraveProfile' `
            -CommandLine '"C:\brave.exe" --user-data-dir=v:\braveprofile' | Should -BeTrue
    }

    It 'does NOT match the ordinary work Brave' {
        Test-BraveLockerCommandLineMatch -ProfilePath 'V:\BraveProfile' `
            -CommandLine '"C:\brave.exe"' | Should -BeFalse
    }

    It 'does NOT match a different profile directory' {
        Test-BraveLockerCommandLineMatch -ProfilePath 'V:\BraveProfile' `
            -CommandLine '"C:\brave.exe" --user-data-dir=V:\OtherProfile' | Should -BeFalse
    }

    It 'does NOT match a profile path that is merely a prefix' {
        Test-BraveLockerCommandLineMatch -ProfilePath 'V:\BraveProfile' `
            -CommandLine '"C:\brave.exe" --user-data-dir=V:\BraveProfileBackup' | Should -BeFalse
    }

    It 'handles an empty command line without throwing' {
        Test-BraveLockerCommandLineMatch -CommandLine '' -ProfilePath 'V:\BraveProfile' | Should -BeFalse
    }
}
```

- [ ] **Step 2: Run it and confirm it fails**

Run: `Invoke-Pester tests\BraveProcess.Tests.ps1 -Output Detailed`
Expected: FAIL — command not recognised.

- [ ] **Step 3: Implement**

`src/BraveLocker/BraveProcess.ps1`:

```powershell
function Test-BraveLockerCommandLineMatch {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][AllowNull()][string]$CommandLine,
        [Parameter(Mandatory)][string]$ProfilePath
    )

    if ([string]::IsNullOrWhiteSpace($CommandLine)) { return $false }

    $wanted = $ProfilePath.TrimEnd('\').ToUpperInvariant()
    $pattern = '--user-data-dir=("?)([^"]*?)\1(\s|$)'

    foreach ($m in [regex]::Matches($CommandLine, $pattern)) {
        $value = $m.Groups[2].Value.Trim().TrimEnd('\').ToUpperInvariant()
        if ($value -eq $wanted) { return $true }
    }
    $false
}

function Get-BraveLockerBrowserProcess {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ProfilePath)

    Get-CimInstance Win32_Process -Filter "Name='brave.exe'" -ErrorAction SilentlyContinue |
        Where-Object { Test-BraveLockerCommandLineMatch -CommandLine $_.CommandLine -ProfilePath $ProfilePath }
}

function Start-BraveLockerBrowser {
    [CmdletBinding()]
    [OutputType([System.Diagnostics.Process])]
    param(
        [Parameter(Mandatory)][string]$BraveExe,
        [Parameter(Mandatory)][string]$ProfilePath
    )

    if (-not (Test-Path $BraveExe)) {
        throw "Brave Locker: Brave was not found at '$BraveExe'."
    }
    if (-not (Test-Path $ProfilePath)) {
        New-Item -ItemType Directory -Path $ProfilePath -Force | Out-Null
    }

    Start-Process -FilePath $BraveExe -ArgumentList "--user-data-dir=`"$ProfilePath`"" -PassThru
}

function Wait-BraveLockerBrowserExit {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProfilePath,
        [int]$PollSeconds = 2
    )

    # Brave forks helper processes and the launcher process can exit early, so
    # poll for any process still using this profile rather than waiting on a handle.
    while (@(Get-BraveLockerBrowserProcess -ProfilePath $ProfilePath).Count -gt 0) {
        Start-Sleep -Seconds $PollSeconds
    }
}

function Stop-BraveLockerBrowser {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$ProfilePath,
        [int]$TimeoutSeconds = 15
    )

    $procs = @(Get-BraveLockerBrowserProcess -ProfilePath $ProfilePath)
    if ($procs.Count -eq 0) { return $true }

    foreach ($p in $procs) {
        Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
    }

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if (@(Get-BraveLockerBrowserProcess -ProfilePath $ProfilePath).Count -eq 0) { return $true }
        Start-Sleep -Milliseconds 500
    }
    return (@(Get-BraveLockerBrowserProcess -ProfilePath $ProfilePath).Count -eq 0)
}
```

- [ ] **Step 4: Run and confirm pass**

Run: `Invoke-Pester tests\BraveProcess.Tests.ps1 -Output Detailed`
Expected: 8 passed.

- [ ] **Step 5: Commit**

```bash
git add src/BraveLocker/BraveProcess.ps1 tests/BraveProcess.Tests.ps1
git commit -m "feat: identify Brave processes by vault profile path"
```

---

### Task 6: The vault — create, mount, unlock, lock, dismount

**Files:**
- Create: `src/BraveLocker/Vault.ps1`, `tests/Vault.Tests.ps1`

**Interfaces:**
- Consumes: `Get-BraveLockerFreeDriveLetter` (Task 4).
- Produces:
  - `New-BraveLockerDiskpartScript -VhdxPath <string> -MaximumSizeMB <int> -DriveLetter <string>` -> `[string]` (pure; unit-tested)
  - `New-BraveLockerVault -VhdxPath <string> -MaximumSizeMB <int> -DriveLetter <string>` -> `[void]` (runs diskpart)
  - `Mount-BraveLockerVault -VhdxPath <string>` -> `[string]` drive letter of the attached (still locked) volume
  - `Unlock-BraveLockerVault -DriveLetter <string> -Passphrase <securestring>` -> `[bool]` (false on wrong passphrase, never throws)
  - `Dismount-BraveLockerVault -VhdxPath <string>` -> `[void]`
  - `Test-BraveLockerVaultMounted -VhdxPath <string>` -> `[bool]`

`New-VHD` does not exist on this machine, so **creation** goes through a generated diskpart script. Attach and detach use `Mount-DiskImage` / `Dismount-DiskImage`, which are present and far easier to error-check than parsing diskpart output.

- [ ] **Step 1: Settle the unelevated-unlock question before writing code**

This decides the shape of Tasks 7 and 9, so resolve it first. `Get-BitLockerVolume` returns *Access denied* when not elevated, which means the BitLocker **cmdlets** need admin. Whether `manage-bde -unlock` also needs admin is the open question — unlocking a data volume from Explorer does not.

Run, in a **non-elevated** shell, against any BitLocker-protected data volume (or defer until Task 8 has created the vault, then come back and run it):

```powershell
manage-bde -status V:
manage-bde -unlock V: -password
```

Record which of these is true in `docs/INTEGRATION-CHECKS.md`:

- **Unlock works unelevated (expected).** Keep the design as specced: the elevated task only attaches and detaches the VHDX, and the passphrase never leaves the user's own shell.
- **Unlock requires elevation (fallback).** Then the elevated task must perform the unlock too, and the passphrase has to reach it. In that case: write it to the request file protected with `ConvertTo-SecureString` / `ConvertFrom-SecureString` (DPAPI, CurrentUser scope — the task runs as the same user), and have the task delete the request file immediately after reading it, in a `finally` block. Update the spec's claim that "it never handles the password", because it would no longer be true.

Do not skip this step and assume the happy path.

- [ ] **Step 2: Write the failing test**

`tests/Vault.Tests.ps1`:

```powershell
BeforeAll {
    Import-Module "$PSScriptRoot\..\src\BraveLocker\BraveLocker.psd1" -Force
}

Describe 'New-BraveLockerDiskpartScript' {
    BeforeEach {
        $script:s = New-BraveLockerDiskpartScript -VhdxPath 'D:\apps\brave_locker\vault.vhdx' `
                        -MaximumSizeMB 32768 -DriveLetter 'V'
    }

    It 'creates an expandable vdisk of the requested size' {
        $script:s | Should -Match 'create vdisk file="D:\\apps\\brave_locker\\vault\.vhdx" maximum=32768 type=expandable'
    }

    It 'attaches, partitions, formats NTFS and assigns the letter, in that order' {
        $lines = $script:s -split "`r?`n" | Where-Object { $_ -ne '' }
        ($lines -join '|') | Should -Match 'attach vdisk.*create partition primary.*format fs=ntfs quick.*assign letter=V'
    }

    It 'labels the volume so it is recognisable in Explorer' {
        $script:s | Should -Match 'label="BraveVault"'
    }

    It 'quotes the path so spaces cannot break the script' {
        $s2 = New-BraveLockerDiskpartScript -VhdxPath 'D:\my apps\vault.vhdx' -MaximumSizeMB 100 -DriveLetter 'X'
        $s2 | Should -Match 'file="D:\\my apps\\vault\.vhdx"'
    }

    It 'rejects a size below 1024 MB' {
        { New-BraveLockerDiskpartScript -VhdxPath 'D:\v.vhdx' -MaximumSizeMB 10 -DriveLetter 'V' } |
            Should -Throw -ExpectedMessage '*at least 1024*'
    }
}
```

- [ ] **Step 3: Run it and confirm it fails**

Run: `Invoke-Pester tests\Vault.Tests.ps1 -Output Detailed`
Expected: FAIL — command not recognised.

- [ ] **Step 4: Implement**

`src/BraveLocker/Vault.ps1`:

```powershell
function New-BraveLockerDiskpartScript {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$VhdxPath,
        [Parameter(Mandatory)][int]$MaximumSizeMB,
        [Parameter(Mandatory)][string]$DriveLetter
    )

    if ($MaximumSizeMB -lt 1024) {
        throw "Brave Locker: the vault must be at least 1024 MB; got $MaximumSizeMB."
    }

    $letter = $DriveLetter.TrimEnd(':').ToUpperInvariant()

    @(
        "create vdisk file=`"$VhdxPath`" maximum=$MaximumSizeMB type=expandable"
        "select vdisk file=`"$VhdxPath`""
        'attach vdisk'
        'convert gpt'
        'create partition primary'
        'format fs=ntfs quick label="BraveVault"'
        "assign letter=$letter"
    ) -join "`r`n"
}

function New-BraveLockerVault {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$VhdxPath,
        [Parameter(Mandatory)][int]$MaximumSizeMB,
        [Parameter(Mandatory)][string]$DriveLetter
    )

    if (Test-Path $VhdxPath) {
        throw "Brave Locker: a vault already exists at '$VhdxPath'. Refusing to overwrite it."
    }

    $dir = Split-Path -Parent $VhdxPath
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

    $script = New-BraveLockerDiskpartScript -VhdxPath $VhdxPath -MaximumSizeMB $MaximumSizeMB -DriveLetter $DriveLetter
    $scriptFile = Join-Path $env:TEMP ("bravelocker-" + [guid]::NewGuid().ToString() + ".txt")

    try {
        Set-Content -Path $scriptFile -Value $script -Encoding ascii
        $output = & diskpart.exe /s $scriptFile 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "Brave Locker: diskpart failed creating the vault.`r`n$($output -join "`r`n")"
        }
    } finally {
        Remove-Item -Path $scriptFile -Force -ErrorAction SilentlyContinue
    }
}

function Test-BraveLockerVaultMounted {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$VhdxPath)

    if (-not (Test-Path $VhdxPath)) { return $false }
    $image = Get-DiskImage -ImagePath $VhdxPath -ErrorAction SilentlyContinue
    if ($null -eq $image) { return $false }
    [bool]$image.Attached
}

function Mount-BraveLockerVault {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$VhdxPath)

    if (-not (Test-Path $VhdxPath)) {
        throw "Brave Locker: no vault found at '$VhdxPath'."
    }

    if (-not (Test-BraveLockerVaultMounted -VhdxPath $VhdxPath)) {
        Mount-DiskImage -ImagePath $VhdxPath -StorageType VHDX -ErrorAction Stop | Out-Null
    }

    # The volume is still BitLocker-locked at this point; it has a drive letter
    # but its contents are unreadable until Unlock-BraveLockerVault succeeds.
    $letter = Get-DiskImage -ImagePath $VhdxPath |
        Get-Disk |
        Get-Partition -ErrorAction SilentlyContinue |
        Where-Object { $_.DriveLetter } |
        Select-Object -First 1 -ExpandProperty DriveLetter

    if (-not $letter) {
        throw "Brave Locker: the vault attached but Windows gave it no drive letter."
    }
    [string]$letter
}

function Unlock-BraveLockerVault {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$DriveLetter,
        [Parameter(Mandatory)][securestring]$Passphrase
    )

    $mount = $DriveLetter.TrimEnd(':').ToUpperInvariant() + ':'
    try {
        Unlock-BitLocker -MountPoint $mount -Password $Passphrase -ErrorAction Stop | Out-Null
        return $true
    } catch {
        # A wrong passphrase is an expected outcome, not an exceptional one.
        Write-Verbose "Unlock failed: $($_.Exception.Message)"
        return $false
    }
}

function Dismount-BraveLockerVault {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$VhdxPath)

    if (-not (Test-BraveLockerVaultMounted -VhdxPath $VhdxPath)) { return }
    Dismount-DiskImage -ImagePath $VhdxPath -ErrorAction Stop | Out-Null
}
```

- [ ] **Step 5: Run and confirm pass**

Run: `Invoke-Pester tests\Vault.Tests.ps1 -Output Detailed`
Expected: 5 passed. Only the pure script generator is unit-tested here; the mount/unlock/dismount wrappers are covered by the integration run in Task 10.

- [ ] **Step 6: Commit**

```bash
git add src/BraveLocker/Vault.ps1 tests/Vault.Tests.ps1 docs/INTEGRATION-CHECKS.md
git commit -m "feat: create, mount, unlock and dismount the encrypted vault"
```

---

### Task 7: Elevated mount helper and script-directory hardening

**Files:**
- Create: `src/BraveLocker/Elevation.ps1`, `scripts/Invoke-BraveLockerVaultTask.ps1`, `tests/Elevation.Tests.ps1`

**Interfaces:**
- Consumes: `Get-BraveLockerPaths` (Task 1), `Mount-BraveLockerVault` / `Dismount-BraveLockerVault` (Task 6).
- Produces:
  - `New-BraveLockerVaultRequest -Action <string> -VhdxPath <string>` -> `[pscustomobject]` with `Action`, `VhdxPath`, `RequestId`, `CreatedUtc`
  - `Test-BraveLockerVaultResponse -Response <pscustomobject> -RequestId <string>` -> `[bool]`
  - `Test-BraveLockerAclHardened -IcaclsOutput <string[]>` -> `[bool]`
  - `Register-BraveLockerMountTask -TaskName <string> -ScriptPath <string>` -> `[void]` (needs admin)
  - `Set-BraveLockerScriptAcl -Path <string>` -> `[void]` (needs admin)
  - `Invoke-BraveLockerMountTask -Action <string> -VhdxPath <string> [-TaskName <string>] [-TimeoutSeconds <int>]` -> `[pscustomobject]` with `Success`, `DriveLetter`, `Error`

Why a scheduled task at all: attaching a VHDX requires administrator rights, and prompting for UAC on every launch would make the tool unusable. A task registered once at setup, running as this user with highest privileges, performs only attach and detach.

Why the ACL step is not optional: that task runs a script from `D:\apps\brave_locker\scripts` **with elevated rights**. If any non-administrator can write to that directory, they can replace the script and get code execution as admin. Hardening the directory is what stops this tool from becoming a privilege-escalation hole.

- [ ] **Step 1: Write the failing test**

`tests/Elevation.Tests.ps1`:

```powershell
BeforeAll {
    Import-Module "$PSScriptRoot\..\src\BraveLocker\BraveLocker.psd1" -Force
}

Describe 'New-BraveLockerVaultRequest' {
    It 'carries the action and path' {
        $r = New-BraveLockerVaultRequest -Action 'Mount' -VhdxPath 'D:\v.vhdx'
        $r.Action   | Should -Be 'Mount'
        $r.VhdxPath | Should -Be 'D:\v.vhdx'
    }

    It 'gives every request a distinct id' {
        $a = New-BraveLockerVaultRequest -Action 'Mount' -VhdxPath 'D:\v.vhdx'
        $b = New-BraveLockerVaultRequest -Action 'Mount' -VhdxPath 'D:\v.vhdx'
        $a.RequestId | Should -Not -Be $b.RequestId
    }

    It 'rejects an unknown action' {
        { New-BraveLockerVaultRequest -Action 'Delete' -VhdxPath 'D:\v.vhdx' } | Should -Throw
    }
}

Describe 'Test-BraveLockerVaultResponse' {
    It 'accepts a response whose id matches the request' {
        $resp = [pscustomobject]@{ RequestId = 'abc'; Success = $true }
        Test-BraveLockerVaultResponse -Response $resp -RequestId 'abc' | Should -BeTrue
    }

    It 'rejects a stale response from an earlier request' {
        $resp = [pscustomobject]@{ RequestId = 'old'; Success = $true }
        Test-BraveLockerVaultResponse -Response $resp -RequestId 'new' | Should -BeFalse
    }

    It 'rejects a null response' {
        Test-BraveLockerVaultResponse -Response $null -RequestId 'abc' | Should -BeFalse
    }
}

Describe 'Test-BraveLockerAclHardened' {
    It 'accepts an ACL where only admins and SYSTEM can write' {
        $out = @(
            'D:\apps\brave_locker\scripts BUILTIN\Administrators:(OI)(CI)(F)'
            '                             NT AUTHORITY\SYSTEM:(OI)(CI)(F)'
            '                             BUILTIN\Users:(OI)(CI)(RX)'
        )
        Test-BraveLockerAclHardened -IcaclsOutput $out | Should -BeTrue
    }

    It 'rejects an ACL granting Users full control' {
        $out = @(
            'D:\apps\brave_locker\scripts BUILTIN\Administrators:(OI)(CI)(F)'
            '                             BUILTIN\Users:(OI)(CI)(F)'
        )
        Test-BraveLockerAclHardened -IcaclsOutput $out | Should -BeFalse
    }

    It 'rejects an ACL granting Users modify' {
        $out = @('D:\x BUILTIN\Users:(OI)(CI)(M)')
        Test-BraveLockerAclHardened -IcaclsOutput $out | Should -BeFalse
    }

    It 'rejects an ACL granting Authenticated Users write' {
        $out = @('D:\x NT AUTHORITY\Authenticated Users:(OI)(CI)(W)')
        Test-BraveLockerAclHardened -IcaclsOutput $out | Should -BeFalse
    }
}
```

- [ ] **Step 2: Run it and confirm it fails**

Run: `Invoke-Pester tests\Elevation.Tests.ps1 -Output Detailed`
Expected: FAIL — commands not recognised.

- [ ] **Step 3: Implement the module side**

`src/BraveLocker/Elevation.ps1`:

```powershell
$script:BraveLockerTaskName = 'BraveLocker-Mount'

function New-BraveLockerVaultRequest {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][ValidateSet('Mount','Dismount')][string]$Action,
        [Parameter(Mandatory)][string]$VhdxPath
    )

    [pscustomobject]@{
        RequestId  = [guid]::NewGuid().ToString()
        Action     = $Action
        VhdxPath   = $VhdxPath
        CreatedUtc = (Get-Date).ToUniversalTime().ToString('o')
    }
}

function Test-BraveLockerVaultResponse {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][AllowNull()]$Response,
        [Parameter(Mandatory)][string]$RequestId
    )

    if ($null -eq $Response) { return $false }
    if ($null -eq $Response.RequestId) { return $false }
    [string]$Response.RequestId -eq $RequestId
}

function Test-BraveLockerAclHardened {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][AllowEmptyCollection()][string[]]$IcaclsOutput)

    $risky = 'Users', 'Authenticated Users', 'Everyone', 'INTERACTIVE'

    foreach ($line in $IcaclsOutput) {
        foreach ($principal in $risky) {
            if ($line -notmatch [regex]::Escape($principal) + '\s*:') { continue }
            # (F)ull, (M)odify, (W)rite all let a non-admin replace the elevated script.
            if ($line -match '\((F|M|W)\)') { return $false }
        }
    }
    $true
}

function Set-BraveLockerScriptAcl {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $output = & icacls.exe $Path /inheritance:r `
        /grant:r 'BUILTIN\Administrators:(OI)(CI)F' `
                 'NT AUTHORITY\SYSTEM:(OI)(CI)F' `
                 'BUILTIN\Users:(OI)(CI)RX' 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Brave Locker: failed to harden '$Path'.`r`n$($output -join "`r`n")"
    }

    $verify = & icacls.exe $Path 2>&1
    if (-not (Test-BraveLockerAclHardened -IcaclsOutput @($verify))) {
        throw "Brave Locker: '$Path' is still writable by non-administrators after hardening. Refusing to continue, because the elevated task would be hijackable."
    }
}

function Register-BraveLockerMountTask {
    [CmdletBinding()]
    param(
        [string]$TaskName = $script:BraveLockerTaskName,
        [Parameter(Mandatory)][string]$ScriptPath
    )

    if (-not (Test-Path $ScriptPath)) {
        throw "Brave Locker: cannot register the mount task; '$ScriptPath' does not exist."
    }

    $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
        -Argument ('-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}"' -f $ScriptPath)

    $principal = New-ScheduledTaskPrincipal -UserId ("{0}\{1}" -f $env:USERDOMAIN, $env:USERNAME) `
        -LogonType Interactive -RunLevel Highest

    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -ExecutionTimeLimit (New-TimeSpan -Minutes 5) -MultipleInstances IgnoreNew

    Register-ScheduledTask -TaskName $TaskName -Action $action -Principal $principal `
        -Settings $settings -Description 'Attaches and detaches the Brave Locker vault.' -Force | Out-Null
}

function Invoke-BraveLockerMountTask {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][ValidateSet('Mount','Dismount')][string]$Action,
        [Parameter(Mandatory)][string]$VhdxPath,
        [string]$TaskName = $script:BraveLockerTaskName,
        [int]$TimeoutSeconds = 60
    )

    $paths = Get-BraveLockerPaths
    if (-not (Test-Path $paths.StateRoot)) {
        New-Item -ItemType Directory -Path $paths.StateRoot -Force | Out-Null
    }

    Remove-Item -Path $paths.ResponsePath -Force -ErrorAction SilentlyContinue

    $request = New-BraveLockerVaultRequest -Action $Action -VhdxPath $VhdxPath
    $request | ConvertTo-Json -Depth 5 | Set-Content -Path $paths.RequestPath -Encoding utf8

    Start-ScheduledTask -TaskName $TaskName -ErrorAction Stop

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if (Test-Path $paths.ResponsePath) {
            try {
                $resp = Get-Content -Path $paths.ResponsePath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            } catch {
                $resp = $null
            }
            if (Test-BraveLockerVaultResponse -Response $resp -RequestId $request.RequestId) {
                return [pscustomobject]@{
                    Success     = [bool]$resp.Success
                    DriveLetter = [string]$resp.DriveLetter
                    Error       = [string]$resp.Error
                }
            }
        }
        Start-Sleep -Milliseconds 300
    }

    [pscustomobject]@{
        Success     = $false
        DriveLetter = ''
        Error       = "The vault task did not respond within $TimeoutSeconds seconds."
    }
}
```

- [ ] **Step 4: Implement the elevated task script**

`scripts/Invoke-BraveLockerVaultTask.ps1` — this is the only code that runs with administrator rights. It attaches and detaches; it does nothing else.

```powershell
#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot '..\src\BraveLocker\BraveLocker.psd1') -Force

$paths = Get-BraveLockerPaths
$response = [pscustomobject]@{ RequestId = ''; Success = $false; DriveLetter = ''; Error = '' }

try {
    if (-not (Test-Path $paths.RequestPath)) {
        throw 'No request file present.'
    }

    $request = Get-Content -Path $paths.RequestPath -Raw | ConvertFrom-Json
    $response.RequestId = [string]$request.RequestId

    switch ($request.Action) {
        'Mount' {
            $response.DriveLetter = Mount-BraveLockerVault -VhdxPath $request.VhdxPath
            $response.Success = $true
        }
        'Dismount' {
            Dismount-BraveLockerVault -VhdxPath $request.VhdxPath
            $response.Success = $true
        }
        default { throw "Unknown action '$($request.Action)'." }
    }
} catch {
    $response.Success = $false
    $response.Error = $_.Exception.Message
} finally {
    Remove-Item -Path $paths.RequestPath -Force -ErrorAction SilentlyContinue
    $response | ConvertTo-Json -Depth 5 | Set-Content -Path $paths.ResponsePath -Encoding utf8
}
```

- [ ] **Step 5: Run and confirm pass**

Run: `Invoke-Pester tests\Elevation.Tests.ps1 -Output Detailed`
Expected: 10 passed.

- [ ] **Step 6: Commit**

```bash
git add src/BraveLocker/Elevation.ps1 scripts/Invoke-BraveLockerVaultTask.ps1 tests/Elevation.Tests.ps1
git commit -m "feat: elevated mount helper with hardened script directory"
```

---

### Task 8: Setup script

**Files:**
- Create: `scripts/Install-BraveLocker.ps1`

**Interfaces:**
- Consumes: everything from Tasks 1–7.
- Produces: `config.json` in the state root with `VhdxPath`, `ProfilePath`, `BraveExe`, `PreferredDriveLetter`, `SourceProfilePath`; a registered `BraveLocker-Mount` task; a desktop shortcut; a populated vault.

Setup must be run elevated (it creates the VHDX, enables BitLocker, registers the task and sets ACLs). This is the one UAC prompt the user ever sees.

- [ ] **Step 1: Write the script**

`scripts/Install-BraveLocker.ps1`:

```powershell
#Requires -Version 5.1
#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [string]$VhdxPath = 'D:\apps\brave_locker\vault.vhdx',
    [int]$MaximumSizeMB = 32768,
    [string]$BraveExe = 'C:\Program Files\BraveSoftware\Brave-Browser\Application\brave.exe',
    [string]$SourceProfilePath = (Join-Path $env:LOCALAPPDATA 'BraveSoftware\Brave-Browser\User Data')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot '..\src\BraveLocker\BraveLocker.psd1') -Force

Write-Host ''
Write-Host 'Brave Locker setup' -ForegroundColor Cyan
Write-Host '=================='

# --- 1. Preconditions -------------------------------------------------------
if (-not (Test-Path $BraveExe))          { throw "Brave was not found at '$BraveExe'." }
if (-not (Test-Path $SourceProfilePath)) { throw "No Brave profile found at '$SourceProfilePath'." }
if (Test-Path $VhdxPath)                 { throw "A vault already exists at '$VhdxPath'. Delete it first if you truly want to start over." }

if (@(Get-Process -Name 'brave' -ErrorAction SilentlyContinue).Count -gt 0) {
    throw 'Close Brave completely before running setup, so the profile is copied in a consistent state.'
}

# --- 2. Passphrase ----------------------------------------------------------
$passphrase = $null
while ($null -eq $passphrase) {
    $first = Read-Host -Prompt 'Choose a vault passphrase (at least 16 characters)' -AsSecureString
    $again = Read-Host -Prompt 'Type it again' -AsSecureString

    $plainFirst = [Runtime.InteropServices.Marshal]::PtrToStringUni(
        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($first))
    $plainAgain = [Runtime.InteropServices.Marshal]::PtrToStringUni(
        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($again))

    if ($plainFirst -ne $plainAgain) {
        Write-Host 'Those did not match. Try again.' -ForegroundColor Yellow
        continue
    }

    $check = Test-BraveLockerPassphrase -Passphrase $plainFirst
    if (-not $check.IsValid) {
        if ($check.Reason -eq 'TooShort') {
            Write-Host 'Too short. Anyone who copies the vault file can attack it offline with no attempt limit, so length is what protects you. Use at least 16 characters - a few words you will remember beats a short clever one.' -ForegroundColor Yellow
        } else {
            Write-Host 'Padding with spaces does not count. Use at least 16 real characters.' -ForegroundColor Yellow
        }
        continue
    }
    $passphrase = $first
}
Remove-Variable plainFirst, plainAgain -ErrorAction SilentlyContinue

# --- 3. Create and encrypt the vault ---------------------------------------
$letter = Get-BraveLockerFreeDriveLetter -Preferred 'V'
Write-Host "Creating the vault at $VhdxPath (drive $letter`:) ..."
New-BraveLockerVault -VhdxPath $VhdxPath -MaximumSizeMB $MaximumSizeMB -DriveLetter $letter

$mount = "$letter`:"
Write-Host 'Encrypting it with BitLocker. This is quick because the vault is nearly empty.'
Enable-BitLocker -MountPoint $mount -PasswordProtector -Password $passphrase `
    -EncryptionMethod XtsAes256 -UsedSpaceOnly -ErrorAction Stop | Out-Null

$recovery = Add-BitLockerKeyProtector -MountPoint $mount -RecoveryPasswordProtector -ErrorAction Stop
$recoveryKey = ($recovery.KeyProtector | Where-Object { $_.KeyProtectorType -eq 'RecoveryPassword' } |
    Select-Object -Last 1).RecoveryPassword

# --- 4. Recovery key: shown once, never written to disk ---------------------
Write-Host ''
Write-Host 'RECOVERY KEY - write this down now' -ForegroundColor Red
Write-Host $recoveryKey -ForegroundColor White
Write-Host ''
Write-Host 'This is deliberately not saved anywhere on this PC. A recovery key sitting'
Write-Host 'on the machine would let anyone who finds it open the vault, which would'
Write-Host 'defeat the entire point. Put it on your phone or in a password manager.'
Write-Host 'If you lose both the passphrase and this key, the profile is gone for good.'
Write-Host ''
$confirm = Read-Host 'Type STORED once you have saved it somewhere off this PC'
if ($confirm -ne 'STORED') {
    Dismount-BraveLockerVault -VhdxPath $VhdxPath
    Remove-Item -Path $VhdxPath -Force
    throw 'Setup cancelled and the vault deleted, because the recovery key was not stored. Nothing was changed.'
}
Clear-Variable recoveryKey

# --- 5. Migrate the profile -------------------------------------------------
$profilePath = Join-Path $mount 'BraveProfile'
Write-Host "Copying your Brave profile into the vault. This moves about 1.2 GB and takes a minute."
New-Item -ItemType Directory -Path $profilePath -Force | Out-Null
& robocopy.exe $SourceProfilePath $profilePath /E /R:1 /W:1 /NFL /NDL /NJH /NJS | Out-Null
if ($LASTEXITCODE -ge 8) {
    throw "robocopy reported errors (exit $LASTEXITCODE). The vault has been left in place for inspection; your original profile is untouched."
}

$sourceCount = @(Get-ChildItem -Path $SourceProfilePath -Recurse -File -ErrorAction SilentlyContinue).Count
$vaultCount  = @(Get-ChildItem -Path $profilePath -Recurse -File -ErrorAction SilentlyContinue).Count
Write-Host "Verification: $sourceCount files in the original, $vaultCount in the vault."
if ($vaultCount -lt $sourceCount) {
    Write-Host 'Fewer files arrived than were sent. Your original profile is untouched - do not run the cleanup script.' -ForegroundColor Yellow
}

# --- 6. Register the elevated helper and harden the scripts directory -------
$scriptsDir = $PSScriptRoot
$taskScript = Join-Path $scriptsDir 'Invoke-BraveLockerVaultTask.ps1'
Set-BraveLockerScriptAcl -Path (Split-Path -Parent $scriptsDir)
Register-BraveLockerMountTask -ScriptPath $taskScript
Write-Host 'Registered the mount helper, so you will not see a UAC prompt when launching Brave.'

# --- 7. Save config ---------------------------------------------------------
$paths = Get-BraveLockerPaths
if (-not (Test-Path $paths.StateRoot)) { New-Item -ItemType Directory -Path $paths.StateRoot -Force | Out-Null }
[pscustomobject]@{
    VhdxPath             = $VhdxPath
    ProfileDirName       = 'BraveProfile'
    BraveExe             = $BraveExe
    PreferredDriveLetter = $letter
    SourceProfilePath    = $SourceProfilePath
} | ConvertTo-Json -Depth 5 | Set-Content -Path $paths.ConfigPath -Encoding utf8

# --- 8. Seal up and make a shortcut ----------------------------------------
Lock-BitLocker -MountPoint $mount -ErrorAction SilentlyContinue | Out-Null
Dismount-BraveLockerVault -VhdxPath $VhdxPath

$shortcut = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Brave (Private).lnk'
$shell = New-Object -ComObject WScript.Shell
$link = $shell.CreateShortcut($shortcut)
$link.TargetPath = 'powershell.exe'
$link.Arguments = ('-NoProfile -ExecutionPolicy Bypass -File "{0}"' -f (Join-Path $scriptsDir 'Start-BraveLocked.ps1'))
$link.IconLocation = $BraveExe
$link.Description = 'Open Brave with the encrypted private profile.'
$link.Save()

Write-Host ''
Write-Host 'Setup complete.' -ForegroundColor Green
Write-Host 'Next: open "Brave (Private)" on your desktop and check that Facebook, your email and your cards are all there.'
Write-Host 'Your ORIGINAL unprotected profile is still on disk. Until you remove it, this tool protects nothing.'
Write-Host 'Once you have confirmed everything works, run Complete-BraveLockerMigration.ps1 to delete it.'
```

- [ ] **Step 2: Syntax-check without executing**

```powershell
$errors = $null
[System.Management.Automation.Language.Parser]::ParseFile(
    'D:\apps\brave_locker\scripts\Install-BraveLocker.ps1', [ref]$null, [ref]$errors)
$errors
```

Expected: no output. Do not run the script yet — Task 10 runs it for real.

- [ ] **Step 3: Commit**

```bash
git add scripts/Install-BraveLocker.ps1
git commit -m "feat: setup script creating, encrypting and populating the vault"
```

---

### Task 9: The everyday launcher

**Files:**
- Create: `scripts/Start-BraveLocked.ps1`

**Interfaces:**
- Consumes: everything from Tasks 1–7, plus `config.json` written by Task 8.
- Produces: the user-facing launch experience.

This is where the failed-attempt policy from the spec is enforced: refuse, seal, cool down, log — never destroy.

- [ ] **Step 1: Write the script**

`scripts/Start-BraveLocked.ps1`:

```powershell
#Requires -Version 5.1
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot '..\src\BraveLocker\BraveLocker.psd1') -Force

$paths = Get-BraveLockerPaths
if (-not (Test-Path $paths.ConfigPath)) {
    Write-Host 'Brave Locker is not set up yet. Run Install-BraveLocker.ps1 first.' -ForegroundColor Yellow
    Read-Host 'Press Enter to close'
    return
}
$config = Get-Content -Path $paths.ConfigPath -Raw | ConvertFrom-Json

function Complete-Session {
    param([string]$VhdxPath, [string]$ProfilePath)

    if ($ProfilePath) {
        Stop-BraveLockerBrowser -ProfilePath $ProfilePath -TimeoutSeconds 15 | Out-Null
    }
    $result = Invoke-BraveLockerMountTask -Action 'Dismount' -VhdxPath $VhdxPath
    if (-not $result.Success) {
        Write-Host "Warning: the vault could not be sealed - $($result.Error)" -ForegroundColor Yellow
        Write-Host 'Close any window using the vault drive, then run this launcher again.' -ForegroundColor Yellow
    }
}

# --- Recover from a crash or forced reboot ---------------------------------
# If the vault is still attached from a previous session, seal it before doing
# anything else, so a crash cannot silently leave the profile readable.
if (Test-BraveLockerVaultMounted -VhdxPath $config.VhdxPath) {
    Write-Host 'The vault was left open by a previous session. Sealing it first.' -ForegroundColor Yellow
    Complete-Session -VhdxPath $config.VhdxPath -ProfilePath ''
}

# --- Cooldown ---------------------------------------------------------------
$remaining = Get-BraveLockerRemainingCooldownSeconds -StatePath $paths.StatePath -NowUtc (Get-Date).ToUniversalTime()
if ($remaining -gt 0) {
    Write-Host "Too many failed attempts. Wait $remaining seconds and try again." -ForegroundColor Yellow
    Read-Host 'Press Enter to close'
    return
}

# --- Unlock -----------------------------------------------------------------
$passphrase = Read-Host -Prompt 'Vault passphrase' -AsSecureString

$mountResult = Invoke-BraveLockerMountTask -Action 'Mount' -VhdxPath $config.VhdxPath
if (-not $mountResult.Success) {
    Write-Host "Could not open the vault: $($mountResult.Error)" -ForegroundColor Red
    Read-Host 'Press Enter to close'
    return
}

$driveLetter = $mountResult.DriveLetter
if (-not (Unlock-BraveLockerVault -DriveLetter $driveLetter -Passphrase $passphrase)) {
    # Wrong passphrase: nothing was decrypted. Seal it back up, record the
    # attempt, and step up the cooldown. Nothing is ever deleted.
    $count = Add-BraveLockerFailedAttempt -StatePath $paths.StatePath -NowUtc (Get-Date).ToUniversalTime()
    Complete-Session -VhdxPath $config.VhdxPath -ProfilePath ''
    $wait = Get-BraveLockerCooldownSeconds -FailureCount $count
    Write-Host "Incorrect passphrase. The vault stays sealed. Wait $wait seconds before trying again." -ForegroundColor Red
    Read-Host 'Press Enter to close'
    return
}

# --- Success ----------------------------------------------------------------
$prior = Clear-BraveLockerFailedAttempts -StatePath $paths.StatePath
if ($prior.FailureCount -gt 0) {
    $when = ([datetime]$prior.LastFailureUtc).ToLocalTime().ToString('ddd HH:mm')
    Write-Host ''
    Write-Host "Note: $($prior.FailureCount) failed attempt(s) since you last opened this, most recent $when." -ForegroundColor Yellow
    Write-Host ''
}

$profilePath = Join-Path "$driveLetter`:" $config.ProfileDirName

try {
    Start-BraveLockerBrowser -BraveExe $config.BraveExe -ProfilePath $profilePath | Out-Null
    Write-Host 'Brave is open. This window seals the vault when you close Brave - leave it running.'
    Write-Host 'Remember to lock Windows (Win+L) if you step away while Brave is open.'
    Wait-BraveLockerBrowserExit -ProfilePath $profilePath
} finally {
    Complete-Session -VhdxPath $config.VhdxPath -ProfilePath $profilePath
    Write-Host 'Vault sealed.' -ForegroundColor Green
}
```

- [ ] **Step 2: Syntax-check without executing**

```powershell
$errors = $null
[System.Management.Automation.Language.Parser]::ParseFile(
    'D:\apps\brave_locker\scripts\Start-BraveLocked.ps1', [ref]$null, [ref]$errors)
$errors
```

Expected: no output.

- [ ] **Step 3: Commit**

```bash
git add scripts/Start-BraveLocked.ps1
git commit -m "feat: launcher enforcing the non-destructive failed-attempt policy"
```

---

### Task 10: Cleanup script, docs, and the real integration run

**Files:**
- Create: `scripts/Complete-BraveLockerMigration.ps1`, `docs/INTEGRATION-CHECKS.md`, `README.md`

**Interfaces:**
- Consumes: `config.json`.
- Produces: the finished, verified tool.

Until the plaintext original is deleted, the vault protects nothing — a copy of everything still sits in `AppData`. That deletion is irreversible, so it is a separate script the user runs deliberately, after confirming the vaulted Brave works.

- [ ] **Step 1: Write the cleanup script**

`scripts/Complete-BraveLockerMigration.ps1`:

```powershell
#Requires -Version 5.1
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot '..\src\BraveLocker\BraveLocker.psd1') -Force

$paths = Get-BraveLockerPaths
if (-not (Test-Path $paths.ConfigPath)) { throw 'Brave Locker is not set up. Nothing to clean up.' }
$config = Get-Content -Path $paths.ConfigPath -Raw | ConvertFrom-Json

if (-not (Test-Path $config.SourceProfilePath)) {
    Write-Host 'The original profile is already gone. Nothing to do.' -ForegroundColor Green
    return
}

if (@(Get-Process -Name 'brave' -ErrorAction SilentlyContinue).Count -gt 0) {
    throw 'Close Brave completely before running this.'
}

$size = (Get-ChildItem -Path $config.SourceProfilePath -Recurse -File -ErrorAction SilentlyContinue |
    Measure-Object Length -Sum).Sum / 1GB

Write-Host ''
Write-Host 'This permanently deletes your original, unprotected Brave profile:' -ForegroundColor Red
Write-Host ("  {0}  ({1:N2} GB)" -f $config.SourceProfilePath, $size)
Write-Host ''
Write-Host 'Only do this if you have already opened Brave (Private) and confirmed that'
Write-Host 'your logins, bookmarks and saved cards are all present in the vault copy.'
Write-Host 'There is no undo. The vault becomes the only copy.'
Write-Host ''

$answer = Read-Host 'Type DELETE to confirm'
if ($answer -ne 'DELETE') {
    Write-Host 'Cancelled. Nothing was removed.' -ForegroundColor Yellow
    return
}

Remove-Item -Path $config.SourceProfilePath -Recurse -Force
Write-Host 'Original profile deleted. Your Brave data now exists only inside the encrypted vault.' -ForegroundColor Green
```

- [ ] **Step 2: Write the integration checklist**

`docs/INTEGRATION-CHECKS.md` — the things unit tests cannot prove, each with the command to run and the result that counts as a pass:

```markdown
# Integration checks

Run in order. Record the actual output; a check is not passed until its output is seen.

| # | Check | Command | Pass condition |
|---|-------|---------|----------------|
| 1 | Unelevated unlock (decided in Task 6) | `manage-bde -unlock V: -password` in a non-elevated shell | Unlocks without a UAC prompt. If it demands elevation, apply the Task 6 fallback and update the spec. |
| 2 | Setup completes | `Install-BraveLocker.ps1` from an elevated shell | Recovery key shown, profile copied, file counts match, shortcut on desktop |
| 3 | Vault is encrypted | `manage-bde -status V:` while mounted | `Percentage Encrypted: 100%`, `Protection On` |
| 4 | Locked vault is unreadable | With Brave closed: `Get-ChildItem V:\` | Fails — the drive is not accessible |
| 5 | Vault file resists inspection | `Get-Content vault.vhdx -TotalCount 1 -Encoding Byte` | Returns bytes, but no readable profile data; confirm no plaintext strings via `Select-String -Pattern 'facebook' -Path vault.vhdx` returning nothing |
| 6 | Correct passphrase opens Brave | Desktop shortcut | Brave opens, still logged into Facebook, cards present in `brave://settings/payments` |
| 7 | Wrong passphrase never mounts | Shortcut, type garbage | "Incorrect passphrase", `Get-DiskImage` shows `Attached: False`, nothing deleted |
| 8 | Cooldown escalates | Three wrong attempts in a row | 5s, then 30s, then 5m enforced |
| 9 | Failures are reported | Correct passphrase after failures | "N failed attempt(s) ... most recent ..." shown |
| 10 | Normal close seals the vault | Close Brave | Launcher prints "Vault sealed", `Get-DiskImage` shows `Attached: False` |
| 11 | Crash recovery | `Stop-Process -Name brave -Force`, then relaunch | Launcher reports it sealed a vault left open, then proceeds |
| 12 | Work Brave is untouched | Open normal Brave, then launch the private one and close it | The normal Brave keeps running throughout |
| 13 | No UAC on daily launch | Use the shortcut | No UAC prompt appears |
| 14 | Scripts directory is hardened | `icacls D:\apps\brave_locker` | Users have only `(RX)`; no `(F)`, `(M)` or `(W)` for Users or Authenticated Users |
```

Check 12 is the one that protects the user's working day: the launcher must never kill the work Brave.

- [ ] **Step 3: Run the whole unit suite**

Run: `Invoke-Pester tests\ -Output Detailed`
Expected: all tests pass — 3 + 5 + 12 + 4 + 8 + 5 + 10 = 47.

- [ ] **Step 4: Run the integration checklist for real**

Work through `docs/INTEGRATION-CHECKS.md` on this machine, recording actual output for each row. Any failure stops the process and is fixed before continuing — do not report the tool as working on the strength of the unit tests alone.

- [ ] **Step 5: Write the README**

`README.md` covering: what this is, daily use, what it protects against and what it does not (the vault is decrypted while Brave runs; `Win+L` still matters), where the recovery key lives (not on this PC), how to uninstall (unregister the task, delete the shortcut, and — after copying the profile back out — delete the vault), and the reminder that setup is not finished until `Complete-BraveLockerMigration.ps1` has been run.

- [ ] **Step 6: Commit**

```bash
git add scripts/Complete-BraveLockerMigration.ps1 docs/INTEGRATION-CHECKS.md README.md
git commit -m "feat: cleanup script, integration checklist and README"
```

---

## Open verification points

Two assumptions in this plan are load-bearing and neither is proven yet. Both are
about which operations Windows permits **without elevation**, and the evidence so far
cuts against the optimistic reading: `Get-BitLockerVolume` already returned *Access
denied* in a non-elevated shell on this machine.

**1. `Unlock-BitLocker` without elevation.** Settled in Task 6, Step 1, with a
documented fallback if it fails. Do not skip it.

**2. `Get-DiskImage` without elevation.** The launcher's crash-recovery check calls
`Test-BraveLockerVaultMounted`, which calls `Get-DiskImage`. If that needs admin, the
check throws on every launch. Verify with, in a non-elevated shell:

```powershell
Get-DiskImage -ImagePath 'D:\apps\brave_locker\vault.vhdx'
```

If it is denied, change the launcher's recovery step to skip the check and simply
request a `Dismount` from the elevated task unconditionally at startup.
`Dismount-BraveLockerVault` already returns early when nothing is attached, so the
call is safe to make every time; it costs one fast task run per launch. Make the same
substitution inside `Complete-Session`.

## Small follow-ups

- When `Mount-BraveLockerVault` fails because the vault file is missing or corrupt,
  the launcher currently prints the raw error. Add a line pointing the user at their
  recovery key, since that is the only remaining route back into the data. The spec
  calls for this and the launcher in Task 9 does not yet do it.
