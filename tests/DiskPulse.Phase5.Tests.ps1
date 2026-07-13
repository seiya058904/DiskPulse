$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = Split-Path -Parent $PSScriptRoot
$source = Get-Content -Raw -LiteralPath (Join-Path $root 'check.bat') -Encoding UTF8
$env:DISKPULSE_TEST_MODE = '1'
$env:DISKPULSE_ROOT = $root
$env:DISKPULSE_SCRIPT_PATH = Join-Path $root 'check.bat'
Invoke-Expression $source.Substring($source.IndexOf('#>') + 2)

function Rec([string]$Key,[int64]$Size,[int]$Level=1) {
    [pscustomobject]@{ key=$Key; kind='directory'; displayPath=('T:\' + $Key); level=$Level; sizeBytes=$Size }
}
function Drive([string]$Drive,[string]$Status,[string]$Root,[int64]$Used,[array]$Records) {
    [pscustomobject]@{ drive=$Drive; status=$Status; rootPath=$Root; usedBytes=$Used; records=$Records; unavailable=@(); excluded=@(); errors=@() }
}
function Snap([string]$Id,[string]$At,[array]$Drives) {
    [pscustomobject]@{ scanId=$Id; startedAt=$At; completedAt=$At; status='complete'; drives=$Drives }
}

$current = Snap 'now' '2026-07-13T12:00:00Z' @(
    (Drive 'T:' 'complete' 'T:\' 160 @((Rec 'Grow' 100),(Rec 'Gone' 0),(Rec 'Unknown' 20),(Rec 'Unavailable' 20)))
    (Drive 'U:' 'complete' 'U:\' 260 @([pscustomobject]@{key='u';kind='directory';displayPath='U:\Data';level=1;sizeBytes=260}))
)
$failedTop = Snap 'failed-top' '2026-07-13T07:00:00Z' @((Drive 'T:' 'complete' 'T:\' 90 @((Rec 'Grow' 30))))
$failedTop.status = 'failed'
$snapshots = @(
    (Snap 'previous-t' '2026-07-13T11:00:00Z' @((Drive 'T:' 'complete' 'T:\' 100 @((Rec 'Grow' 40),(Rec 'Gone' 30),(Rec 'Unknown' 20),(Rec 'Unavailable' 20)))))
    (Snap 'previous-u' '2026-07-13T10:00:00Z' @((Drive 'U:' 'complete' 'U:\' 200 @([pscustomobject]@{key='u';kind='directory';displayPath='U:\Data';level=1;sizeBytes=200}))))
    (Snap 'partial' '2026-07-13T09:00:00Z' @((Drive 'T:' 'partial' 'T:\' 90 @((Rec 'Grow' 30)))))
    (Snap 'failed' '2026-07-13T08:00:00Z' @((Drive 'T:' 'failed' 'T:\' 90 @((Rec 'Grow' 30)))))
    $failedTop
    (Snap 'day' '2026-07-12T11:40:00Z' @((Drive 'T:' 'baseline' 'T:\' 80 @((Rec 'Grow' 20),(Rec 'Gone' 30)))))
    (Snap 'wrong-root' '2026-07-11T12:00:00Z' @((Drive 'T:' 'complete' 'T:\Other' 70 @((Rec 'Grow' 10)))))
    (Snap 'week' '2026-07-06T12:20:00Z' @((Drive 'T:' 'complete' 'T:\' 60 @((Rec 'Grow' 10),(Rec 'Gone' 30)))))
    (Snap 'earliest' '2026-07-01T12:00:00Z' @((Drive 'T:' 'complete' 'T:\' 50 @((Rec 'Gone' 30)))))
)

$tCandidates = @(Get-DriveHistoryCandidates -Snapshots $snapshots -Drive 'T:' -Current $current)
if (($tCandidates.scanId -join ',') -ne 'previous-t,day,week,earliest') { throw "Unexpected T: candidates: $($tCandidates.scanId -join ',')" }
if ((Select-DriveHistoryBaseline $tCandidates previous $current).scanId -ne 'previous-t') { throw 'Previous selection failed.' }
if ((Select-DriveHistoryBaseline $tCandidates day $current).scanId -ne 'day') { throw '24-hour selection failed.' }
if ((Select-DriveHistoryBaseline $tCandidates week $current).scanId -ne 'week') { throw '7-day selection failed.' }
if ((Select-DriveHistoryBaseline $tCandidates earliest $current).scanId -ne 'earliest') { throw 'Earliest selection failed.' }
if ((Select-DriveHistoryBaseline $tCandidates custom $current 'week').scanId -ne 'week') { throw 'Custom selection failed.' }

$uCandidates = @(Get-DriveHistoryCandidates -Snapshots $snapshots -Drive 'U:' -Current $current)
if ($uCandidates.Count -ne 1 -or $uCandidates[0].scanId -ne 'previous-u') { throw 'Each disk must choose from its own history.' }
if (@(Get-DriveHistoryCandidates -Snapshots @($current) -Drive 'T:' -Current $current).Count -ne 0) { throw 'One snapshot must have no historical baseline.' }

$baseline = Drive 'T:' 'complete' 'T:\' 100 @((Rec 'Grow' 40),(Rec 'Gone' 30),(Rec 'Unknown' 20),(Rec 'Unavailable' 20))
$currentDrive = Drive 'T:' 'partial' 'T:\' 160 @((Rec 'Grow' 100),(Rec 'Created' 10),(Rec 'Unknown' 20))
$currentDrive.unavailable = @([pscustomobject]@{path='T:\Unavailable';reason='entry-unavailable'})
$comparison = New-HistoryComparison -CurrentDrive $currentDrive -BaselineDrive $baseline -BaselineSnapshot (Snap 'base' '2026-07-13T11:00:00Z' @($baseline))
$states = @($comparison.changes | Group-Object state | ForEach-Object Name)
foreach ($state in 'created','changed','unknown','unavailable') { if ($state -notin $states) { throw "Missing historical state: $state" } }
if (@($comparison.changes | Where-Object state -eq 'removed').Count) { throw 'Partial current scans must not claim removals.' }
if ($comparison.coverage.addedBytes -ne 70 -or $comparison.coverage.releasedBytes -ne 0) { throw 'Unknown and unavailable rows must not enter reliable totals.' }

$completeDrive = Drive 'T:' 'complete' 'T:\' 160 @((Rec 'Grow' 100),(Rec 'Created' 10))
$completeComparison = New-HistoryComparison -CurrentDrive $completeDrive -BaselineDrive $baseline -BaselineSnapshot (Snap 'base' '2026-07-13T11:00:00Z' @($baseline))
if (@($completeComparison.changes | Where-Object state -eq 'removed').Count -ne 3) { throw 'Complete historical comparisons must preserve removed semantics.' }

if ((Get-DirectoryTrendClassification @(
    [pscustomobject]@{state='changed';deltaBytes=10},[pscustomobject]@{state='changed';deltaBytes=20},[pscustomobject]@{state='changed';deltaBytes=30}
)).label -ne '持续增长') { throw 'Sustained growth rule failed.' }
if ((Get-DirectoryTrendClassification @(
    [pscustomobject]@{state='changed';deltaBytes=-10},[pscustomobject]@{state='changed';deltaBytes=-20},[pscustomobject]@{state='removed';deltaBytes=-30}
)).label -ne '持续释放') { throw 'Sustained release rule failed.' }
if ((Get-DirectoryTrendClassification @([pscustomobject]@{state='changed';deltaBytes=10})).label -ne '数据不足') { throw 'Insufficient sample rule failed.' }
if ((Get-DirectoryTrendClassification @(
    [pscustomobject]@{state='changed';deltaBytes=10},[pscustomobject]@{state='changed';deltaBytes=-9},[pscustomobject]@{state='changed';deltaBytes=8}
)).label -ne '波动较大') { throw 'Volatility rule failed.' }
if ((Get-DirectoryTrendClassification @([pscustomobject]@{state='created';deltaBytes=100})).label -ne '首次出现') { throw 'First appearance rule failed.' }
if ((Get-DirectoryTrendClassification @(
    [pscustomobject]@{state='changed';deltaBytes=4},[pscustomobject]@{state='changed';deltaBytes=5},[pscustomobject]@{state='changed';deltaBytes=40}
)).label -ne '本次突增') { throw 'Spike rule failed.' }

$history = @(New-HistoryComparisonCenter -Snapshots $snapshots -Current $current)
if ($history.Count -ne 2) { throw 'History payload must include each current disk.' }
$tHistory = $history | Where-Object drive -eq 'T:'
if ($tHistory.selections.day -ne 'day' -or $tHistory.selections.week -ne 'week') { throw 'Range selections were not serialized.' }
if (-not @($tHistory.trends | Where-Object level -eq 1).Count) { throw 'Level-one trend series are required.' }

$markers = @('INJECT_HISTORY_CENTER','id="history-range"','id="history-range-note"','id="history-tabs"','role="tablist"','data-history-tab="growth"','data-history-tab="release"','data-history-tab="trend"','id="sustained-growth-list"','id="sustained-release-list"','id="history-trend-list"','class="history-expand"','history-custom-baseline')
foreach ($marker in $markers) { if ($source -notmatch [regex]::Escape($marker)) { throw "Missing history center marker: $marker" } }

$helperMatch = [regex]::Match($source, '(?s)// TESTABLE_HISTORY_HELPERS_START(?<code>.*?)// TESTABLE_HISTORY_HELPERS_END')
if (-not $helperMatch.Success) { throw 'Missing testable history helper block.' }
$fixtureTest = @'
const assert = require("node:assert/strict");
const disk = {selections:{previous:"p",day:"d",week:"w",earliest:"e"},comparisons:[{scanId:"p"},{scanId:"d"},{scanId:"w"},{scanId:"e"}]};
assert.equal(selectHistoryComparison(disk,"day").scanId,"d");
assert.equal(selectHistoryComparison(disk,"week").scanId,"w");
assert.equal(selectHistoryComparison(disk,"custom","p").scanId,"p");
assert.equal(defaultHistoryCustomScanId(disk),"p");
assert.equal(selectHistoryComparison({selections:{},comparisons:[]},"day"),null);
assert.deepEqual(reliableHistoryRows([{state:"changed",deltaBytes:2},{state:"created",deltaBytes:3},{state:"removed",deltaBytes:-4},{state:"unknown",deltaBytes:99},{state:"unavailable",deltaBytes:-99}]).map(x=>x.state),["changed","created","removed"]);
const tenRows = Array.from({length:10},(_,index)=>({index}));
assert.equal(visibleHistoryRows(tenRows,"growth",{}).length,5);
assert.equal(visibleHistoryRows(tenRows,"release",{}).length,5);
assert.equal(visibleHistoryRows(tenRows,"trend",{}).length,6);
assert.equal(visibleHistoryRows(tenRows,"growth",{growth:true}).length,10);
console.log("PASS: history center behavior fixtures.");
'@
$temp = Join-Path ([IO.Path]::GetTempPath()) ('DiskPulse-Phase5-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($temp) | Out-Null
try {
    $behaviorFile = Join-Path $temp 'history.js'
    [IO.File]::WriteAllText($behaviorFile, $helperMatch.Groups['code'].Value + [Environment]::NewLine + $fixtureTest, [Text.UTF8Encoding]::new($false))
    & node $behaviorFile
    if ($LASTEXITCODE -ne 0) { throw 'History center behavior fixture failed.' }

    $scriptMatch = [regex]::Match($source, '(?s)<script>(?<script>.*?)</script>')
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

foreach ($marker in @('[data-theme="dark"]','@media (max-width: 560px)','id="themeBtn"')) {
    if ($source -notmatch [regex]::Escape($marker)) { throw "Stable theme or responsive marker missing: $marker" }
}
if ($source -notmatch [regex]::Escape('.history-row-meta { color: var(--muted); display: flex; font-size: 12px;')) { throw 'History helper text must remain readable at 12px.' }
if ($source -notmatch [regex]::Escape('本范围内没有持续释放目录。')) { throw 'The empty release tab must use compact honest copy.' }
Write-Host 'PASS: history comparison center selection, semantics, trends, and embedded JavaScript.'
