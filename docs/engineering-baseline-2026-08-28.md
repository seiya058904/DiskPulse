# DiskPulse Engineering Baseline — 2026-08-28

This document records the repository state before architectural work begins. It is a comparison point for later refactors, persistence changes, CI work, and performance work. Facts below were captured on 2026-08-28 from the local checkout; repository files are the source of truth when this document conflicts.

## Repository state

| Item | Value |
|------|-------|
| Local branch | `main` |
| Local HEAD | `1dd0a35a6e668b659273f6c57a3dd74f614e769e` |
| Remote tracking | `origin/main` at same commit |
| Ahead/behind | 0 / 0 |
| Version | `1.2.0` (`version.txt`) |
| Tag at HEAD | `v1.2.0` |
| Working tree | Clean before and after verification (`git status --short` empty) |
| `git diff --check` | Pass |

## Source inventory (approximate, current tree)

| File | Lines |
|------|------:|
| `check.bat` | 4,669 |
| `check-profile.bat` | 13 |
| `DiskPulse.vbs` | 43 |
| `configure-ai.bat` | 9 |
| `build-release.ps1` | 71 |
| `build-installer.ps1` | 48 |
| `installer/DiskPulse.nsi` | 82 |
| `launcher/DiskPulseLauncher.cs` | 214 |
| Test files | 7 (`tests/*.Tests.ps1`) |

## Verification results

### Windows PowerShell 5.1 dynamic suite

Command:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\Invoke-DiskPulseTestSuite.ps1
```

Result: **PASS** — all 7 discovered test files passed:

1. `DiskPulse.Installation.Tests.ps1`
2. `DiskPulse.Launcher.Tests.ps1`
3. `DiskPulse.Phase1.Tests.ps1`
4. `DiskPulse.Phase3.Tests.ps1`
5. `DiskPulse.Phase4.Tests.ps1`
6. `DiskPulse.Phase5.Tests.ps1`
7. `DiskPulse.Scanner.Tests.ps1`

### PowerShell 7 compatibility

Commands:

```powershell
pwsh -NoProfile -File tests\DiskPulse.Phase3.Tests.ps1
pwsh -NoProfile -File tests\DiskPulse.Phase4.Tests.ps1
```

Result: **PASS** for both.

### JavaScript syntax verification

The Phase 4 and Phase 5 suites extract embedded JavaScript from `check.bat` and run `node --check` plus behavior fixtures.

Result: **PASS**.

### Launcher build

Commands:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File build-release.ps1
```

Result: **PASS** — generated `dist\DiskPulse.exe`.

### Installer build

NSIS was available on this machine at the existing local fallback path `D:\xia zai\NSIS\makensis.exe`.

Command:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File build-installer.ps1
```

Result: **PASS** — generated `dist\DiskPulse-Setup-1.2.0.exe`.

### Temporary-data-root real scan with AI disabled

Command (Git Bash form):

```bash
tmp=$(mktemp -d)
DISKPULSE_DATA_ROOT="$tmp" DISKPULSE_NO_OPEN=1 cmd //c check.bat
```

Result: **PASS** — exit code 0. A normal fixed-drive scan completed and generated a self-contained dashboard.

Generated output in the temporary data root:

| File | Size (bytes) |
|------|------:|
| `runtime/DiskPulse.html` | 2,950,263 |
| `runtime/DiskPulse.csv` | 232 |
| `runtime/snapshots/20260828-142050-273-735c30.json` | 296,256 |
| `runtime/scans.jsonl` | 255 |
| `runtime/last-ai-analysis.json` | 247 |

## Current build artifact sizes

| Artifact | Size (bytes) |
|----------|------:|
| `dist/DiskPulse.exe` | 1,334,272 |
| `dist/DiskPulse-Setup-1.2.0.exe` | 1,355,186 |

## Existing performance evidence reviewed

`docs/performance/2026-07-15-scan-ai-latency.md` documents the previous scan/AI latency investigation. The report explicitly rejected or did not retain:

- scanner hot-loop rewriting without proof;
- multi-drive concurrent scanning;
- splitting the AI worker merely for latency;
- arbitrary AI output-limit reductions;
- parser-tightening as a token/latency optimization.

These remain non-goals unless new evidence materially changes the conclusions.

## Observed documentation/repository drift (recorded for Phase B, not fixed here)

- `AGENTS.md` says `check.bat` is approximately 3,500 lines; current file is 4,669 lines.
- `AGENTS.md` says there are 5 test files; the dynamic runner discovers 7.
- `CLAUDE.md` says "No build step"; release and installer build scripts now exist.
- `DESIGN.md` references `docs/DiskPulse-dashboard-visual-hierarchy-design.md`; that file exists locally but is listed in `.gitignore`, so it is not part of the committed repository.
- `build-installer.ps1` still includes a machine-specific fallback path `D:\xia zai\NSIS\makensis.exe`; the portable discovery order already supports explicit `-NsisPath`, `DISKPULSE_NSIS_PATH`, and `Get-Command makensis.exe`.

## Baseline interpretation

The current repository is in a passing, releasable state at v1.2.0. The main structural risk is unchanged: `check.bat` is still a 4,600+ line polyglot file that tests load with `Invoke-Expression`. The next work should follow the program order: documentation convergence, a canonical local verifier, normal CI, persistence hardening, and then deterministic source bundling before large extraction.
