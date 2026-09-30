$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'TestHelpers.ps1')
$source = New-DiskPulseCanonicalTestSource -Components @('Common','History')
try { . $source } finally { Remove-Item -LiteralPath $source -Force }

function Assert-Identity([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}
function Identity-Drive([string]$Guid, [int64]$Size) {
    [pscustomobject]@{
        drive='T:'; rootPath='T:\'; volumeGuid=$Guid; status='complete';
        totalBytes=2000; usedBytes=$Size; freeBytes=(2000-$Size);
        scopeSignature='same-scope'; enumerationComplete=$true; childrenEnumerationComplete=$true;
        unavailable=@(); excluded=@(); errors=@(); records=@([pscustomobject]@{
            key='t:\data'; displayPath='T:\Data'; kind='directory'; level=1; sizeBytes=$Size;
            enumerationComplete=$true; childrenEnumerationComplete=$true
        })
    }
}
function Identity-Snapshot([string]$Id, [int]$Day, $Drive) {
    [pscustomobject]@{scanId=$Id; startedAt=('2026-01-{0:00}T00:00:00Z' -f $Day); completedAt=('2026-01-{0:00}T00:01:00Z' -f $Day); status='complete'; drives=@($Drive)}
}
$guidA='\\?\Volume{11111111-1111-1111-1111-111111111111}'
$guidB='\\?\Volume{22222222-2222-2222-2222-222222222222}'
$a=Identity-Snapshot 'a' 1 (Identity-Drive $guidA 1000)
$b=Identity-Snapshot 'b' 2 (Identity-Drive $guidB 10)
$wrong=Find-DriveBaseline @($a) 'T:' $b
$rows=@(Compare-DriveRecords $b.drives[0] $a.drives[0])
Write-Host ('CROSS_VOLUME baseline={0} rows={1}' -f $(if($wrong){$wrong.scanId}else{'none'}),($rows|ConvertTo-Json -Compress))
Assert-Identity ($null -eq $wrong) 'ISSUE21_CROSS_VOLUME_BASELINE: a different fixed volume must not be a baseline.'
Assert-Identity (@($rows|Where-Object state -in @('created','changed','removed','unchanged')).Count -eq 0) 'Different volumes must not produce reliable rows.'
Write-Host 'PASS: volume identity rejects cross-volume baselines and comparisons.'

$b2=Identity-Snapshot 'b2' 3 (Identity-Drive ($guidB.ToLowerInvariant()+'\') 20)
$a2=Identity-Snapshot 'a2' 4 (Identity-Drive $guidA 1005)
Assert-Identity ((Find-DriveBaseline @($a,$b) 'T:' $b2).scanId -eq 'b') 'B second scan must select B first scan.'
Assert-Identity ((Find-DriveBaseline @($a,$b,$b2) 'T:' $a2).scanId -eq 'a') 'Returning A must select only A history.'
$candidates=@(Get-DriveHistoryCandidates @($a,$b) 'T:' $b2)
Assert-Identity ($candidates.Count -eq 1 -and $candidates[0].scanId -eq 'b') 'Historical candidates must be volume-scoped.'
Assert-Identity ($null -eq (Select-DriveHistoryBaseline $candidates 'custom' $b2 'a')) 'Custom selection cannot restore a foreign-volume baseline.'
$center=@(New-HistoryComparisonCenter @($a,$b) $b2)
Assert-Identity ($center[0].comparisons.Count -eq 1 -and $center[0].trends[0].cumulativeBytes -eq 10) 'Trend pairs must exclude A and preserve B growth.'
Assert-Identity ((Get-ChangeCoverage $b.drives[0] $a.drives[0] $rows).releasedBytes -eq 0) 'Foreign-volume coverage must exclude release.'
Assert-Identity ($null -eq (Get-ChangeCoverage $b.drives[0] $a.drives[0] $rows).actualNetBytes) 'Foreign-volume capacity delta must be unknown.'
foreach($unknown in @('', 'not-a-guid', '\\?\Volume{invalid}')) {
    $u=Identity-Snapshot 'unknown' 5 (Identity-Drive $unknown 30)
    Assert-Identity ($null -eq (Find-DriveBaseline @($a,$b,$b2) 'T:' $u)) 'Unknown current identity must never match history.'
    Assert-Identity (@(Get-DriveHistoryCandidates @($u) 'T:' (Identity-Snapshot 'unknown2' 6 (Identity-Drive $unknown 40))).Count -eq 0) 'Unknown identity must not match itself.'
    Assert-Identity (@(Compare-DriveRecords $b.drives[0] $u.drives[0] | Where-Object state -ne 'unknown').Count -eq 0) 'Unknown baseline must suppress comparisons.'
}
$legacy=Identity-Snapshot 'legacy' 1 (Identity-Drive $guidB 900)
$legacy.drives[0].PSObject.Properties.Remove('volumeGuid')
Assert-Identity ($null -eq (Find-DriveBaseline @($legacy) 'T:' $b2)) 'Legacy snapshot without identity must not be upgraded by guessing.'
Assert-Identity (-not (Test-DiskPulseSameVolume $legacy.drives[0] $legacy.drives[0])) 'Legacy identity must not prove equality.'

$source = New-DiskPulseCanonicalTestSource -Components @('AI')
try { . $source } finally { Remove-Item -LiteralPath $source -Force }
$withoutBaseline=[pscustomobject]@{drive='T:';status='baseline';baselineScanId=$null;changes=@(Compare-DriveRecords $b.drives[0] $null);coverage=(Get-ChangeCoverage $b.drives[0] $null @());errors=@();excluded=@();unavailable=@()}
$input=New-DiskPulseAIInput @($withoutBaseline) @(New-HistoryComparisonCenter @($a) $b) $b
Assert-Identity ($input.primaryGrowth.Count -eq 0 -and $input.primaryRelease.Count -eq 0 -and $input.historicalTrends.Count -eq 0) 'AI must have no cross-volume growth, release or trend evidence.'
Assert-Identity (-not $input.drives[0].comparisonAvailable -and $null -eq $input.drives[0].actualNetChangeBytes) 'AI must identify unavailable comparison rather than a measured zero.'
foreach($field in @('actualNetChangeBytes','locatedNetChangeBytes','unexplainedBytes','coverageRate')) { Assert-Identity ($null -eq $input.drives[0].$field) 'Unavailable AI measurements must remain null.' }
Assert-Identity (-not (Test-DiskPulseAIInputEligible @($withoutBaseline))) 'A replacement volume must not trigger AI analysis.'
Assert-Identity (($input|ConvertTo-Json -Depth 12) -notmatch 'Volume\{|volumeGuid') 'AI payload must not transmit raw volume identity.'
Assert-Identity ($input.drives[0].volumeRef -eq 'volume-1' -and $input.drives[0].volumeIdentityState -eq 'known') 'Known current volume must have an analysis-local reference even without a baseline.'
$unknownSnapshot=Identity-Snapshot 'unknown-ai' 6 (Identity-Drive '' 50)
$unknownInput=New-DiskPulseAIInput @($withoutBaseline) @() $unknownSnapshot
Assert-Identity ($null -eq $unknownInput.drives[0].volumeRef -and $unknownInput.drives[0].volumeIdentityState -eq 'unknown' -and -not $unknownInput.drives[0].comparisonAvailable) 'Unknown volume identity must have no AI reference or comparison.'
$sameInput=New-DiskPulseAIInput @($withoutBaseline) @() $a
Assert-Identity ($sameInput.drives[0].volumeRef -eq 'volume-1') 'Reference allocation must restart for each input, not persist a volume identifier.'


# Real CSV writer/reader, mixing legacy rows first with new rows of the same letter/time.
$temp=Join-Path $env:TEMP ('DiskPulse-VolumeIdentity-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temp | Out-Null
try {
    $csv=Join-Path $temp 'mixed.csv'
    $oldRow=[pscustomobject]@{Timestamp='2026-01-01';ID='T:';Total=2000;Free=1000;Used=1000;Percent=50}
    $newRow=[pscustomobject]@{Timestamp='2026-01-01';ID='T:';Total=2000;Free=1990;Used=10;Percent=0.5;VolumeGuid=$guidB}
    Write-DiskPulseAtomicCsv $csv @($oldRow,$newRow)
    $read=@(Import-Csv -LiteralPath $csv)
    Assert-Identity ($read.Count -eq 2 -and $read[0].VolumeGuid -eq '' -and $read[1].VolumeGuid -eq $guidB.ToUpperInvariant()) 'CSV identity must survive a legacy-first schema.'
    Assert-Identity (@(Get-DiskPulseCapacityHistory $read 'T:' $guidB).Count -eq 1) 'Capacity lookup must exclude legacy and foreign rows.'
    Assert-Identity (@(Get-DiskPulseCapacityHistory $read 'T:' '').Count -eq 0) 'Unknown capacity identity must not use history.'
} finally { Remove-Item -LiteralPath $temp -Recurse -Force }
Write-Host 'PASS: same-volume continuity, return, legacy/unknown, history/trend, AI and mixed CSV fixtures.'

# Exercise the generated entry pipeline with fake disk enumeration and scan results only.
# Persistence, first-baseline classification, CSV reload, comparisons, history, AI input and
# report serialization run unchanged in an isolated data directory. No real disk is scanned.
$env:DISKPULSE_TEST_MODE='1'; $env:DISKPULSE_ROOT=$root; $env:DISKPULSE_NO_OPEN='1'; $env:DISKPULSE_SILENT='1'
$env:DISKPULSE_SCRIPT_PATH=Join-Path $root 'check.bat'
$env:DISKPULSE_DATA_ROOT=Join-Path $env:TEMP ('DiskPulse-IdentityPipeline-'+[guid]::NewGuid().ToString('N'))
$generated=Get-Content -Raw -LiteralPath $env:DISKPULSE_SCRIPT_PATH -Encoding UTF8
Invoke-Expression $generated.Substring($generated.IndexOf('#>')+2)
function Get-CimInstance { [pscustomobject]@{DriveType=3;DeviceID='T:';Size=[int64](2000GB);FreeSpace=[int64]((2000-$script:fixtureUsed)*1GB);VolumeSerialNumber='SAME'} }
function Get-DiskPulseDriveVolumeGuid { param($Drive) return $script:fixtureGuid }
function Get-DiskPulseDosDeviceTarget { param($Drive) return '\Device\HarddiskVolume99' }
function Invoke-DirectoryScan {
    param($Drive,$RootPath,$ProgressCallback,$VolumeGuid)
    $scan=Identity-Drive (ConvertTo-DiskPulseVolumeGuid $VolumeGuid) ([int64]($script:fixtureUsed*1GB))
    foreach($field in @('totalBytes','freeBytes','usedBytes')) { $scan.PSObject.Properties.Remove($field) }
    return $scan
}
function Read-IdentityReport($Name) {
    $html=Get-Content -Raw -LiteralPath (Join-Path $env:DISKPULSE_DATA_ROOT 'runtime/DiskPulse.html') -Encoding UTF8
    $match=[regex]::Match($html, ('const RAW_'+$Name+' = (?<json>[^\r\n]+);'))
    if(-not $match.Success){throw "Missing report field $Name"}
    return ConvertFrom-Json $match.Groups['json'].Value
}
try {
    $script:fixtureGuid=$guidA; $script:fixtureUsed=1000; Invoke-DiskPulse
    $aId=(Read-IdentityReport 'SCAN_META').scanId
    $script:fixtureGuid=$guidB; $script:fixtureUsed=10; Invoke-DiskPulse
    $bId=(Read-IdentityReport 'SCAN_META').scanId
    $data=@(Read-IdentityReport 'DATA'); $directory=@(Read-IdentityReport 'DIRECTORY')
    Assert-Identity ($directory[0].status -eq 'baseline' -and -not $directory[0].baselineScanId -and $null -eq $data[0].diff) 'Actual pipeline must start B baseline without cross-volume capacity delta.'
    $script:fixtureUsed=20; Invoke-DiskPulse
    $data=@(Read-IdentityReport 'DATA'); $directory=@(Read-IdentityReport 'DIRECTORY')
    Assert-Identity ($directory[0].baselineScanId -eq $bId -and $data[0].diff -eq 10) 'Actual B second scan must compare to B first scan.'
    $script:fixtureGuid=$guidA; $script:fixtureUsed=1005; Invoke-DiskPulse
    $data=@(Read-IdentityReport 'DATA'); $directory=@(Read-IdentityReport 'DIRECTORY')
    Assert-Identity ($directory[0].baselineScanId -eq $aId -and $data[0].diff -eq 5) 'Actual returning A must compare to A, not B.'
    $history=@(Read-IdentityReport 'HISTORY_CENTER')
    Assert-Identity (@($history[0].comparisons).Count -eq 1) 'Report custom/history choices must exclude the other volume.'
    $script:fixtureGuid=''; $script:fixtureUsed=40; Invoke-DiskPulse
    $data=@(Read-IdentityReport 'DATA'); $directory=@(Read-IdentityReport 'DIRECTORY')
    Assert-Identity (-not $directory[0].baselineScanId -and $null -eq $data[0].diff) 'Query failure must remain unknown through actual pipeline.'
    $persisted=@(Import-Csv (Join-Path $env:DISKPULSE_DATA_ROOT 'runtime/DiskPulse.csv'))
    Assert-Identity ($persisted.Count -eq 5 -and @($persisted|Where-Object VolumeGuid -eq $guidA.ToUpperInvariant()).Count -eq 2) 'CSV reload/publication must preserve both volume histories and unknown sample.'
    Write-Host 'PASS: generated Invoke-DiskPulse A -> B -> B2 -> A2 -> unknown, isolated persistence/report/AI pipeline.'
} finally { Remove-Item -LiteralPath $env:DISKPULSE_DATA_ROOT -Recurse -Force }
