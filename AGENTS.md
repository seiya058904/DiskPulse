# Repository Guidelines

## Project Overview

DiskPulse is a zero-dependency Windows disk capacity and directory change monitor. A single polyglot BAT/PowerShell script (`check.bat`, ~2900 lines) scans local fixed disks, records usage history to CSV, and generates a self-contained HTML dashboard with dark mode, trend analysis, and accessibility support.

- **Language:** PowerShell 5.1+ (embedded in a BAT wrapper), C# compiled inline via `Add-Type`, HTML/CSS/JS in a here-string template
- **Runtime:** Windows only, no external dependencies
- **Entry points:** `DiskPulse.vbs` (silent), `check.bat` (debug), `check-profile.bat` (profiling)
- **Output:** `runtime/DiskPulse.html`, `runtime/DiskPulse.csv`, `runtime/snapshots/*.json`

## Project Structure

```
check.bat              Main program (BAT preamble + PowerShell + embedded C#/HTML/JS)
DiskPulse.vbs          Silent launcher (VBScript, hidden window)
check-profile.bat      Performance diagnostics launcher
tests/                 Standalone PowerShell test scripts (5 files)
runtime/               Generated data (gitignored): CSV, HTML, snapshots, scans, logs
docs/                  Design documentation
PRODUCT.md             Product requirements and design principles
DESIGN.md              Visual design constraints
README.md              User-facing documentation
CLAUDE.md              Claude Code integration guide
```

## Architecture

`check.bat` is a linear pipeline:

1. **Initialize** — load history CSV, acquire file lock, detect `DISKPULSE_SILENT` / `DISKPULSE_PROFILE` env vars
2. **Compile C# scanner** — `Add-Type` embeds `DiskPulseFastScanner` (stack-based directory walker)
3. **Query disks** — `Get-CimInstance Win32_LogicalDisk` (DriveType 3); fallback: `[System.IO.DriveInfo]::GetDrives()`
4. **Scan directories** — per-drive via native C# `Scan()` method
5. **Compare with baseline** — `Compare-DriveRecords` produces created/changed/removed/unchanged
6. **Build history comparison center** — `New-HistoryComparisonCenter` with pre-built indexes for trend aggregation
7. **Persist** — write CSV, snapshot JSON
8. **Generate HTML** — here-string template, `INJECT_*` placeholders replaced via regex
9. **Open browser** — `Start-Process` (skipped when `DISKPULSE_NO_OPEN=1`)

**Key constraint:** The here-string closing delimiter `'@` must appear at the start of a line. The HTML template body must not contain a line starting with `'@`.

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
```

### Run Tests

Tests are standalone PowerShell scripts, not Pester. All 5 must pass before committing:

```powershell
powershell.exe -NoProfile -File "tests\DiskPulse.Phase1.Tests.ps1"
powershell.exe -NoProfile -File "tests\DiskPulse.Phase3.Tests.ps1"
powershell.exe -NoProfile -File "tests\DiskPulse.Phase4.Tests.ps1"
powershell.exe -NoProfile -File "tests\DiskPulse.Phase5.Tests.ps1"
powershell.exe -NoProfile -File "tests\DiskPulse.Scanner.Tests.ps1"
```

- Phase1: helpers, locking, migration, events, atomic JSON, dashboard markers
- Phase3: comparison states, baseline selection, coverage
- Phase4: visual hierarchy, state behavior, embedded JavaScript (runs `node --check` on extracted JS)
- Phase5: history comparison center selection, semantics, trends, embedded JavaScript
- Scanner: real directory scanner aggregation and edge cases

### Verify

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
- Do not add external network requests — the tool is offline-only
- Do not embed secrets in documentation, commit messages, or log output
- `DiskPulse.vbs` must remain ASCII-only (VBScript fails on UTF-8 Chinese characters)
- The program requires only standard Windows permissions; no admin rights for normal operation

## Agent-Specific Instructions

1. **Read before writing.** Understand the file you are modifying before making changes.
2. **Small, reviewable changes.** One concern per commit. Do not bundle unrelated fixes.
3. **Do not touch unrelated files.** If a task says "modify check.bat", do not also rename tests or update README unless explicitly asked.
4. **Run all 5 test suites** after any change to `check.bat`. Report failures honestly.
5. **Preserve semantics.** Do not change scanning logic, history retention, baseline selection, status thresholds, or dashboard data flow without explicit authorization.
6. **Do not fabricate commands, files, or APIs.** If something does not exist, say so.
7. **Do not overwrite user's uncommitted changes.** Check `git status` first.
8. **Do not install dependencies, run auto-fixers, or format the entire codebase.**
9. **Do not commit, push, deploy, publish, or create releases without explicit user authorization.**
10. **Mark uncertain content.** If you cannot verify a claim, label it as needing confirmation.

## Pre-Commit Checklist

- [ ] `git status --short` — only intended files changed
- [ ] `git diff --check` — no whitespace errors
- [ ] `git diff` — changes are correct and complete
- [ ] All 5 test suites pass (or failures explained)
- [ ] No secrets, tokens, or credentials in diff
- [ ] No `runtime/` files staged
- [ ] Commit message is clear and scoped
