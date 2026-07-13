# DiskPulse Dashboard Visual Hierarchy Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reorganize the generated offline dashboard so capacity pressure, latest reliable changes, and comparison confidence are understandable within three seconds without changing scan or snapshot semantics.

**Architecture:** Keep the existing PowerShell scan pipeline and serialized `RAW_DATA`, `RAW_HISTORY`, and `RAW_DIRECTORY` inputs unchanged. Replace only the embedded dashboard structure, styles, and display-only JavaScript helpers in `check.bat`; add behavior-focused assertions to the existing Phase 4 test script.

**Tech Stack:** PowerShell 5.1, embedded HTML/CSS/vanilla JavaScript, PowerShell test scripts, Node.js only for parsing extracted JavaScript when available.

## Global Constraints

- Offline and zero dependencies; production remains one `check.bat` file.
- Do not change snapshot JSON schema, comparison states, baseline selection, scan completeness, exclusions, explanation-rate calculation, CSV behavior, or historical trend data.
- Use the exact light/dark and semantic colors in the frozen specification.
- Preserve search, sorting, compact mode, theme switching, summary copy, history download, capacity ring, drive cards, progress bars, trends, and full-disk prediction.
- Do not add any item listed under Explicit Non-goals.
- Do not stage `runtime/`, `DiskPulse.csv`, `DiskPulse.html`, `AGENTS.md`, or the shortcut.
- Do not perform browser or screenshot inspection; report the manual viewport checklist to the user.

---

### Task 1: Behavioral test harness and semantic fixtures

**Files:**
- Modify: `tests/DiskPulse.Phase4.Tests.ps1`

**Interfaces:**
- Consumes: the embedded here-string from `check.bat`.
- Produces: extracted HTML/JavaScript plus fixture-based checks for reliable ranking, fallback copy, filters, DOM regions, and JavaScript syntax.

- [ ] **Step 1: Add fixture-driven assertions that initially fail**

Add a small Node script generated in the test temp directory. It must extract/evaluate pure display helpers with fixtures containing `created`, `changed`, `removed`, `unknown`, and `unavailable` rows, then assert:

```javascript
const rows = reliableChanges(fixture, 1);
assert.deepStrictEqual(rows.map(row => row.state), ["created", "removed"]);
assert.deepStrictEqual(rankChanges(rows).growth.map(row => row.displayPath), ["C:\\Grow"]);
assert.deepStrictEqual(rankChanges(rows).release.map(row => row.displayPath), ["C:\\Release"]);
assert.equal(defaultChangeFilters.level, "1");
assert.equal(defaultChangeFilters.direction, "all");
assert.equal(defaultChangeFilters.state, "reliable");
```

Also assert the exact state copy:

```javascript
assert.equal(emptyChangeCopy({ waiting: true }), "当前磁盘正在建立首次完整基线");
assert.equal(emptyChangeCopy({ comparable: true, released: false }), "本次没有明显释放");
assert.equal(emptyChangeCopy({ comparable: true }), "当前没有可可靠归因的目录变化");
```

- [ ] **Step 2: Add structural assertions**

Require IDs/classes for `summary-grid`, `capacity-summary`, `latest-change`, `comparison-confidence`, `system-conclusion`, state and path filters, separate growth/release lists, drive expanders, completeness groups, scan metadata, copy-path controls, and both theme markers. Assert no `INJECT_[A-Z_]+` remains after fixture substitution.

- [ ] **Step 3: Verify the new tests fail**

Run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests\DiskPulse.Phase4.Tests.ps1
```

Expected: failure naming the first missing hierarchy helper or DOM region.

---

### Task 2: Three-card summary and deterministic conclusion

**Files:**
- Modify: `check.bat` embedded HTML/CSS/JavaScript only
- Test: `tests/DiskPulse.Phase4.Tests.ps1`

**Interfaces:**
- Consumes: `DATA`, `DIRECTORY`, `HISTORY`, `totals()`, reliable `coverage` values.
- Produces: `summaryFor(items)`, `confidenceFor(items)`, `capacityConclusion()`, `changeConclusion(summary)`, and `renderSummary()`.

- [ ] **Step 1: Replace the old overview/insight row with the specified summary grid**

Use semantic articles in this order:

```html
<section class="summary-grid" id="summary-grid">
  <article class="summary-card capacity-summary" id="capacity-summary"></article>
  <article class="summary-card latest-change" id="latest-change"></article>
  <article class="summary-card comparison-confidence" id="comparison-confidence"></article>
</section>
<section class="system-conclusion" id="system-conclusion" aria-label="系统结论"></section>
```

- [ ] **Step 2: Derive summary values from reliable rows only**

Implement one shared selector so the summary and rankings cannot disagree:

```javascript
const defaultChangeFilters = { drive: "all", level: "1", direction: "all", state: "reliable", query: "" };
function selectedDirectoryItems(filters) { /* filter DIRECTORY by drive */ }
function selectedChangeRows(filters) { /* call reliableChanges; filter level, direction, query */ }
function rankChanges(rows) { /* return separately sorted growth and release arrays */ }
```

Aggregate added/released/located values only from selected comparable drives. When `activityPreferred` is true or actual/located directions differ, show added/released activity rather than a primary explanation percentage.

- [ ] **Step 3: Render honest deterministic state copy**

The capacity statement is based on the highest-use drive and the existing 75/90 thresholds. Confidence state is green for all comparable, blue-gray for waiting, orange for partial, and red only when every scanned drive failed. The conclusion contains at most capacity, change, and reliability statements.

- [ ] **Step 4: Apply the frozen color tokens and responsive order**

Use `1.05fr 1.65fr .9fr` on wide screens; at medium width put capacity/confidence together and latest change full-width; at mobile order latest change, capacity, confidence, then conclusion. Keep controls visually secondary and include reduced-motion overrides.

- [ ] **Step 5: Run Phase 4 tests**

Expected: summary and conclusion assertions pass; remaining detail/drive assertions may still fail.

---

### Task 3: Filtered change details and honest rankings

**Files:**
- Modify: `check.bat` embedded HTML/CSS/JavaScript only
- Test: `tests/DiskPulse.Phase4.Tests.ps1`

**Interfaces:**
- Consumes: `defaultChangeFilters`, `selectedChangeRows()`, `rankChanges()` from Task 2.
- Produces: filter controls, `changeRow(row, maxMagnitude, index)`, explicit empty states, and consistent rerendering.

- [ ] **Step 1: Add the complete filter set**

Keep drive, add level options `1`, `2`, `all`; keep direction; add reliable/unknown/unavailable state; add path search. Defaults are all drives, level 1, all directions, reliable state.

- [ ] **Step 2: Render complete ranking rows**

Each row displays path, drive, level, current size, delta, a relative intensity bar, valid contribution percentage, and a visible copy button. The path uses single-line ellipsis, a title tooltip, and a narrow-screen click expansion class.

- [ ] **Step 3: Add exact empty-state selection**

Use `当前磁盘正在建立首次完整基线`, `本次没有明显释放`, and `当前没有可可靠归因的目录变化` according to selected-drive state. Never manufacture a `0 B` rank.

- [ ] **Step 4: Make filters update both latest-change summary and rankings**

Every filter event calls a single `renderChangeView()` that recomputes the summary card, conclusion, and both lists while leaving `capacity-summary` untouched.

- [ ] **Step 5: Run Phase 4 tests**

Expected: all summary/filter/ranking/state-copy fixture assertions pass.

---

### Task 4: Consistent compact drive cards with inline details

**Files:**
- Modify: `check.bat` embedded HTML/CSS/JavaScript only
- Test: `tests/DiskPulse.Phase4.Tests.ps1`

**Interfaces:**
- Consumes: `directoryTopThree()`, `statusLabel()`, `coverageLabel()`, history/trend helpers.
- Produces: a consistent compact card and native `<details>` expansion per drive.

- [ ] **Step 1: Extend the compact card without changing capacity data**

Render drive, usage, completeness/baseline badge, used/total, remaining, bar, directory net change, explanation/activity label, top three paths with intensity and copy controls, sparkline, and existing prediction.

- [ ] **Step 2: Add native inline expansion**

Use `<details class="drive-details">` for top ten paths, level switch, expected exclusions, unexpected errors, baseline time, scan status, and detailed trend. Native details avoids new state machinery and remains keyboard accessible.

- [ ] **Step 3: Stabilize long paths**

Apply `min-width:0`, ellipsis, tooltip, mobile expansion, and a fixed copy-action column. No horizontal page scrolling is permitted.

- [ ] **Step 4: Route copy actions through one delegated handler**

Use `data-copy-path` on every ranking and drive-card button; on success briefly change text to `已复制`, and fall back to `alert(path)` if clipboard access fails.

- [ ] **Step 5: Run Phase 4 tests**

Expected: drive-card and copy-control assertions pass.

---

### Task 5: Completeness, errors, and scan metadata

**Files:**
- Modify: `check.bat` embedded HTML/CSS/JavaScript only
- Test: `tests/DiskPulse.Phase4.Tests.ps1`

**Interfaces:**
- Consumes: current snapshot/directory display data already serialized to the page.
- Produces: collapsed expected-exclusion and unexpected-unavailable groups plus safe metadata fields.

- [ ] **Step 1: Separate expected exclusions from unexpected unavailable items**

Use one collapsed section after drive cards. Group by drive and render reasons/paths under two headings; exclusions must never use error styling.

- [ ] **Step 2: Render only available safe metadata**

Show scan started/completed time, duration, scanned-drive count, and snapshot ID only if supplied to the embedded page. Do not display PID, lock file, or runtime paths. If the current injection lacks those fields, add a display-only `INJECT_SCAN_META` object derived from the already-created `$snapshot` without changing the snapshot itself.

- [ ] **Step 3: Run Phase 4 and JavaScript parse checks**

Expected: all Phase 4 assertions and extracted JavaScript syntax checks pass.

---

### Task 6: Full regression and requirement audit

**Files:**
- Verify: `check.bat`
- Verify: `tests/DiskPulse.Phase1.Tests.ps1`
- Verify: `tests/DiskPulse.Scanner.Tests.ps1`
- Verify: `tests/DiskPulse.Phase3.Tests.ps1`
- Verify: `tests/DiskPulse.Phase4.Tests.ps1`

**Interfaces:**
- Consumes: the completed implementation.
- Produces: evidence for every automated requirement and a manual visual checklist.

- [ ] **Step 1: Run all required tests**

```powershell
$tests = @(
  'tests\DiskPulse.Phase1.Tests.ps1',
  'tests\DiskPulse.Scanner.Tests.ps1',
  'tests\DiskPulse.Phase3.Tests.ps1',
  'tests\DiskPulse.Phase4.Tests.ps1'
)
foreach ($test in $tests) {
  powershell -NoProfile -ExecutionPolicy Bypass -File $test
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}
```

Expected: four PASS results and exit code 0.

- [ ] **Step 2: Run static integrity checks**

```powershell
git diff --check
git status --short
rg -n 'INJECT_[A-Z_]+' check.bat
```

Expected: no whitespace errors; only deliberate injection definitions/replacements; changed files limited to `check.bat` and `tests/DiskPulse.Phase4.Tests.ps1` (the user-supplied design document and ignored plan may remain outside implementation staging).

- [ ] **Step 3: Audit every frozen-spec section**

Confirm the information architecture, copy/state rules, responsive ordering, motion constraints, semantic boundaries, preserved features, non-goals, automated tests, and safe metadata against current source and fresh test output.

- [ ] **Step 4: Hand off manual visual acceptance**

Report that browser visual inspection was not performed by request. Ask the user to check 1366×768, 1920×1080, 2560×1440, 3840×2160, about 900 px, and about 390 px using the ten acceptance questions in the frozen specification.
