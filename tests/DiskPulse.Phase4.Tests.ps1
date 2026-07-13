$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$source = Get-Content -Raw -LiteralPath (Join-Path $root 'check.bat') -Encoding UTF8

$stable = @('class="grid"','sparkline','estimateDays','id="search"','id="sort"','id="compact"','id="copy"','data-theme','@media')
$hierarchy = @(
    'id="summary-grid"', 'id="capacity-summary"', 'id="latest-change"',
    'id="comparison-confidence"', 'id="system-conclusion"', 'id="change-details"',
    'id="growth-list"', 'id="release-list"', 'id="change-drive-filter"',
    'id="change-level-filter"', 'id="change-direction-filter"', 'id="change-state-filter"',
    'id="change-path-filter"', 'id="state-change-list"', 'class="drive-details"', 'data-copy-path',
    'id="scan-completeness"', 'id="scan-metadata"', 'INJECT_SCAN_META',
    'release-empty', 'conclusion-item', 'snapshot-copy', '@media (max-width: 1500px)'
)
foreach ($marker in @($stable + $hierarchy)) {
    if ($source -notmatch [regex]::Escape($marker)) { throw "Missing dashboard marker: $marker" }
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

$temp = Join-Path ([IO.Path]::GetTempPath()) ('DiskPulse-Phase4-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($temp) | Out-Null
try {
    $behaviorFile = Join-Path $temp 'behavior.js'
    [IO.File]::WriteAllText($behaviorFile, $helperMatch.Groups['code'].Value + [Environment]::NewLine + $fixtureTest, [Text.UTF8Encoding]::new($false))
    & node $behaviorFile
    if ($LASTEXITCODE -ne 0) { throw 'Dashboard behavior fixture failed.' }

    $scriptMatch = [regex]::Match($source, '(?s)<script>(?<script>.*?)</script>')
    if (-not $scriptMatch.Success) { throw 'Embedded JavaScript was not found.' }
    $script = $scriptMatch.Groups['script'].Value.Replace('INJECT_HISTORY_CENTER','[]').Replace('INJECT_DATA','[]').Replace('INJECT_HISTORY','[]').Replace('INJECT_DIRECTORY','[]').Replace('INJECT_SCAN_META','{}').Replace('INJECT_TS','test')
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
foreach ($forbidden in @('SMART','性能衰退','健康指标','实时监控')) {
    if ($readme -match [regex]::Escape($forbidden)) { throw "README contains unverified claim: $forbidden" }
}
Write-Host 'PASS: visual hierarchy, state behavior, and embedded JavaScript.'
