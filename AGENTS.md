# Repository Guidelines

## Project Overview

DiskPulse is a zero-dependency Windows disk capacity and directory change monitor. The canonical source lives under `src/`; the single-file polyglot runtime artifact `check.bat` is generated from that source by `scripts/build-check.ps1`. The generated `check.bat` contains the core scanner, persistence, comparison, history, AI, report and entry-point logic. A C# launcher (`launcher/DiskPulseLauncher.cs`) and an NSIS installer layer (`installer/DiskPulse.nsi`) provide the packaged Windows application.

- **Language:** PowerShell 5.1+ (embedded in a BAT wrapper), C# compiled inline via `Add-Type`, HTML/CSS/JS in a here-string template
- **Runtime:** Windows only, no external dependencies
- **Entry points:** `DiskPulse.vbs` (silent), `check.bat` (debug), `check-profile.bat` (profiling), `configure-ai.bat` (AI config)
- **Output:** `runtime/DiskPulse.html`, `runtime/DiskPulse.csv`, `runtime/snapshots/*.json`, `runtime/last-ai-analysis.json`

## Project Structure

```
check.bat              Main program (BAT preamble + PowerShell + embedded C#/HTML/JS)
DiskPulse.vbs          Silent launcher (VBScript, hidden window)
check-profile.bat      Performance diagnostics launcher
configure-ai.bat       AI configuration entry point (interactive menu)
tests/                 Standalone PowerShell test scripts (dynamic `tests/*.Tests.ps1` discovery)
runtime/               Generated data (gitignored): CSV, HTML, snapshots, scans, logs, AI config
docs/                  Design documentation
PRODUCT.md             Product requirements and design principles
DESIGN.md              Visual design constraints
README.md              User-facing documentation
CLAUDE.md              Claude Code integration guide
build-release.ps1       Builds the single-file `DiskPulse.exe` launcher (payload includes generated `check.bat`)
build-installer.ps1     Builds the NSIS installer around `DiskPulse.exe`
scripts/build-check.ps1 Regenerates `check.bat` from canonical `src/`
src/                    Canonical editable source (PowerShell, C# scanner, dashboard)
launcher/               C# WinForms launcher source
installer/              NSIS installer script
```

## Architecture

`check.bat` is a linear pipeline:

1. **Initialize** — load history CSV, acquire file lock, detect `DISKPULSE_SILENT` / `DISKPULSE_PROFILE` env vars
2. **Compile C# scanner** — `Add-Type` embeds `DiskPulseFastScanner` (stack-based directory walker)
3. **Query disks** — `Get-CimInstance Win32_LogicalDisk` (DriveType 3); fallback: `[System.IO.DriveInfo]::GetDrives()`
4. **Scan directories** — per-drive via native C# `Scan()` method
5. **Compare with baseline** — `Compare-DriveRecords` produces created/changed/removed/unchanged
6. **Build history comparison center** — `New-HistoryComparisonCenter` with pre-built indexes for trend aggregation
7. **AI analysis (optional)** — `Invoke-DiskPulseAIAnalysis` (only when configured and enabled)
8. **Persist** — write CSV, snapshot JSON
9. **Generate HTML** — here-string template, `INJECT_*` placeholders replaced via regex
10. **Open browser** — `Start-Process` (skipped when `DISKPULSE_NO_OPEN=1`)

**Key constraint:** The here-string closing delimiter `'@` must appear at the start of a line. The HTML template body must not contain a line starting with `'@`.

## Scanner and Test Architecture

- Canonical C# scanner source lives in `src/scanner/DiskPulseFastScanner.cs`; the PowerShell wrapper is `src/powershell/Scanner.ps1`.
- Scanner-focused tests can load canonical source directly through `tests/TestHelpers.ps1` instead of loading the entire generated `check.bat`.
- Generated-`check.bat` scanner integration remains covered by the broader dynamic suite and generation tests.
- The scanner contract is: fixed-drive scope, root files plus level-1/level-2 aggregation, reparse-point exclusion, transient-missing tolerance, and honest partial/failed status.

## Packaged Lifecycle Invariants

- Application payload under `%LOCALAPPDATA%\DiskPulse` is replaceable and is repaired from embedded resources when missing, stale, or corrupt.
- Persistent user data under `%LOCALAPPDATA%\DiskPulse\data` must survive upgrades and uninstall.
- Launcher payload extraction uses hash comparison and atomic temp/replace publication.
- Migration is idempotent, non-destructive, and does not traverse reparse points.
- Installer/uninstaller shortcuts and registry metadata are current-user scoped.
- Full installer install/uninstall smoke testing is currently **extended Windows QA**, not required canonical CI, because it may touch Desktop/Start Menu.

## Browser QA

- Canonical dashboard sources live under `src/dashboard/`.
- Browser QA is currently an **extended/local verification** step, not a required canonical CI stage.
- Run it with:
  ```powershell
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File testsrowser\Invoke-DiskPulseBrowserQA.ps1 -HtmlPath <generated-DiskPulse.html>
  ```
- The browser harness uses headless Chrome/Edge, monitors console errors, checks desktop/mobile overflow, toggles theme/compact controls, and captures screenshots under a temporary output directory.
- Canonical dashboard source tests (`DiskPulse.DashboardSource.Tests.ps1`) run in the normal suite.

## AI Security Invariants

- AI is opt-in and never required for scans/reports.
- API keys are stored only as DPAPI CurrentUser-protected values; plaintext keys must never appear in HTML, logs, snapshots, CSV, diagnostics, or command lines.
- Remote AI endpoints must use HTTPS; localhost/loopback may use HTTP.
- AI HTTP redirects are disabled (`-MaximumRedirection 0`); redirects are rejected and Authorization is never forwarded to a redirect target.
- Provider responses are untrusted and must pass through safe JSON/HTML serialization.
- AI result publication uses atomic writes; a failed write must preserve the previous valid result.
- Focused AI tests load canonical source through `tests/TestHelpers.ps1`; tests must never contact real AI providers.

## Persistence Invariants

- `DiskPulse.csv` and `DiskPulse.html` are published through atomic temp/replace helpers; a failed write must preserve the previous valid file.
- Snapshot JSON is written through `Write-AtomicJson`; a final snapshot file appears only when the complete JSON is valid.
- `scans.jsonl` is compacted at startup and after final scan publication. Compaction keeps unresolved/running records and event records for scan IDs that still have snapshot files, so retained snapshots remain valid baseline candidates.
- Stale DiskPulse-owned temporary files are cleaned conservatively after 24 hours.

## Build, Test & Development Commands

### Run

```powershell
# Normal (hidden terminal)
DiskPulse.vbs

# Debug (shows terminal with progress)
check.bat

# Performance profiling
check-profile.bat
# or: set DISKPULSE_PROFILE=1 && check.bat

# AI configuration
configure-ai.bat
```

### Build

```powershell
# Regenerate check.bat from canonical source under src/
powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts/build-check.ps1

# Build the launcher executable (DiskPulse.exe)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File build-release.ps1

# Build the NSIS installer. NSIS is discovered via -NsisPath,
# DISKPULSE_NSIS_PATH, PATH/Get-Command, or standard install locations.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File build-installer.ps1
```

### Full Verification

Use the canonical verifier for the complete local/CI verification contract:

```powershell
# Core verification (skips installer if NSIS is unavailable)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts\verify.ps1

# Full verification including installer build (requires NSIS)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts\verify.ps1 -IncludeInstaller
```

The verifier runs repository hygiene checks, the Windows PowerShell dynamic test suite, PowerShell 7 compatibility checks, and isolated launcher/installer builds. It never modifies user runtime data and uses temporary output directories.

Do not hand-edit application sections of `check.bat`; edit the corresponding file under `src/` and regenerate with `scripts/build-check.ps1`.

### Targeted Tests

Use the dynamic runner when you only need the Windows PowerShell suite:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "tests\Invoke-DiskPulseTestSuite.ps1"
```

For PowerShell 7 compatibility checks:

```powershell
pwsh -NoProfile -File "tests\DiskPulse.Phase3.Tests.ps1"
pwsh -NoProfile -File "tests\DiskPulse.Phase4.Tests.ps1"
```

- Phase1: helpers, locking, migration, events, atomic JSON, dashboard markers
- Phase3: comparison states, baseline selection, coverage, AI config, input construction, API request/response, orchestration
- Phase4: visual hierarchy, state behavior, embedded JavaScript, AI section markers, rendering fixtures
- Phase5: history comparison center selection, semantics, trends, embedded JavaScript
- Scanner: real directory scanner aggregation and edge cases

The suite runner discovers test files at runtime; do not document or depend on a fixed test count. Phase 3 and Phase 4 remain the PowerShell 7 compatibility checks.

### Quick Verify

```powershell
git status --short
git diff --check        # whitespace errors
```

## Coding Style

- Follow adjacent code conventions; no formatter or linter is configured
- PowerShell: `Set-StrictMode -Version Latest`, `$ErrorActionPreference = "Stop"`
- Functions use `Verb-Noun` naming (e.g., `Compare-DriveRecords`, `New-HistoryComparisonCenter`)
- C# code embedded in `Add-Type` uses inline style
- HTML template is a single-quoted here-string — no PowerShell interpolation inside it
- Dark mode via `[data-theme="dark"]` CSS with `localStorage` persistence
- All DOM updates use `element()` helper or `textContent`, never `innerHTML`

## Commit & Pull Request Guidelines

Recent commit history follows conventional style:

```
feat: add silent launcher and debug/profiling modes
perf: index history trend aggregation
fix: dark mode shadow visibility and confidence illustration contrast
docs: update CLAUDE.md with current architecture and test commands
chore: remove local project image (uploaded to GitHub)
```

Rules:
- Single-purpose commits with clear scope prefix (`feat`, `fix`, `perf`, `docs`, `chore`)
- UI changes should include before/after description
- Bug fixes should describe the failure scenario and verification
- Do not commit build artifacts, runtime data, or unrelated changes

## Security & Configuration

- **Never** commit `.env`, API keys, tokens, passwords, or connection strings
- **Never** commit files from `runtime/` (generated data)
- **Never** commit `runtime/ai-config.local.json` (contains encrypted API key)
- Do not add external network requests as default behavior — AI is opt-in only
- Do not embed secrets in documentation, commit messages, or log output
- `DiskPulse.vbs` must remain ASCII-only (VBScript fails on UTF-8 Chinese characters)
- `configure-ai.bat` must remain ASCII-only
- The program requires only standard Windows permissions; no admin rights for normal operation
- AI content injected into HTML must use `ConvertTo-DiskPulseSafeJSON` for script-context safety
- API Key must never appear in HTML, logs, snapshots, or test output
- Tests must never make real network requests or call real AI APIs
- All AI test fixtures use offline Transport scriptblocks

## Agent-Specific Instructions

1. **Read before writing.** Understand the file you are modifying before making changes.
2. **Small, reviewable changes.** One concern per commit. Do not bundle unrelated fixes.
3. **Do not touch unrelated files.** If a task says "modify check.bat", do not also rename tests or update README unless explicitly asked.
4. **Run the dynamic test suite** after any change to `check.bat`. Report failures honestly.
5. **Preserve semantics.** Do not change scanning logic, history retention, baseline selection, status thresholds, or dashboard data flow without explicit authorization.
6. **Do not fabricate commands, files, or APIs.** If something does not exist, say so.
7. **Do not overwrite user's uncommitted changes.** Check `git status` first.
8. **Do not install dependencies, run auto-fixers, or format the entire codebase.**
9. **Do not commit, push, deploy, publish, or create releases without explicit user authorization.** Completing implementation never authorizes a release.
10. **Mark uncertain content.** If you cannot verify a claim, label it as needing confirmation.
11. **AI feature constraints:** AI is opt-in, default off. Network requests are optional. Tests must use offline Transport fixtures. API Key uses DPAPI. AI content is untrusted input requiring safe serialization.

12. **Release contract:** after implementation, tests, real-browser QA, and clean-state checks, propose the target SemVer, patch/minor/major classification, and summary. Ask once with a specific prompt such as `Ready to publish DiskPulse v1.2.0. Authorize release?`. Only explicit authorization for that release permits version metadata updates, release commit, main synchronization, push, tag, and GitHub Release automation. Stop for conflicts, force-push requests, credential failures, or ambiguous release state.

## Pre-Commit Checklist

## Personal Knowledge Context

The user's shared long-term AI context lives at `D:\xia zai\AI project\Knowledge`.

This repository's `AGENTS.md` / `CLAUDE.md` / docs and Git state are the source of truth for this project's long-term context. The user's shared cross-project reusable knowledge (prompts, protocols, workflows) lives at `D:\xia zai\AI project\Knowledge`; consult its `AGENTS.md` only when the task needs one of those reusable items or to locate this project's repository. Do not mirror project context back into Knowledge — it is a collection, not project memory.

When the user explicitly says the project/task is ready to “收工” or gives an equivalent finalization instruction, read and follow `D:\xia zai\AI project\Knowledge\02-AI\Prompts\项目收工提示词.md`. This trigger does not expand current task permissions; do not merge, deploy, force-push, resolve remote conflicts, or modify unrelated files unless separately authorized.

- [ ] `git status --short` — only intended files changed
- [ ] `git diff --check` — no whitespace errors
- [ ] `git diff` — changes are correct and complete
- [ ] `scripts/verify.ps1` passes (use `-IncludeInstaller` when NSIS is available/required)
- [ ] `scripts/build-check.ps1` freshness passes (included via generation tests)
- [ ] PowerShell 7 compatibility checks pass (included in the canonical verifier)
- [ ] Embedded JavaScript syntax checks pass (included via Phase4/Phase5 tests)
- [ ] No secrets, tokens, or credentials in diff
- [ ] No `runtime/` files staged
- [ ] No API Key in generated HTML or test output
- [ ] Commit message is clear and scoped
