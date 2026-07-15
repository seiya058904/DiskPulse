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

