$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$source = Get-Content -Raw -LiteralPath (Join-Path $root 'check.bat') -Encoding UTF8

$stable = @('class="grid"','sparkline','estimateDays','id="search"','id="sort"','id="compact"','id="copy"','data-theme','@media')
$hierarchy = @(
    'class="product-header"', 'class="header-brand"', 'class="brand-mark"',
    'hero-grid', 'hero-card-primary latest-change',
    'id="summary-grid"', 'id="capacity-summary"', 'id="latest-change"',
    'id="comparison-confidence"', 'id="attention-center"', 'id="attention-list"', 'id="change-details"',
    'id="growth-list"', 'id="release-list"', 'id="change-drive-filter"',
    'id="change-level-filter"', 'id="change-direction-filter"', 'id="change-state-filter"',
    'id="change-path-filter"', 'id="state-change-list"', 'element("details","drive-details")', 'dataset.copyPath',
    'id="capacity-visuals"', 'id="capacity-drive-select"', 'id="capacity-range"',
    'id="capacity-trend-chart"', 'id="print-report"', 'id="section-nav"',
    'id="scan-completeness"', 'id="scan-metadata"', 'INJECT_SCAN_META', 'INJECT_SYSTEM_DRIVE',
    'id="release-empty-note"', 'id="growth-empty-note"', 'class="action-group action-search"',
    'class="action-group action-display"', 'class="action-group action-report"',
    'root.dataset.count', 'only-growth', 'only-release', 'both-empty', 'capacity-current',
    'attention-strip', 'change-ranking', 'history-summary-strip', 'dashboard-footer',
    'confidence-illustration', 'trend-summary', 'history-rail', 'disk-card-grid', 'scan-summary-card',
    'capacity-area', 'attention-item', 'snapshot-copy', '@media (max-width: 1500px)',
    '.capacity-area {', 'classList.add("capacity-area")'
)
foreach ($marker in @($stable + $hierarchy)) {
    if ($source -notmatch [regex]::Escape($marker)) { throw "Missing dashboard marker: $marker" }
}

$bodyMatch = [regex]::Match($source, '(?s)<body>(?<body>.*?)<script>')
if (-not $bodyMatch.Success) { throw 'Static dashboard body was not found.' }
$ids = @([regex]::Matches($bodyMatch.Groups['body'].Value, '\bid="(?<id>[^"]+)"') | ForEach-Object { $_.Groups['id'].Value })
$duplicateIds = @($ids | Group-Object | Where-Object Count -gt 1)
if ($duplicateIds.Count) { throw "Duplicate static DOM id: $($duplicateIds[0].Name)" }
$navMatch = [regex]::Match($bodyMatch.Groups['body'].Value, '(?s)<nav class="section-nav".*?</nav>')
foreach ($link in [regex]::Matches($navMatch.Value, 'href="#(?<id>[^"]+)"')) {
    if ($ids -notcontains $link.Groups['id'].Value) { throw "Navigation target is missing: $($link.Groups['id'].Value)" }
}

if ($source -match [regex]::Escape("`$html.Replace('INJECT_")) { throw 'Dashboard placeholders must be replaced in one pass.' }
if ($source -match 'innerHTML\s*=') { throw 'Dynamic dashboard content must use safe DOM APIs instead of innerHTML.' }
$injectionTemplate = 'const data=INJECT_DATA;const ts=INJECT_TS_JSON;'
$injectionMap = @{ INJECT_DATA = '"%!&<>|''INJECT_TS_JSON"'; INJECT_TS_JSON = '"safe-time"' }
$injectionPattern = 'INJECT_(?:TS_JSON|DATA)'
$injectionResult = [regex]::Replace($injectionTemplate, $injectionPattern, { param($match) [string]$injectionMap[$match.Value] })
if ($injectionResult -ne 'const data="%!&<>|''INJECT_TS_JSON";const ts="safe-time";') { throw 'One-pass placeholder replacement altered inserted content.' }

foreach ($id in 'search','sort','compact','themeBtn','copy','print-report','history-range') {
    $binding = '$(' + '"' + $id + '"' + ').addEventListener'
    if ([regex]::Matches($source,[regex]::Escape($binding)).Count -ne 1) { throw "Expected exactly one event binding for $id." }
}

$gitignore = Get-Content -Raw -LiteralPath (Join-Path $root '.gitignore') -Encoding UTF8
foreach ($exception in '!/PRODUCT.md','!/DESIGN.md') {
    if ($gitignore -notmatch ('(?m)^' + [regex]::Escape($exception) + '\r?$')) { throw "Missing version-control exception: $exception" }
}

if ($source -notmatch [regex]::Escape('$directoryJson = ConvertTo-JsonArray ([object[]]$directoryResults)')) {
    throw 'Directory result serialization must materialize the generic list as object[].'
}
foreach ($copy in @('本次没有明显释放','当前没有可可靠归因的目录变化','当前磁盘正在建立首次完整基线')) {
    if ($source -notmatch [regex]::Escape($copy)) { throw "Missing honest empty-state copy: $copy" }
}
foreach ($forbidden in @('磁盘健康','硬盘寿命','性能下降','安全风险','智能清理')) {
    if ($source -match [regex]::Escape($forbidden)) { throw "Dashboard contains prohibited terminology: $forbidden" }
}

$helperMatch = [regex]::Match($source, '(?s)// TESTABLE_CHANGE_HELPERS_START(?<code>.*?)// TESTABLE_CHANGE_HELPERS_END')
if (-not $helperMatch.Success) { throw 'Missing testable change helper block.' }
$fixtureTest = @'
const assert = require("node:assert/strict");
const fixture = [
  { drive:"C:", status:"complete", baselineScanId:"base", coverage:{actualNetBytes:60,locatedNetBytes:60,addedBytes:100,releasedBytes:40,rate:100,activityPreferred:true}, changes:[
    {state:"created",level:1,displayPath:"C:\\Grow",deltaBytes:100,currentBytes:100},
    {state:"removed",level:1,displayPath:"C:\\Release",deltaBytes:-40,currentBytes:0},
    {state:"unknown",level:1,displayPath:"C:\\Unknown",deltaBytes:999,currentBytes:999},
    {state:"unavailable",level:1,displayPath:"C:\\Unavailable",deltaBytes:888,currentBytes:888},
    {state:"changed",level:2,displayPath:"C:\\Grow\\Child",deltaBytes:10,currentBytes:10}
  ]}
];
const rows = filterChangeRows(fixture, defaultChangeFilters);
assert.deepEqual(rows.map(row => row.state), ["created","removed"]);
const ranked = rankChanges(rows);
assert.deepEqual(ranked.growth.map(row => row.displayPath), ["C:\\Grow"]);
assert.deepEqual(ranked.release.map(row => row.displayPath), ["C:\\Release"]);
const unknownRows = filterChangeRows(fixture, {...defaultChangeFilters,state:"unknown"});
assert.deepEqual(unknownRows.map(row => row.displayPath), ["C:\\Unknown"]);
assert.deepEqual(rankChanges(unknownRows), {growth:[],release:[]});
assert.equal(defaultChangeFilters.drive, "all");
assert.equal(defaultChangeFilters.level, "1");
assert.equal(defaultChangeFilters.direction, "all");
assert.equal(defaultChangeFilters.state, "reliable");
assert.equal(statusLabel("failed", false), "扫描失败");
const evidence = classifyScanEvidence([{drive:"C:",excluded:[{path:"C:\\Link",reason:"reparse-point"},{path:"C:\\Private",reason:"access-denied"}],unavailable:[{path:"C:\\Gone",reason:"entry-unavailable"}],errors:[]}]);
assert.deepEqual(evidence.expected.map(row => row.path), ["C:\\Link"]);
assert.deepEqual(evidence.unexpected.map(row => row.path), ["C:\\Private","C:\\Gone"]);
assert.equal(confidenceFor([{drive:"C:",status:"baseline",baselineScanId:null}]).state, "waiting");
assert.equal(confidenceFor([{drive:"C:",status:"partial",baselineScanId:"base"}]).state, "partial");
assert.equal(confidenceFor([{drive:"C:",status:"failed",baselineScanId:null}]).state, "failed");
const noChange = summarizeChanges([{drive:"C:",status:"complete",baselineScanId:"base",coverage:{actualNetBytes:0}}], []);
assert.equal(noChange.added, 0);
assert.equal(noChange.released, 0);
assert.equal(noChange.rate, null);
assert.equal(formatCapacityDelta(0.0158203125), "增加 16.2 MB");
assert.equal(formatCapacityDelta(-0.001), "减少 1.0 MB");
assert.equal(formatCapacityDelta(0.0000005), "容量基本不变");
const localFixture = new Date(2026, 6, 13, 14, 42, 14).toISOString();
assert.equal(formatLocalDate(localFixture), "2026-07-13 14:42:14");
assert.equal(shortSnapshotId("20260713-abcdef123456"), "20260713…");
assert.equal(currentSizeBytes({sizeBytes:123456,currentBytes:0}), 123456);
assert.equal(emptyChangeCopy({waiting:true}), "当前磁盘正在建立首次完整基线");
assert.equal(emptyChangeCopy({comparable:true,kind:"release"}), "本次没有明显释放");
assert.equal(emptyChangeCopy({comparable:true,kind:"all"}), "当前没有可可靠归因的目录变化");
console.log("PASS: dashboard behavior fixtures.");
'@

$capacityMatch = [regex]::Match($source, '(?s)// TESTABLE_CAPACITY_HELPERS_START(?<code>.*?)// TESTABLE_CAPACITY_HELPERS_END')
if (-not $capacityMatch.Success) { throw 'Missing testable capacity helper block.' }
$capacityFixture = @'
const assert = require("node:assert/strict");
function fmt(value){ return `${Number(value).toFixed(1)} GB`; }
function pct(value){ return `${Number(value).toFixed(1)}%`; }
function fmtBytes(value){ return `${value} B`; }
function isReliableChange(row){ return ["created","changed","removed"].includes(row.state); }
const drives = [
  {id:"C:",status:"good",percent:40,free:60,total:100,used:40},
  {id:"D:",status:"critical",percent:92,free:8,total:100,used:92},
  {id:"E:",status:"critical",percent:95,free:20,total:400,used:380}
];
assert.equal(defaultCapacityDrive(drives,"C:"),"E:");
assert.equal(defaultCapacityDrive(drives.filter(x=>x.status!=="critical"),"C:"),"C:");
assert.deepEqual(capacityDriveOrder(drives).map(x=>x.id),["E:","D:","C:"]);
const history = [
  {ID:"C:",Timestamp:"2026-07-01T00:00:00Z",Total:100,Used:20},
  {ID:"C:",Timestamp:"2026-07-01T00:00:00Z",Total:100,Used:25},
  {ID:"C:",Timestamp:"bad",Total:100,Used:30},
  {ID:"C:",Timestamp:"2026-07-02T00:00:00Z",Total:0,Used:0},
  {ID:"C:",Timestamp:"2026-07-03T00:00:00Z",Total:100,Used:-1},
  {ID:"C:",Timestamp:"2026-07-04T00:00:00Z",Total:100,Used:101},
  {ID:"D:",Timestamp:"2026-07-02T00:00:00Z",Total:100,Used:50}
];
const samples = cleanCapacitySamples(history,drives[0],"C:","2026-07-13T00:00:00Z");
assert.deepEqual(samples.map(x=>x.used),[25,40]);
assert.equal(filterCapacitySamples(samples,"7","2026-07-13T00:00:00Z").length,1);
assert.equal(filterCapacitySamples([],"30","2026-07-13T00:00:00Z").length,0);
assert.equal(filterCapacitySamples(samples,"all","2026-07-13T00:00:00Z").length,2);
assert.equal(capacityTrendStats([samples[0]]).change,null);
assert.equal(capacityTrendStats(samples).change,15);
const attention = buildAttentionItems(drives,[{status:"partial"}],[{state:"changed",deltaBytes:10,displayPath:"C:\\Data"}]);
assert.deepEqual(attention.map(x=>x.kind),["critical","incomplete","change"]);
console.log("PASS: capacity visualization helpers.");
'@

$temp = Join-Path ([IO.Path]::GetTempPath()) ('DiskPulse-Phase4-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($temp) | Out-Null
try {
    $behaviorFile = Join-Path $temp 'behavior.js'
    [IO.File]::WriteAllText($behaviorFile, $helperMatch.Groups['code'].Value + [Environment]::NewLine + $fixtureTest, [Text.UTF8Encoding]::new($false))
    & node $behaviorFile
    if ($LASTEXITCODE -ne 0) { throw 'Dashboard behavior fixture failed.' }

    $capacityFile = Join-Path $temp 'capacity.js'
    [System.IO.File]::WriteAllText($capacityFile, $capacityMatch.Groups['code'].Value + [Environment]::NewLine + $capacityFixture, [Text.UTF8Encoding]::new($false))
    & node $capacityFile
    if ($LASTEXITCODE -ne 0) { throw 'Capacity visualization fixture failed.' }

    $scriptMatch = [regex]::Match($source, '(?s)<script>(?<script>.*?)</script>')
    if (-not $scriptMatch.Success) { throw 'Embedded JavaScript was not found.' }
    $script = $scriptMatch.Groups['script'].Value.Replace('INJECT_HISTORY_CENTER','[]').Replace('INJECT_SYSTEM_DRIVE','"C:"').Replace('INJECT_DATA','[]').Replace('INJECT_HISTORY','[]').Replace('INJECT_DIRECTORY','[]').Replace('INJECT_SCAN_META','{}').Replace('INJECT_TS_JSON','"test"')
    if ($script -match 'INJECT_[A-Z_]+') { throw "Unresolved dashboard placeholder: $($Matches[0])" }
    $scriptFile = Join-Path $temp 'dashboard.js'
    [IO.File]::WriteAllText($scriptFile, $script, [Text.UTF8Encoding]::new($false))
    & node --check $scriptFile
    if ($LASTEXITCODE -ne 0) { throw 'Embedded JavaScript does not parse.' }
}
finally {
    Get-ChildItem -LiteralPath $temp -File | ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force }
    Remove-Item -LiteralPath $temp
}

$readme = Get-Content -Raw -LiteralPath (Join-Path $root 'README.md') -Encoding UTF8
foreach ($marker in @('@media print','@media (prefers-reduced-motion: reduce)','scroll-margin-top','aria-live="polite"','aria-pressed="true"')) {
    if ($source -notmatch [regex]::Escape($marker)) { throw "Missing print, motion, navigation, or accessibility marker: $marker" }
}
if ($source -notmatch [regex]::Escape('.latest-change, [data-theme="dark"] .latest-change { background: #fff;')) { throw 'Print mode must override the dark primary card without !important.' }
foreach ($responsiveRule in @(
    'grid-template-areas: "change change" "capacity confidence"',
    '.latest-change { order: 1; } .capacity-summary { order: 2; } .comparison-confidence { order: 3; }',
    '.action-search { grid-template-columns: 1fr 1fr; }',
    '.copy-path, .overview-scan-state { min-height:44px; }'
)) {
    if ($source -notmatch [regex]::Escape($responsiveRule)) { throw "Missing required responsive summary order: $responsiveRule" }
}
foreach ($marker in @('查看全部磁盘','当前使用','总容量','可用容量','较范围起点','Top 增长','Top 释放')) {
    if ($source -notmatch [regex]::Escape($marker)) { throw "Missing concept-aligned dashboard copy: $marker" }
}
if ([regex]::Matches($source,'(?m)^\s*\.product-header\s*\{').Count -ne 1) { throw 'Product header must have one authoritative component rule.' }
if ([regex]::Matches($source,'(?m)^\s*:root\s*\{').Count -ne 1) { throw 'Design tokens must have one authoritative root definition.' }
foreach ($forbidden in @('SMART','性能衰退','健康指标','实时监控')) {
    if ($readme -match [regex]::Escape($forbidden)) { throw "README contains unverified claim: $forbidden" }
}
Write-Host 'PASS: visual hierarchy, state behavior, and embedded JavaScript.'
