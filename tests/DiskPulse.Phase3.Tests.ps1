$ErrorActionPreference='Stop'; Set-StrictMode -Version Latest
$root=Split-Path -Parent $PSScriptRoot; $source=Get-Content -Raw -LiteralPath (Join-Path $root 'check.bat') -Encoding UTF8
$env:DISKPULSE_TEST_MODE='1';$env:DISKPULSE_ROOT=$root;$env:DISKPULSE_SCRIPT_PATH=Join-Path $root 'check.bat'
Invoke-Expression $source.Substring($source.IndexOf('#>')+2)
foreach($name in 'Compare-DriveRecords','Find-DriveBaseline','Get-ChangeCoverage','Complete-InterruptedScans','Remove-StaleTemporaryFiles','Invoke-SnapshotRetention'){
    if(-not(Get-Command $name -ErrorAction SilentlyContinue)){throw "Missing Phase 3 helper: $name"}
}
function Rec($key,$size,$level=1,$complete=$true){[pscustomobject]@{key=$key;displayPath=$key;kind='directory';level=$level;sizeBytes=[int64]$size;enumerationComplete=$complete;childrenEnumerationComplete=$complete}}
$baseline=[pscustomobject]@{drive='T:';status='complete';usedBytes=1000;records=@((Rec 'same' 10),(Rec 'changed' 20),(Rec 'removed' 30),(Rec 'blocked' 40),(Rec 'excluded' 50))}
$current=[pscustomobject]@{drive='T:';status='partial';usedBytes=1015;records=@((Rec 'same' 10),(Rec 'changed' 25),(Rec 'created' 10));unavailable=@([pscustomobject]@{path='blocked'});excluded=@([pscustomobject]@{path='excluded'})}
$rows=@(Compare-DriveRecords $current $baseline);$counts=@{};$rows|Group-Object state|ForEach-Object{$counts[$_.Name]=$_.Count}
foreach($state in 'created','changed','unavailable','unchanged'){if($counts[$state]-ne 1){throw "Expected one $state state."}}
if($counts['unknown']-ne 2){throw 'Partial comparison must keep unconfirmed missing paths unknown.'}
$complete=[pscustomobject]@{drive='T:';status='complete';usedBytes=1015;records=$current.records;unavailable=@();excluded=@()}
if(@(Compare-DriveRecords $complete $baseline|Where-Object state -eq 'removed').Count-ne 3){throw 'Complete comparison must emit removed records.'}
$now=[pscustomobject]@{scanId='now';startedAt='2026-07-13T12:00:00Z'}
$emptyBaseline=Find-DriveBaseline -Snapshots @() -Drive 'T:' -Current $now
if($null-ne$emptyBaseline){throw 'First run with no snapshots must return no baseline.'}
$snaps=@([pscustomobject]@{scanId='future';completedAt='2026-07-13T13:00:00Z';drives=@($baseline)},[pscustomobject]@{scanId='partial';completedAt='2026-07-13T11:00:00Z';drives=@([pscustomobject]@{drive='T:';status='partial'})},[pscustomobject]@{scanId='base';completedAt='2026-07-13T10:00:00Z';drives=@($baseline)})
if((Find-DriveBaseline $snaps 'T:' $now).scanId-ne'base'){throw 'Baseline selection is incorrect.'}
$coverage=Get-ChangeCoverage $complete $baseline (Compare-DriveRecords $complete $baseline)
if($coverage.rate-lt 0-or $coverage.rate-gt 100){throw 'Coverage rate must be clamped.'}
$temp=Join-Path ([IO.Path]::GetTempPath()) ('DiskPulse-Phase3-'+[guid]::NewGuid().ToString('N'));[IO.Directory]::CreateDirectory($temp)|Out-Null
$paths=[pscustomobject]@{Snapshots=Join-Path $temp 'snapshots';Events=Join-Path $temp 'scans.jsonl'};[IO.Directory]::CreateDirectory($paths.Snapshots)|Out-Null
try{
    '{"scanId":"orphan","status":"running"}'|Set-Content -LiteralPath $paths.Events -Encoding UTF8;Complete-InterruptedScans $paths
    $eventLines=@(Get-Content $paths.Events -Encoding UTF8|ForEach-Object{$_|ConvertFrom-Json});if($eventLines[-1].reason-ne'interrupted'){throw 'Orphaned running scan must be finalized as interrupted.'}
    $failedSnapshot=[pscustomobject]@{scanId='failed-snapshot';startedAt='2026-07-13T07:00:00Z';completedAt='2026-07-13T07:01:00Z';drives=@($baseline)}
    [IO.File]::WriteAllText((Join-Path $paths.Snapshots 'failed-snapshot.json'),($failedSnapshot|ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))
    Write-ScanEvent $paths ([pscustomobject]@{scanId='failed-snapshot';status='failed';reason='test'})
    if(@(Read-Snapshots $paths).Count-ne 0){throw 'A snapshot whose final event failed must not become a baseline candidate.'}
    $oldTmp=Join-Path $paths.Snapshots 'old.tmp';'x'|Set-Content $oldTmp;[IO.File]::SetLastWriteTime($oldTmp,(Get-Date).AddHours(-25));Remove-StaleTemporaryFiles $paths;if(Test-Path $oldTmp){throw 'Stale temporary snapshot must be removed.'}
    $retention=@(
        [pscustomobject]@{scanId='oldpartial';completedAt='2026-07-13T08:00:00Z';drives=@([pscustomobject]@{drive='T:';status='partial'})},
        [pscustomobject]@{scanId='oldcomplete';completedAt='2026-07-13T09:00:00Z';drives=@([pscustomobject]@{drive='T:';status='complete'})},
        [pscustomobject]@{scanId='newcomplete';completedAt='2026-07-13T10:00:00Z';drives=@([pscustomobject]@{drive='T:';status='complete'})},
        [pscustomobject]@{scanId='current';completedAt='2026-07-13T11:00:00Z';drives=@([pscustomobject]@{drive='T:';status='complete'})}
    )
    foreach($s in $retention){[IO.File]::WriteAllText((Join-Path $paths.Snapshots ($s.scanId+'.json')),($s|ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))}
    Invoke-SnapshotRetention $paths $retention @('T:') 'current' 3
    if(Test-Path (Join-Path $paths.Snapshots 'oldpartial.json')){throw 'Old unprotected partial snapshot must be removed first.'}
    if(-not(Test-Path (Join-Path $paths.Snapshots 'oldcomplete.json'))){throw 'Complete snapshot must remain while partial cleanup satisfies the limit.'}
}finally{
    foreach($name in 'oldpartial.json','oldcomplete.json','newcomplete.json','current.json','failed-snapshot.json','old.tmp'){ $p=Join-Path $paths.Snapshots $name;if(Test-Path $p){Remove-Item -LiteralPath $p -Force}}
    if(Test-Path $paths.Events){Remove-Item -LiteralPath $paths.Events -Force};[IO.Directory]::Delete($paths.Snapshots);[IO.Directory]::Delete($temp)
}
if($source-notmatch 'exit /b %ERRORLEVEL%'){throw 'BAT must return the PowerShell exit code.'}
Write-Host ($counts|ConvertTo-Json -Compress);Write-Host 'PASS: Phase 3 comparison states, baseline selection, and coverage.'
