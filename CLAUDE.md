# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

DiskPulse is a zero-dependency Windows disk storage monitor. A single polyglot BAT/PowerShell script scans local fixed disks, appends usage data to a CSV log, and generates a self-contained HTML dashboard (titled "磁盘容量看板").

## Files

- `check.bat` — the entire backend (polyglot: BAT preamble on lines 1-6 invokes the PowerShell code on lines 9-863)
- `storage_history.csv` — historical data store (columns: Timestamp, ID, Total, Free, Used, Percent; capped at 3650 rows; deduped — identical consecutive samples are skipped)
- `disk_monitor.html` — generated output artifact, overwritten each run (not hand-edited)

## How to Run

```
check.bat
```

Double-click or execute from a terminal. No build step, no dependencies. Requires Windows with PowerShell 5.1+.

## Architecture

The PowerShell code in `check.bat` follows a linear pipeline:

1. **Load history** (lines 48-80) — `Import-Csv` the existing CSV, normalize with `Read-Number` / `New-HistoryRow` helpers
2. **Query disks** (lines 87-105) — primary: `Get-CimInstance Win32_LogicalDisk` (DriveType 3); fallback: `[System.IO.DriveInfo]::GetDrives()`
3. **Compute metrics** (lines 108-150) — per-drive GB values, usage %, diff vs last sample, status thresholds (good <75%, warning 75-89%, critical >=90%). Critical drives trigger a Windows balloon notification. CSV dedup: skips appending if data matches previous sample.
4. **Persist history** (lines 152-157) — trim to `$maxHistoryRows`, write CSV
5. **Generate HTML** (lines 164-849) — a here-string template with three placeholders: `INJECT_DATA`, `INJECT_HISTORY`, `INJECT_TS`, replaced via string substitution (lines 851-853). Written as UTF-8 without BOM.
6. **Open browser** (lines 858-863) — `Start-Process` on the HTML file

The HTML template is a full single-page app embedded in the PowerShell here-string. It contains all CSS and JavaScript inline. Features include:
- Dark mode with manual toggle button (persists via localStorage, defaults to system preference)
- No external font dependencies (system font stack)
- Keyboard shortcut 'C' to toggle compact mode
- Pre-indexed history map for fast per-drive lookups
- Linear regression for days-until-full estimation (last 20 samples)
- Next-run sampling time indicator

## Key Constants (in check.bat)

- `$logFile` = `"storage_history.csv"` (line 12)
- `$htmlFile` = `"disk_monitor.html"` (line 13)
- `$maxHistoryRows` = `3650` (line 15)

## Status Thresholds (line 117)

- `good`: usage < 75%
- `warning`: usage 75-89%
- `critical`: usage >= 90% (triggers balloon notification)

## HTML Template Mechanics

The here-string uses single-quoted `@'...'@` so PowerShell does not interpolate `$` or backticks inside the HTML/JS. The three `INJECT_*` placeholders are plain text substitutions done after the here-string closes. The only constraint is that the closing delimiter `'@` must appear at the start of a line — avoid lines beginning with `'@` in the template body.
