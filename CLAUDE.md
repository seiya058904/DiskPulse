# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

DiskPulse is a zero-dependency Windows disk storage monitor. A single polyglot BAT/PowerShell script scans local fixed disks, appends usage data to a CSV log, and generates a self-contained HTML dashboard (titled "磁盘容量看板").

## Files

- `check.bat` — the entire backend (polyglot: BAT preamble invokes PowerShell). All CSS/JS/HTML is embedded as a here-string template.
- `DiskPulse.vbs` — silent launcher (hidden window, error dialog on failure)
- `check-profile.bat` — performance diagnostics launcher (generates `runtime/last-profile.json`)
- `runtime/` — all generated data: `DiskPulse.csv`, `DiskPulse.html`, `snapshots/`, `scans.jsonl`, `last-run.log`, `last-profile.json`

## How to Run

```powershell
# Normal (hidden terminal, recommended for users)
DiskPulse.vbs

# Debug (shows terminal with progress)
check.bat

# Performance profiling (generates runtime/last-profile.json)
check-profile.bat
# or: set DISKPULSE_PROFILE=1 && check.bat
```

No build step. Requires Windows with PowerShell 5.1+.

## How to Run Tests

Tests are standalone PowerShell scripts (not Pester). Run with Windows PowerShell:

```powershell
powershell.exe -NoProfile -File "tests\DiskPulse.Phase1.Tests.ps1"
powershell.exe -NoProfile -File "tests\DiskPulse.Phase3.Tests.ps1"
powershell.exe -NoProfile -File "tests\DiskPulse.Phase4.Tests.ps1"
powershell.exe -NoProfile -File "tests\DiskPulse.Phase5.Tests.ps1"
powershell.exe -NoProfile -File "tests\DiskPulse.Scanner.Tests.ps1"
```

All 5 must pass before committing. Phase4/5 extract embedded JavaScript from `check.bat` and run it through Node.js for fixture validation.

## Architecture

The PowerShell code in `check.bat` follows a linear pipeline:

1. **Initialize** — load history CSV, acquire file lock, optional silent/profiling modes via `DISKPULSE_SILENT` and `DISKPULSE_PROFILE` env vars
2. **Compile C# scanner** — `Add-Type` embeds `DiskPulseFastScanner` (stack-based directory walker with native `FileSystemInfo` enumeration)
3. **Query disks** — `Get-CimInstance Win32_LogicalDisk` (DriveType 3); fallback: `[System.IO.DriveInfo]::GetDrives()`
4. **Scan directories** — per-drive via `[DiskPulseFastScanner]::Scan()`, producing records for root files, level-1 and level-2 directories
5. **Compare with baseline** — `Compare-DriveRecords` detects created/changed/removed directories
6. **Build history comparison center** — `New-HistoryComparisonCenter` (optimized with pre-built indexes for trend aggregation)
7. **Persist** — trim history, write CSV, write snapshot JSON
8. **Generate HTML** — here-string template with `INJECT_*` placeholders replaced via regex
9. **Open browser** — `Start-Process` (skipped when `DISKPULSE_NO_OPEN=1`)

### HTML Template

The here-string uses single-quoted `@'...'@` so PowerShell does not interpolate `$` or backticks. The closing delimiter `'@` must appear at the start of a line. Placeholders (`INJECT_DATA`, `INJECT_HISTORY`, `INJECT_DIRECTORY`, `INJECT_HISTORY_CENTER`, `INJECT_SCAN_META`, `INJECT_TS_JSON`, `INJECT_SYSTEM_DRIVE`) are replaced via one-pass regex substitution.

### Key Functions in check.bat

- `Invoke-DirectoryScan` — wraps the native C# scanner
- `Compare-DriveRecords` — produces created/changed/removed/unchanged records
- `New-HistoryComparisonCenter` — builds trend analysis across all snapshots (heavily indexed for performance)
- `Get-DirectoryTrendClassification` — labels trend as 持续增长/持续释放/波动较大/本次突增/首次出现/数据不足

### Silent Mode

When `DISKPULSE_SILENT=1`, all `Write-Host` and progress callbacks are suppressed. Errors are written to `runtime/last-run.log`. Balloon notifications for critical disks are preserved.

### Profiling

When `DISKPULSE_PROFILE=1`, phase timing is recorded via `Profile-Mark` calls and written to `runtime/last-profile.json`. Key phases: `init`, `addType`, `readHistory`, `diskQuery`, `readSnapshots`, `scan:<drive>`, `history:aggregateTrends:<drive>`, `htmlReplace`, `htmlWrite`.

## Key Constants

- `$maxHistoryRows` = 3650
- Status thresholds: good < 75%, warning 75-89%, critical >= 90%
- Snapshot retention: 30 files max

## Constraints

- Single-file architecture: all code in `check.bat`
- Zero runtime dependencies
- No external network requests
- Do not use `innerHTML` — all DOM updates via `element()` helper or `textContent`
- The here-string closing delimiter `'@` must not appear as the first character of any line in the template body
