# DiskPulse Scan and AI Latency Optimization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reduce measured disk-scan and AI-result latency on `perf/scan-ai-latency` while preserving every scan, history, privacy, and worker-isolation invariant.

**Architecture:** Instrument the existing single-file pipeline first, then keep only independently measured optimizations. The main process remains the source of scan/comparison truth; the worker receives only a redacted AI contract, performs the request, validates the latest scan, updates HTML, and writes the result.

**Tech Stack:** Windows PowerShell 5.1+, embedded C#, `Invoke-WebRequest`, existing standalone PowerShell tests, existing BAT/PowerShell release and installer scripts.

## Global Constraints

- PowerShell 5.1+ remains supported.
- AI remains optional and offline by default.
- No third-party runtime dependency is added.
- No scan depth, drive range, exclusion rule, baseline rule, history retention rule, or coverage semantics change.
- The worker never acquires the main scan lock or scans a disk.
- API keys, authorization headers, prompts, raw responses, usernames, and unredacted paths never enter profile output.
- Real API comparisons use no more than five calls per condition and only the authorized existing endpoint.
- Do not modify `main`; do not merge; finish with a Draft PR only.

---

## File map

- Modify `check.bat`: profile instrumentation, worker contract, prompt/input candidates, and only profile-proven hot-path changes.
- Modify `tests/DiskPulse.Phase3.Tests.ps1`: AI input, prompt, token-limit, worker isolation, stale-worker, and profile-redaction tests.
- Modify `tests/DiskPulse.Phase4.Tests.ps1`: AI HTML update and result-integrity checks.
- Modify `tests/DiskPulse.Scanner.Tests.ps1`: before/after scanner record and error-shape equality checks.
- Create `docs/performance/2026-07-15-scan-ai-latency.md`: benchmark conditions, raw-safe measurements, accepted/reverted experiments, and final comparison tables.
- Do not modify `README.md`, `PRODUCT.md`, or UI code unless a test proves the performance work requires it.

## Task 1: Establish repeatable instrumentation and benchmark evidence

**Files:**
- Modify: `check.bat:14-21,1515-1585,4049-4060`
- Modify: `tests/DiskPulse.Phase3.Tests.ps1`
- Create: `docs/performance/2026-07-15-scan-ai-latency.md`

**Interfaces:**
- Produce profile files only when `$env:DISKPULSE_PROFILE -eq '1'`.
- Main profile remains `runtime/last-profile.json` and gains stage duration, per-drive duration, record counts, and safe size fields.
- Worker profile is `runtime/last-ai-profile.json` and contains only duration, data-size, provider/model, and token usage fields.

- [ ] **Step 1: Add a failing profile-redaction test.**

Add to `tests/DiskPulse.Phase3.Tests.ps1` a fixture assertion that a profile object contains no keys or values matching `apiKey`, `authorization`, `prompt`, `path`, `USERPROFILE`, or a drive-root pattern, while allowing `inputChars`, `inputBytes`, and token fields.

- [ ] **Step 2: Run the focused test and record the failure.**

Run:

```powershell
powershell.exe -NoProfile -File tests\DiskPulse.Phase3.Tests.ps1
```

Expected: the new profile assertion fails because the profile contract does not yet exist.

- [ ] **Step 3: Add profile helpers and marks at component boundaries.**

Use the existing `Profile-Mark` helper and add only profile-gated marks around: process/main entry, `Add-Type`, disk query, snapshot read, each `Invoke-DirectoryScan`, comparison, history center, AI input construction, AI JSON serialization, prompt construction, worker spawn, HTML template/replace/write, and final result timing. In the worker, record process-entry, script-ready, contract-read, prompt-ready, request-start, request-end, response-parse, HTML-update, result-write, and total durations. Never write prompt text or paths to profile files.

- [ ] **Step 4: Record token usage without assuming one provider shape.**

In the existing response parser, read usage fields when present using the names `prompt_tokens`, `input_tokens`, `completion_tokens`, `output_tokens`, `reasoning_tokens`, `cached_tokens`, and `total_tokens`; preserve null/zero when absent. Do not calculate `total_tokens` by adding reasoning tokens to completion tokens.

- [ ] **Step 5: Run the focused test and three baseline scans.**

Run three identical profile scans with `DISKPULSE_NO_OPEN=1`, capture per-drive values and record counts, then run the existing configured endpoint up to five times only until three structured successes are available. Record hardware, Windows version, media type, cache condition, active-process check, provider, model, endpoint host, and safe token/time metadata in the performance report.

Expected: profile-redaction test passes; baseline report records all requested fields or explicitly marks unavailable fields.

- [ ] **Step 6: Commit instrumentation separately.**

```powershell
git add check.bat tests\DiskPulse.Phase3.Tests.ps1 tests\DiskPulse.Phase4.Tests.ps1 docs\performance\2026-07-15-scan-ai-latency.md
git commit -m "perf: instrument scan and AI latency"
```

## Task 2: Compare AI serialization contracts before changing behavior

**Files:**
- Modify: `check.bat:1515-1568`
- Modify: `tests/DiskPulse.Phase3.Tests.ps1`

**Interfaces:**
- Contract A: worker input has `aiInput` as an object; the worker serializes it once before prompt construction.
- Contract B: worker input has `aiInputJson` as one UTF-8 JSON string; the worker uses it directly.
- Both contracts expose the same `scanId`, output paths, model/provider metadata, and redacted semantic content.

- [ ] **Step 1: Add offline fixture tests for semantic equivalence.**

Build one fixture containing a maximum growth item, maximum release item, breakdown, low coverage, unexplained bytes, partial status, and trends. Assert that both contracts produce identical prompt JSON after parsing and that neither contains raw paths or secrets.

- [ ] **Step 2: Add measurement-only contract selection.**

Generate both contracts in profile mode, measure contract UTF-8 bytes, main serialization time, worker contract-read time, prompt-ready time, and end-to-end time. Do not change the production default until repeated offline and real measurements identify the smaller/faster contract.

- [ ] **Step 3: Run tests and compare the two contracts.**

```powershell
powershell.exe -NoProfile -File tests\DiskPulse.Phase3.Tests.ps1
```

Expected: both contracts preserve identical redacted semantics. Select the contract with the lower median total cost; if the difference is noise, retain the existing object contract and remove the experiment code.

- [ ] **Step 4: Commit only a proven contract change.**

```powershell
git add check.bat tests\DiskPulse.Phase3.Tests.ps1
git commit -m "perf: reduce AI worker serialization"
```

## Task 3: Reduce AI prompt and input size with safety-preserving tests

**Files:**
- Modify: `check.bat:1131-1282`
- Modify: `tests/DiskPulse.Phase3.Tests.ps1`

**Interfaces:**
- `New-DiskPulseAIInput` continues to return the same schema and does not alter scan records.
- `New-DiskPulseAIPrompt` continues to return `{ system, user }` and only changes wording/AI-summary bounds.

- [ ] **Step 1: Add failing fixture assertions for bounds and safety rules.**

Assert that the AI summary retains the largest growth and release, `coverageRate`, `unexplainedBytes`, partial status, and key trend; that `omitted` equals the exact count and absolute-byte total of omitted items; that system prompt text still contains the parent/breakdown, no-file-content, untrusted-path, no-delete-command, no-system-directory-delete, fact/speculation, low-confidence, and JSON-only rules. Assert summary/list limits and no Markdown instruction.

- [ ] **Step 2: Implement the smallest measured caps.**

Evaluate primary growth 8/10 items, release 5/8 items, breakdown 3 children per retained parent, and trends 5/8 items against the existing 15/10/5/10 values. Preserve mandatory items first; aggregate only omitted non-mandatory items. Compress duplicate prompt wording without deleting a safety rule.

- [ ] **Step 3: Test completion limits offline.**

For `768`, `1024`, `1536`, `2048`, and no limit, feed the existing offline structured responses through the parser. Assert complete JSON, all required fields, no truncation, and no loss of maximum growth/release. Do not change provider defaults from this fixture alone.

- [ ] **Step 4: Run the focused suites.**

```powershell
powershell.exe -NoProfile -File tests\DiskPulse.Phase3.Tests.ps1
powershell.exe -NoProfile -File tests\DiskPulse.Phase4.Tests.ps1
```

Expected: all existing and new fixture assertions pass; input character/byte measurements show the target reduction without semantic loss.

- [ ] **Step 5: Run the authorized real completion-limit comparison.**

Use the same redacted input and existing provider/model. Test only the configured token parameter and at most five calls per condition. Keep a limit only if at least three structured responses are complete, major changes remain represented, and median latency or total tokens improves; otherwise restore the previous no-limit setting.

- [ ] **Step 6: Commit only proven prompt/input changes.**

```powershell
git add check.bat tests\DiskPulse.Phase3.Tests.ps1 tests\DiskPulse.Phase4.Tests.ps1
git commit -m "perf: trim AI analysis payload"
```

## Task 4: Decide whether the worker fast path needs a split script

**Files:**
- Modify: `check.bat:1515-1585,4120-4130`
- Possibly create: `ai-worker.ps1` only if the measured split wins
- Modify: `tests/DiskPulse.Phase3.Tests.ps1`
- Modify: `build-release.ps1`, `build-installer.ps1` only if `ai-worker.ps1` is created and packaging tests require it

**Interfaces:**
- `Invoke-DiskPulseAIWorker` never calls `Invoke-DiskPulse`, `Acquire-DiskPulseLock`, or `DiskPulseFastScanner.Scan`.
- Existing stale-scan checks remain before request, before HTML update, and before result write.

- [ ] **Step 1: Add worker isolation tests.**

Run worker mode against an offline fixture and assert no lock file is created, no scanner invocation occurs, no scan snapshot is created, the output updates only for the expected scan id, and a newer latest scan prevents the stale worker from writing.

- [ ] **Step 2: Measure the existing single-file path.**

Record process start, script parse, function-ready, request-start, response-parse, HTML-update, and total durations. This is the decision baseline; no split file is created before this measurement.

- [ ] **Step 3: Implement a split worker only if startup is material.**

If the measured local startup is a material share of end-to-end time, create an internal `ai-worker.ps1` containing only path/config/contract/request/parse/stale-check/HTML/result functions needed by the worker. Package it automatically in release and installer outputs. Keep the same environment contract and PowerShell 5.1 syntax. If startup is not material, remove the experiment and keep `check.bat`.

- [ ] **Step 4: Run worker and packaging tests.**

```powershell
powershell.exe -NoProfile -File tests\DiskPulse.Phase3.Tests.ps1
powershell.exe -NoProfile -File tests\DiskPulse.Installation.Tests.ps1
powershell.exe -NoProfile -File tests\DiskPulse.Launcher.Tests.ps1
```

Expected: worker isolation, stale protection, and packaging behavior pass; a split script exists only with measured benefit.

- [ ] **Step 5: Commit or discard the worker experiment.**

```powershell
git add check.bat tests\DiskPulse.Phase3.Tests.ps1 build-release.ps1 build-installer.ps1 ai-worker.ps1
git commit -m "perf: shorten AI worker startup"
```

Do not stage `ai-worker.ps1` or packaging changes when the split experiment is discarded.

## Task 5: Optimize the scanner only at a profiled hot spot

**Files:**
- Modify: `check.bat:197-315` only if the profile identifies safe repeated work
- Modify: `tests/DiskPulse.Scanner.Tests.ps1`

**Interfaces:**
- `DiskPulseFastScanner.Scan` returns the same records, ordering contract, statuses, and evidence semantics.
- `Invoke-DirectoryScan` keeps the same PowerShell-facing shape.

- [ ] **Step 1: Add before/after equality fixtures.**

Capture a deterministic fixture directory result and compare record count, normalized path, level, kind, size, file count, timestamps, status, unavailable, excluded, errors, and coverage. Assert stable result ordering across repeated runs.

- [ ] **Step 2: Profile the C# hot loop before editing it.**

Use the new per-drive profile and code inspection to identify repeated `Path.GetFullPath`, `Split`, `Join`, dictionary lookup, object allocation, or enumeration work. Do not optimize a path without a measured share of scan time.

- [ ] **Step 3: Apply one minimal C# change.**

Only use a single-pass loop, cached normalized path, pre-sized collection, or equivalent standard-library improvement when it preserves exception handling and evidence behavior. Do not add same-disk parallelism, cache data across scans, reduce depth, or change exclusions.

- [ ] **Step 4: Run scanner equality and full scan tests.**

```powershell
powershell.exe -NoProfile -File tests\DiskPulse.Scanner.Tests.ps1
powershell.exe -NoProfile -File tests\DiskPulse.Phase1.Tests.ps1
powershell.exe -NoProfile -File tests\DiskPulse.Phase5.Tests.ps1
```

Expected: exact fixture equality and all suites pass. If any field differs or the median does not improve, revert the C# change.

- [ ] **Step 5: Evaluate multi-disk concurrency separately, then remove it unless proven.**

Compare sequential versus maximum-concurrency-2 only on distinct physical disks. Keep it only when three repeated medians improve, result order is stable, every result field is identical, and no drive regresses over 5%. Otherwise delete the experiment before the final diff.

## Task 6: Complete verification and write the performance report

**Files:**
- Modify: `docs/performance/2026-07-15-scan-ai-latency.md`

- [ ] **Step 1: Run every required verification command.**

```powershell
powershell.exe -NoProfile -File tests\DiskPulse.Phase1.Tests.ps1
powershell.exe -NoProfile -File tests\DiskPulse.Phase3.Tests.ps1
powershell.exe -NoProfile -File tests\DiskPulse.Phase4.Tests.ps1
powershell.exe -NoProfile -File tests\DiskPulse.Phase5.Tests.ps1
powershell.exe -NoProfile -File tests\DiskPulse.Scanner.Tests.ps1
powershell.exe -NoProfile -File tests\DiskPulse.Launcher.Tests.ps1
powershell.exe -NoProfile -File tests\DiskPulse.Installation.Tests.ps1
pwsh -NoProfile -File tests\DiskPulse.Phase3.Tests.ps1
pwsh -NoProfile -File tests\DiskPulse.Phase4.Tests.ps1
git diff --check
powershell.exe -NoProfile -File build-release.ps1
powershell.exe -NoProfile -File build-installer.ps1
```

Extract the generated JavaScript and run `node --check` on that extracted file. Run one normal real scan and one installer-launcher scan with no browser visual inspection.

- [ ] **Step 2: Run final before/after measurements.**

Use the fixed benchmark conditions, separate cold/warm cache labels, three scan runs, and no more than five real AI calls per condition. Record per-drive medians, stage medians, token medians, structured success rate, and quality-preservation checks.

- [ ] **Step 3: Document every accepted and reverted experiment.**

Fill `docs/performance/2026-07-15-scan-ai-latency.md` with branch/commit, hardware, media, record counts, cache/process conditions, before/after tables, changed hotspots, data-backed improvements, reverted attempts, AI quality, provider/platform limits, test results, and unexecuted checks.

- [ ] **Step 4: Verify the final diff and secrets.**

```powershell
git status --short
git diff --stat
git diff --check
git diff -- . ':!runtime'
```

Confirm no runtime data, API key, authorization header, full prompt, raw response, or unredacted path is tracked.

## Task 7: Commit, push, and create the Draft PR

- [ ] **Step 1: Commit the final scoped changes.**

```powershell
git add check.bat tests docs/performance build-release.ps1 build-installer.ps1 ai-worker.ps1
git commit -m "perf: reduce scan and AI analysis latency"
```

Omit files that were not changed or whose experiments were reverted.

- [ ] **Step 2: Push the requested branch.**

```powershell
git push -u origin perf/scan-ai-latency
```

- [ ] **Step 3: Create a Draft PR without merging.**

Use the GitHub connector or `gh` fallback to open a Draft PR from `perf/scan-ai-latency` into `main`. Include the performance report, exact test results, accepted/reverted experiments, and any unexecuted validation. Do not create a release or merge the PR.
