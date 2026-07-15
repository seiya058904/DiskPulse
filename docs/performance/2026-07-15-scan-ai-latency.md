# DiskPulse Scan and AI Latency Optimization Report

## Scope

- Baseline branch: `main`
- Optimization branch: `perf/scan-ai-latency`
- Baseline HEAD: `951362c`
- Final implementation commits: `c9cdd36`, `62d34d6`, `f27ec53`, `b6954f8`, `06d69d0`, `40e3dcd`
- Real API calls: 5 total, using the existing configured provider/model; no further real calls were made.

## Benchmark conditions

- CPU: AMD Ryzen 7 9700X, 8 cores / 16 logical processors
- Memory: host query did not return a usable value
- Windows version: not captured in the baseline command
- Physical media type: not returned by `Get-PhysicalDisk`
- Drives scanned: C:, D:, E:
- Records in the observed final scan: 608 total in the captured snapshot query
- Cache condition: not controlled; runs are labeled mixed/warm and are not treated as cold-cache proof
- Competing DiskPulse/worker processes: checked before the controlled batches; no competing process was intentionally started
- AI endpoint: existing configured provider host only; full endpoint and credentials are omitted
- AI model: `mimo-v2.5`

## Baseline measurements

Three valid `main` profile scans exited 0 with total profile times 15,621 ms, 15,446 ms, and 15,327 ms; median 15,446 ms. The observed per-drive medians were approximately C: 9,429 ms, D: 2,020 ms, E: 1,199 ms.

Three real AI baseline runs had end-to-end final-result times 36,331 ms (`success`), 45,177 ms (`invalid-response`), and 35,223 ms (`success`). Median: 36,331 ms. Structured success rate: 2/3. The main process itself was approximately 15.6 seconds in each run; the remaining time was worker/API/result completion.

## Before/after comparison

| Stage | Before median | After observed | Change | Evidence |
|---|---:|---:|---:|---|
| Program/main profile | 15,446 ms | 19,746 ms | not comparable; slower observed | mixed cache/profile conditions |
| Disk scan total | about 12,648 ms | 16,333 ms | not accepted as improvement | no scanner code changed |
| C: scan | about 9,429 ms | 12,148 ms | not accepted | cache/data variance |
| D: scan | about 2,020 ms | 2,606 ms | not accepted | cache/data variance |
| E: scan | about 1,199 ms | 1,579 ms | not accepted | cache/data variance |
| historyCenter | 1 ms | 0 ms | not meaningful | mark granularity |
| HTML generation/write | 7–8 ms | 8 ms | neutral | profile |
| AI input construction | not previously isolated | included in worker contract/prompt marks | measured after instrumentation | profile |
| Worker local startup | not available | 532 ms | newly measured | optimized profile |
| AI HTTP request | approximately 20,171 ms in one profiled baseline | 19,863 ms | -1.5% single sample | not enough for target claim |
| AI response parsing | not available | 31 ms | newly measured | optimized profile |
| AI HTML update | not available | 161 ms | newly measured | optimized profile |
| AI complete worker | approximately 20,345 ms in one profiled baseline | 20,194 ms | -0.7% single sample | not enough for target claim |
| AI complete result | 36,331 ms median across 3 baseline runs | 1 post-change success sample; not enough for median | no target claim | API-call budget exhausted |

The scan target of at least 10% improvement was not demonstrated and no scan optimization was retained. The AI target of 20% end-to-end improvement was not demonstrated; the measured local HTML/parse overhead is small compared with provider request time.

## AI payload and token comparison

| Metric | Before observed | After observed | Change |
|---|---:|---:|---:|
| System prompt characters | 1,515 | 1,014 | -33.1% |
| User prompt characters | 2,367 | 3,207 in one mixed-data run | not comparable |
| Redacted input characters | 2,324 | 2,797 in one mixed-data run | not comparable |
| Redacted input UTF-8 bytes | 2,434 | 2,907 | not comparable |
| Request UTF-8 bytes | 4,522 | 4,740 | not comparable |
| Input tokens | unavailable from provider | unavailable from provider | not returned |
| Reasoning tokens | unavailable from provider | unavailable from provider | not returned |
| Output tokens | unavailable from provider | unavailable from provider | not returned |
| Total tokens | unavailable from provider | unavailable from provider | not returned |

The earlier missing usage values must not be attributed directly to the provider: production `Invoke-WebRequest` returns `byte[]`, and the old worker queried usage before decoding that byte array. The worker now strictly UTF-8 decodes the complete envelope once and uses that same envelope for both usage extraction and structured content parsing. Offline coverage verifies `inputTokens=1811`, `outputTokens=2217`, `reasoningTokens=1576`, and `totalTokens=4028`; reasoning tokens are not added again. No additional real API calls were executed in this revision.

## Changes retained

- Profile-only safe diagnostics for main/worker timing, payload sizes, provider/model, and token usage.
- Prompt compression from 1,515 to 1,014 characters while retaining the safety constraints and complete structured JSON contract; measured in Windows PowerShell 5.1.
- AI input caps restored to growth 15, release 10, breakdown 5 per retained parent, trends 10 because the smaller range had no same-input token, latency, or quality proof.
- Exact `omitted` counts and absolute-byte totals for omitted growth/release items.
- Structured-result safety limits restored to summary 4,000 characters, up to 10 items per list, 1,000 characters per item, and raw text 16,000 characters. Post-parse truncation is safety handling, not a performance optimization.
- Per-scan atomic profiles under `runtime/ai-profiles/<scanId>.json`; stale workers retain their own profile but cannot overwrite `last-ai-profile.json`.
- Stage fields use durations: `contractReadMs`, `promptBuildMs`, `configLoadMs`, `httpRequestMs`, `responseDecodeParseMs`, `htmlUpdateMs`, `resultWriteMs`, `workerTotalMs`, and `launchToWorkerEntryMs`.
- Offline tests for prompt safety, omitted accounting, byte[] envelope usage, worker profile redaction, and stale-profile race behavior.

## Experiments reverted or rejected

- Serialized-string worker contract: rejected. On the same fixture, object contract was 3,581 bytes versus 4,093 bytes for the escaped string contract.
- Split `ai-worker.ps1`: rejected. Worker local startup was about 0.53 seconds against about 19.86 seconds HTTP, so the extra payload and packaging path were not justified.
- Multi-disk concurrency: not implemented. No controlled result-equality and median-improvement evidence justified it.
- C# scanner hot-loop rewrite: not implemented. The profile identified scan time, but no single safe rewrite was proven to meet the 10% target without a larger semantic-risk surface.
- Completion token default: not changed. Offline fixtures remain valid at 768/1024/1536/2048, but no provider usage and no remaining real-call budget support choosing a production default.
- Parser-tightening experiment: reverted; it happened after model output and therefore did not reduce tokens or latency.

## Quality and safety

- Scan depth, drive scope, exclusions, baseline selection, history logic, and comparison semantics were not changed.
- Parent and breakdown values remain explicitly non-additive.
- Worker does not acquire the main lock or rescan disks.
- Stale-worker checks remain in place.
- Profile writer uses an allowlist and does not persist prompts, paths, authorization, or API keys.
- No disk-scan speedup was proven.
- No AI end-to-end speedup was proven.
- System prompt reduction of 33.1% was proven (1,515 to 1,014 characters).
- No additional real API calls were performed during this revision.

## Verification results

- PowerShell 5.1: Phase1, Phase3, Phase4, Phase5, Scanner, Launcher, Installation: PASS
- PowerShell 7: Phase3, Phase4: PASS
- `node --check`: PASS on extracted runtime JavaScript
- `git diff --check`: PASS
- `build-release.ps1`: PASS
- `build-installer.ps1`: PASS
- Direct script real scan with AI-disabled temporary data root: PASS; HTML and CSV generated
- Built launcher executable: launched successfully, but scan was not triggered because it requires a GUI button click; hidden process was stopped after the non-interactive check
- Browser visual inspection: not performed by project policy

## Unexecuted or incomplete validation

- Windows version and physical disk media type were not captured reliably.
- Cold-cache isolation was not available.
- Three successful post-change structured API calls were not possible within the five-call authorization budget.
- Real usage return behavior was not re-verified after the byte[] decoding fix because no new real API calls were executed.
- Installer GUI button-click scan was not automated.
