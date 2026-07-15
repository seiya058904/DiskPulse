# DiskPulse Scan and AI Latency Optimization Design

## Goal

Improve real disk-scan and AI-result latency on the current `main` baseline without changing scan coverage, comparison semantics, history behavior, privacy guarantees, or AI failure isolation.

## Baseline evidence

- Branch before work: `main`.
- Baseline scan runs: three valid runs, exit code 0.
- Main profile total: approximately 15.3 seconds median.
- Scan hotspots in the observed profile: C: approximately 9.4 seconds, D: approximately 2.0 seconds, E: approximately 1.2 seconds.
- Real AI runs: three; main process approximately 15.6 seconds each; end-to-end final result approximately 35.2–45.2 seconds.
- AI result status: two `success`, one `invalid-response`; JSON success rate is therefore not yet stable enough to trade for latency.
- Existing profile does not expose worker startup, HTTP, parsing, HTML-update, or token-usage stages. The implementation must add those measurements behind `DISKPULSE_PROFILE=1` only.

## Quantitative acceptance criteria

These are targets, not permissions to reduce reliability:

- Scan-stage median improves by at least 10% on the same environment and data.
- No drive has a stable regression greater than 5%.
- Before and after results match exactly for record count, path, level, size, status, unavailable, excluded, errors, changes, and coverage.
- System-prompt token count decreases by at least 20%.
- Ordinary AI-input token count decreases by at least 15%.
- Real AI end-to-end median latency aims to decrease by 20%.
- Total tokens aim to decrease from the observed approximately 4,028 to 2,500–3,200.
- Structured JSON success rate must not be lower than baseline and should reach 100% in the repeated comparison set.

No target may be met by truncating JSON, reducing scan depth, hiding waits, or hiding failures.

## Fixed benchmark conditions

Every comparison records CPU, installed memory, Windows version, drive count and media type, per-drive record counts, total record count, data state, cache condition, and active DiskPulse/worker process checks. Cold-cache and warm-cache runs are reported separately when available. Windows filesystem-cache effects are not attributed to code changes. Each result includes per-drive timings, not only totals. The same redacted AI input, provider, model, timeout, and token parameters are used before and after. The benchmark run is invalid if another DiskPulse process or AI worker is active.

## Serialization experiment

The implementation must measure both contracts before selecting one:

- Contract A stores `aiInput` as an object; the worker serializes it once before prompt construction.
- Contract B stores `aiInputJson` as a string; the worker uses it directly for prompt construction.

The comparison records contract bytes, main serialization time, worker initialization time, prompt construction time, and end-to-end latency. Contract B is not preferred merely because it avoids a theoretical serialization; escaped JSON may make it larger.

## Worker fast-path decision

Measure PowerShell process start, `check.bat` parse time, worker-function-ready time, and request-start time. Keep the current single-file worker path if its local startup cost is not material to end-to-end latency. Only add an internal `ai-worker.ps1` payload if the measurement shows a meaningful startup bottleneck; if added, it must be packaged and deployed automatically by the existing script and installer paths and must not be user-managed.

## Real AI comparison protocol

Use identical redacted input, provider, model, timeout, and token parameters. Run no more than five authorized real calls per condition and obtain at least three successful structured responses for the final comparison when the service permits. Report median latency, input/prompt tokens, output/completion tokens, reasoning tokens, cached tokens when present, total tokens, and structured success rate. Reasoning tokens included in completion tokens must not be added to total twice. Validate that maximum growth, maximum release, coverage, unexplained bytes, partial-scan state, and key trends remain represented.

## Experiment rollback rule

Each candidate is measured independently. Revert any candidate that does not show stable improvement or that changes output, privacy, reliability, or ordering semantics. Candidates include multi-disk concurrency, smaller AI-input limits, completion-token limits, a split worker script, C# hot-loop rewrites, new caches, and extra indexes. The final PR retains only candidates supported by data and reports every attempted-and-reverted candidate.

## Recommended approach

1. Add a profile contract covering the main pipeline and the worker pipeline. Store only elapsed times, counts, byte/character sizes, model/provider name, and token usage. Never store prompts, paths, API keys, authorization headers, or raw responses.
2. Make the worker fast-path explicit: it must enter before scan initialization, must not acquire the main lock, must not compile or execute scanner/report work unnecessarily, must not rescan, and must retain the existing latest-scan and stale-worker checks.
3. Build the final redacted AI JSON once in the main process and pass that serialized JSON to the worker. The worker may parse the contract envelope but must not reconstruct the same AI payload and serialize it again.
4. Compress the system prompt while retaining every existing safety rule. Bound model output in the prompt itself, then evaluate provider-configured completion limits using offline fixtures and, only where explicitly needed, the authorized real endpoint. Choose a limit only if repeated responses remain valid and complete.
5. Reduce only the AI summary sent to the provider: preserve maximum growth, maximum release, coverage, unexplained bytes, partial-scan state, and key trends; cap ordinary lists and aggregate omitted items without changing scan records or dashboard data.
6. Inspect and optimize the C# hot path only where profile evidence identifies avoidable repeated work. Do not introduce disk-level parallelism unless controlled repeated measurements show a median improvement with identical ordered results and no stable per-drive regression over 5%.

## Data flow

```text
scan records -> baseline comparison -> history center -> redacted AI object
             -> one UTF-8 JSON serialization -> worker contract file
             -> prompt/request -> strict UTF-8 response parsing
             -> stale-scan check -> HTML update -> result file write
```

The worker input contract contains the scan id, model/provider metadata, final redacted AI object as serialized JSON, and the existing output paths. It does not contain raw scan records or secrets.

## Invariants

- PowerShell 5.1+ remains supported.
- AI remains optional and offline by default.
- No scan depth, drive range, exclusion rule, baseline rule, history retention rule, or coverage semantics change.
- Parent directory deltas and breakdown deltas are not double-counted.
- AI paths remain untrusted labels and remain redacted before transmission.
- AI failures cannot fail the disk report.
- Worker completion cannot overwrite a newer scan.
- Worker never acquires the main scan lock or scans a disk.
- No third-party runtime dependency is added.

## Verification

The implementation must pass the repository's PowerShell 5.1 suites, the required PowerShell 7 Phase3/Phase4 suites, `node --check`, `git diff --check`, release and installer builds, a normal real scan, and an installer-launcher scan. It must add offline tests for input preservation, omitted counts, prompt safety rules, completion-limit handling, worker isolation, stale-worker protection, and profile redaction.

Real API comparisons will use the same redacted input and model configuration. They will report median latency, token usage, JSON success rate, and preservation of major growth/release items. No release will be created and the branch will end in a Draft PR without merging.
