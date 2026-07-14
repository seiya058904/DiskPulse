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

# === AI Configuration & Security Tests ===
foreach($name in 'Get-DiskPulseAIConfig','Protect-DiskPulseSecret','Unprotect-DiskPulseSecret','Test-DiskPulseAIEndpoint','Invoke-DiskPulseAIConfigure','ConvertTo-DiskPulseSafeJSON'){
    if(-not(Get-Command $name -ErrorAction SilentlyContinue)){throw "Missing AI function: $name"}
}
$aiCfgNull = Get-DiskPulseAIConfig
if($null-ne$aiCfgNull){throw 'AI config must be null when no config file exists.'}

$testSecret='test-api-key-12345'
$enc=Protect-DiskPulseSecret $testSecret
if([string]::IsNullOrWhiteSpace($enc)){throw 'Protected secret must not be empty.'}
if($enc-eq$testSecret){throw 'Protected secret must not equal plaintext.'}
if($enc-match'test-api-key'){throw 'Protected secret must not contain plaintext substring.'}
$dec=Unprotect-DiskPulseSecret $enc
if($dec-ne$testSecret){throw 'Decrypted secret must match original.'}

$badDec=Unprotect-DiskPulseSecret 'not-valid-base64!!!'
if($null-ne$badDec){throw 'Invalid Base64 must return null.'}

foreach($ep in @('https://api.openai.com/v1/chat/completions','https://example.com/api','http://localhost:11434/v1','http://127.0.0.1:8080/api','http://[::1]:3000/api')){
    if(-not(Test-DiskPulseAIEndpoint $ep)){throw "Must be valid: $ep"}
}
foreach($ep in @('http://api.example.com/v1','ftp://example.com/api','https://','','not-a-url','http://localhost.evil.com:11434/','http://127.0.0.1.evil.com/','http://user@localhost.evil.com/')){
    if(Test-DiskPulseAIEndpoint $ep){throw "Must be invalid: $ep"}
}

$safeJson=ConvertTo-DiskPulseSafeJSON ([pscustomobject]@{summary='test'})
try{$null=$safeJson|ConvertFrom-Json}catch{throw 'SafeJSON must produce valid JSON.'}

$malicious='</script><script>alert(1)</script>'
$safeResult=ConvertTo-DiskPulseSafeJSON ([pscustomobject]@{text=$malicious})
if($safeResult-match'</script>'){throw 'SafeJSON must escape script-closing tags.'}
if($safeResult-match'<script>'){throw 'SafeJSON must escape script-opening tags.'}
$bs=[string][char]0x5c
if($safeResult-notmatch([regex]::Escape($bs+'u003c'))){throw 'SafeJSON must use backslash-u003c for less-than.'}
if($safeResult-notmatch([regex]::Escape($bs+'u003e'))){throw 'SafeJSON must use backslash-u003e for greater-than.'}
$parsedSafe=$safeResult|ConvertFrom-Json
if($parsedSafe.text-ne$malicious){throw 'SafeJSON must round-trip correctly.'}

$ampResult=ConvertTo-DiskPulseSafeJSON ([pscustomobject]@{text='a&b'})
if($ampResult-notmatch([regex]::Escape($bs+'u0026'))){throw 'SafeJSON must escape ampersand.'}

$unicodeObj=[pscustomobject]@{text="line$([char]0x2028)para$([char]0x2029)end"}
$safeUnicode=ConvertTo-DiskPulseSafeJSON $unicodeObj
if($safeUnicode-match[string][char]0x2028){throw 'SafeJSON must escape U+2028.'}
if($safeUnicode-match[string][char]0x2029){throw 'SafeJSON must escape U+2029.'}
$parsedUnicode=$safeUnicode|ConvertFrom-Json
if($parsedUnicode.text-ne"line$([char]0x2028)para$([char]0x2029)end"){throw 'SafeJSON unicode round-trip failed.'}

$aiTemp=Join-Path ([IO.Path]::GetTempPath()) ('DiskPulse-AI-'+[guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($aiTemp)|Out-Null
try{
    $injectedJs='const ai = '+$safeResult+';'
    $jsFile=Join-Path $aiTemp 'ai-test.js'
    [IO.File]::WriteAllText($jsFile,$injectedJs,[Text.UTF8Encoding]::new($false))
    & node --check $jsFile
    if($LASTEXITCODE-ne0){throw 'SafeJSON must produce valid JavaScript.'}
    $xssPayload='</script><script>require("child_process").exec("echo pwned")</script>'
    $safeXss=ConvertTo-DiskPulseSafeJSON ([pscustomobject]@{text=$xssPayload})
    $xssJs='const payload = '+$safeXss+';'
    $xssFile=Join-Path $aiTemp 'xss-test.js'
    [IO.File]::WriteAllText($xssFile,$xssJs,[Text.UTF8Encoding]::new($false))
    & node --check $xssFile
    if($LASTEXITCODE-ne0){throw 'SafeJSON XSS payload must produce valid JavaScript.'}
    if($xssJs-match'</script>'){throw 'SafeJSON must prevent script tag injection in JS context.'}
}
finally{
    if(Test-Path -LiteralPath $aiTemp){Remove-Item -LiteralPath $aiTemp -Recurse -Force}
}

Write-Host 'PASS: AI configuration, DPAPI, endpoint validation, safe JSON, and script injection.'

# === Phase 2: AI Input Construction Tests ===
foreach($name in 'ConvertTo-DiskPulseRedactedPath','New-DiskPulseAIInput','New-DiskPulseAIPrompt'){
    if(-not(Get-Command $name -ErrorAction SilentlyContinue)){throw "Missing Phase 2 function: $name"}
}

# --- Path redaction tests ---
$origProfile=$env:USERPROFILE
$env:USERPROFILE='C:\Users\admin'
try{
    # Exact USERPROFILE match
    $r=ConvertTo-DiskPulseRedactedPath 'C:\Users\admin'
    if($r-ne'%USERPROFILE%'){throw "Exact USERPROFILE must match, got: $r"}
    # USERPROFILE with trailing backslash
    $r=ConvertTo-DiskPulseRedactedPath 'C:\Users\admin\'
    if($r-ne'%USERPROFILE%'){throw "USERPROFILE with trailing slash must match, got: $r"}
    # Child path
    $r=ConvertTo-DiskPulseRedactedPath 'C:\Users\admin\Documents\file.txt'
    if($r-ne'%USERPROFILE%\Documents\file.txt'){throw "Child path must redact, got: $r"}
    # Case insensitive
    $r=ConvertTo-DiskPulseRedactedPath 'c:\users\admin\Documents'
    if($r-ne'%USERPROFILE%\Documents'){throw "Case insensitive must match, got: $r"}
    # Other user → %OTHER_USERPROFILE%
    $r=ConvertTo-DiskPulseRedactedPath 'C:\Users\Alice\AppData'
    if($r-ne'%OTHER_USERPROFILE%\AppData'){throw "Other user must be redacted, got: $r"}
    $r=ConvertTo-DiskPulseRedactedPath 'C:\Users\administrator\stuff'
    if($r-ne'%OTHER_USERPROFILE%\stuff'){throw "administrator must be OTHER_USERPROFILE, got: $r"}
    # Public → %PUBLICPROFILE%
    $r=ConvertTo-DiskPulseRedactedPath 'C:\Users\Public\Documents'
    if($r-ne'%PUBLICPROFILE%\Documents'){throw "Public must be PUBLICPROFILE, got: $r"}
    # Default → %DEFAULTPROFILE%
    $r=ConvertTo-DiskPulseRedactedPath 'C:\Users\Default\AppData'
    if($r-ne'%DEFAULTPROFILE%\AppData'){throw "Default must be DEFAULTPROFILE, got: $r"}
    # Non-user path unchanged
    $r=ConvertTo-DiskPulseRedactedPath 'C:\Windows\System32'
    if($r-ne'C:\Windows\System32'){throw "Non-user path must not change, got: $r"}
    # Null/empty passthrough
    if(ConvertTo-DiskPulseRedactedPath ''){throw "Empty must return empty."}
    if($null-ne(ConvertTo-DiskPulseRedactedPath $null) -and ''-ne(ConvertTo-DiskPulseRedactedPath $null)){throw "Null must return null or empty."}
}finally{$env:USERPROFILE=$origProfile}

# --- AI Input construction tests ---
$snap=[pscustomobject]@{scanId='test-scan';completedAt='2026-07-14T10:30:00Z';status='complete';drives=@([pscustomobject]@{drive='C:';status='complete';rootPath='C:\'})}
$baseline=[pscustomobject]@{scanId='base';completedAt='2026-07-13T10:00:00Z';drives=@([pscustomobject]@{drive='C:';status='complete';rootPath='C:\';usedBytes=1000;records=@(
    [pscustomobject]@{key='c- programs';displayPath='C:\Program Files';kind='directory';level=1;sizeBytes=500},
    [pscustomobject]@{key='c- users';displayPath='C:\Users';kind='directory';level=1;sizeBytes=300},
    [pscustomobject]@{key='c- windows';displayPath='C:\Windows';kind='directory';level=1;sizeBytes=200},
    [pscustomobject]@{key='c- pf-google';displayPath='C:\Program Files\Google';kind='directory';level=2;sizeBytes=400}
)})}
$current=[pscustomobject]@{drive='C:';status='complete';rootPath='C:\';usedBytes=1060;records=@(
    [pscustomobject]@{key='c- programs';displayPath='C:\Program Files';kind='directory';level=1;sizeBytes=550},
    [pscustomobject]@{key='c- users';displayPath='C:\Users';kind='directory';level=1;sizeBytes=280},
    [pscustomobject]@{key='c- windows';displayPath='C:\Windows';kind='directory';level=1;sizeBytes=200},
    [pscustomobject]@{key='c- pf-google';displayPath='C:\Program Files\Google';kind='directory';level=2;sizeBytes=430},
    [pscustomobject]@{key='c- new';displayPath='C:\NewDir';kind='directory';level=1;sizeBytes=30}
);excluded=@();unavailable=@();errors=@()}
$baselineDrive=$baseline.drives[0]
$dirResults=@([pscustomobject]@{
    drive='C:';status='complete';baselineScanId='base';baselineCompletedAt='2026-07-13T10:00:00Z'
    changes=Compare-DriveRecords $current $baselineDrive
    coverage=Get-ChangeCoverage $current $baselineDrive (Compare-DriveRecords $current $baselineDrive)
    errors=@();unavailable=@();excluded=@()
})
$hc=@([pscustomobject]@{
    drive='C:';status='complete'
    selections=[pscustomobject]@{previous='base';day=$null;week=$null;earliest=$null}
    comparisons=@();trends=@(
        [pscustomobject]@{key='c- programs';displayPath='C:\Program Files';level=1;label='持续增长';cumulativeBytes=50;samples=@();growthCount=3;releaseCount=0;occurrenceCount=3;comparisonCount=3;firstSeen='2026-07-13T10:00:00Z';lastSeen='2026-07-14T10:30:00Z'}
    )
})

$aiInput=New-DiskPulseAIInput -DirectoryResults $dirResults -HistoryCenter $hc -Snapshot $snap

# schemaVersion
if($aiInput.schemaVersion-ne1){throw 'schemaVersion must be 1.'}
# scan metadata
if($aiInput.scanStatus-ne'complete'){throw 'scanStatus must be complete.'}
if($aiInput.drives.Count-ne1){throw 'Must have 1 drive.'}
# Level-1 primary: growth=Program Files (+50), NewDir (+30), release=Users (-20)
$pg=$aiInput.primaryGrowth
$pr=$aiInput.primaryRelease
if($pg.Count-ne2){throw "Expected 2 growth items, got $($pg.Count)."}
if($pr.Count-ne1){throw "Expected 1 release item, got $($pr.Count)."}
if($pg[0].path-ne'C:\Program Files'){throw "Top growth must be Program Files, got $($pg[0].path)."}
# Level-2 breakdown: Google is child of Program Files
$bd=$aiInput.breakdown
if($bd.Count-ne1){throw "Expected 1 breakdown item, got $($bd.Count)."}
if($bd[0].parentPath-ne'C:\Program Files'){throw "Breakdown parent must be Program Files."}
if($bd[0].path-ne'C:\Program Files\Google'){throw "Breakdown path must be Google."}
# Level-1 and level-2 must not double-count: primaryGrowth deltaBytes + breakdown deltaBytes != sum
$totalPrimary=[int64]0; foreach($p in $pg){$totalPrimary+=[int64]$p.deltaBytes}
$totalBreakdown=[int64]0; foreach($b in $bd){$totalBreakdown+=[int64]$b.deltaBytes}
# Primary includes Google's parent (+50), breakdown shows Google child (+30)
# They must NOT be summed: the AI prompt explains this relationship
if($totalPrimary-ne80){throw "Total primary delta must be 80, got $totalPrimary."}
if($totalBreakdown-ne30){throw "Total breakdown delta must be 30, got $totalBreakdown."}
# Omitted: all items fit within limits, so omitted must be zero
if($aiInput.omitted.growthCount-ne0){throw 'Omitted growth count must be 0.'}
if($aiInput.omitted.releaseCount-ne0){throw 'Omitted release count must be 0.'}
# Trend info on primary
$progTrend=$pg | Where-Object { $_.path -eq 'C:\Program Files' }
if($progTrend.trendLabel-ne'持续增长'){throw "Program Files trend must be 持续增长."}

# --- Top N truncation test ---
$manyRecords=@()
$changeRecords=@()
for($i=1;$i -le 20;$i++){
    $rec=[pscustomobject]@{key="c-grow$i";displayPath="C:\Grow$((100-$i).ToString('000'))";level=1;sizeBytes=[int64]($i*10)}
    $manyRecords+=$rec
    $changeRecords+=[pscustomobject]@{key=$rec.key;displayPath=$rec.displayPath;level=1;sizeBytes=[int64]$rec.sizeBytes;deltaBytes=[int64]$rec.sizeBytes;state='created';kind='directory'}
}
$manyBaseline=[pscustomobject]@{drive='T:';status='complete';rootPath='T:\';usedBytes=0;records=@();unavailable=@();excluded=@();errors=@()}
$manyCurrent=[pscustomobject]@{drive='T:';status='complete';rootPath='T:\';usedBytes=1000;records=[array]$manyRecords;unavailable=@();excluded=@();errors=@()}
$manyDir=@([pscustomobject]@{drive='T:';status='complete';baselineScanId='base';changes=[array]$changeRecords;coverage=[pscustomobject]@{actualNetBytes=1000;locatedNetBytes=1000;addedBytes=1000;releasedBytes=0;rate=100;activityPreferred=$false};errors=@();unavailable=@();excluded=@()})
$manySnap=[pscustomobject]@{scanId='many';completedAt='2026-07-14T11:00:00Z';status='complete'}
$manyInput=New-DiskPulseAIInput -DirectoryResults $manyDir -HistoryCenter @() -Snapshot $manySnap
if($manyInput.primaryGrowth.Count-ne15){throw "Growth must be capped at 15, got $($manyInput.primaryGrowth.Count)."}
if($manyInput.omitted.growthCount-ne5){throw "Omitted growth must be 5, got $($manyInput.omitted.growthCount)."}
if($manyInput.omitted.growthBytes-le0){throw "Omitted growth bytes must be positive."}

# --- No baseline / no reliable changes / all failed ---
$emptyDir=@([pscustomobject]@{drive='C:';status='baseline';baselineScanId=$null;changes=@();coverage=$null;errors=@();unavailable=@();excluded=@()})
$emptySnap=[pscustomobject]@{scanId='empty';completedAt='2026-07-14T10:30:00Z';status='complete'}
$emptyInput=New-DiskPulseAIInput -DirectoryResults $emptyDir -HistoryCenter @() -Snapshot $emptySnap
if($emptyInput.primaryGrowth.Count-ne0){throw 'No baseline must have 0 growth.'}
if($emptyInput.primaryRelease.Count-ne0){throw 'No baseline must have 0 release.'}

$failDir=@([pscustomobject]@{drive='C:';status='failed';baselineScanId='base';changes=@();coverage=$null;errors=@([pscustomobject]@{path='C:\';reason='fail'});unavailable=@([pscustomobject]@{path='C:\';reason='fail'});excluded=@()})
$failInput=New-DiskPulseAIInput -DirectoryResults $failDir -HistoryCenter @() -Snapshot $emptySnap
if($failInput.drives[0].scanStatus-ne'failed'){throw 'Failed scan must report status.'}
if($failInput.drives[0].unavailablePathCount-ne1){throw 'Unavailable path count must be 1.'}

# --- Removed items preserved ---
$removedChange=@([pscustomobject]@{key='c-old';displayPath='C:\OldDir';level=1;sizeBytes=0;deltaBytes=-100;state='removed';kind='directory'})
$removedDir=@([pscustomobject]@{drive='C:';status='complete';baselineScanId='base';changes=$removedChange;coverage=[pscustomobject]@{actualNetBytes=-100;locatedNetBytes=-100;addedBytes=0;releasedBytes=100;rate=100;activityPreferred=$false};errors=@();unavailable=@();excluded=@()})
$removedInput=New-DiskPulseAIInput -DirectoryResults $removedDir -HistoryCenter @() -Snapshot $emptySnap
if($removedInput.primaryRelease.Count-ne1){throw 'Must have 1 release item.'}
$ri=$removedInput.primaryRelease[0]
if($ri.state-ne'removed'){throw 'Removed state must be preserved.'}
if($ri.currentSizeBytes-ne0){throw 'Removed item currentSizeBytes must be 0.'}
if($ri.deltaBytes-ne-100){throw 'Removed item deltaBytes must be -100.'}

# --- Multiple disks ---
$multiDir=@(
    [pscustomobject]@{drive='C:';status='complete';baselineScanId='base';changes=@([pscustomobject]@{key='c-grow';displayPath='C:\Grow';level=1;sizeBytes=100;deltaBytes=50;state='changed';kind='directory'});coverage=[pscustomobject]@{actualNetBytes=50;locatedNetBytes=50;addedBytes=50;releasedBytes=0;rate=100;activityPreferred=$false};errors=@();unavailable=@();excluded=@()}
    [pscustomobject]@{drive='D:';status='complete';baselineScanId='base';changes=@([pscustomobject]@{key='d-grow';displayPath='D:\Grow';level=1;sizeBytes=200;deltaBytes=80;state='changed';kind='directory'});coverage=[pscustomobject]@{actualNetBytes=80;locatedNetBytes=80;addedBytes=80;releasedBytes=0;rate=100;activityPreferred=$false};errors=@();unavailable=@();excluded=@()}
)
$multiInput=New-DiskPulseAIInput -DirectoryResults $multiDir -HistoryCenter @() -Snapshot $emptySnap
if($multiInput.drives.Count-ne2){throw 'Must have 2 drives.'}
if($multiInput.primaryGrowth.Count-ne2){throw 'Must have 2 growth items across drives.'}

# --- Sort stability (same |deltaBytes|) ---
$snapA=[pscustomobject]@{scanId='sort-test';completedAt='2026-07-14T10:30:00Z';status='complete'}
$sortChanges=@(
    [pscustomobject]@{key='c-bbb';displayPath='C:\BBB';level=1;sizeBytes=100;deltaBytes=50;state='changed';kind='directory'}
    [pscustomobject]@{key='c-aaa';displayPath='C:\AAA';level=1;sizeBytes=100;deltaBytes=50;state='changed';kind='directory'}
)
$sortDir=@([pscustomobject]@{drive='C:';status='complete';baselineScanId='base';changes=$sortChanges;coverage=[pscustomobject]@{actualNetBytes=100;locatedNetBytes=100;addedBytes=100;releasedBytes=0;rate=100;activityPreferred=$false};errors=@();unavailable=@();excluded=@()})
$sortInput=New-DiskPulseAIInput -DirectoryResults $sortDir -HistoryCenter @() -Snapshot $snapA
if($sortInput.primaryGrowth[0].path-ne'C:\AAA'){throw "Same deltaBytes must sort by path. AAA should be first, got $($sortInput.primaryGrowth[0].path)."}

# --- Prompt tests ---
$prompt=New-DiskPulseAIPrompt '{"test":1}'
if($prompt.system -notmatch 'breakdown'){throw 'Prompt must mention breakdown dedup rule.'}
if($prompt.system -notmatch 'UNTRUSTED'){throw 'Prompt must mention untrusted path names.'}
if($prompt.system -notmatch 'Do NOT claim to have read file contents'){throw 'Prompt must forbid claiming file reads.'}
if($prompt.system -notmatch 'Do NOT generate PowerShell'){throw 'Prompt must forbid generating commands.'}
if($prompt.user -notmatch '\{.*test.*\}'){throw 'User message must contain the input JSON.'}

# --- No API Key, username, or file content in results ---
$inputJson=ConvertTo-Json -InputObject $aiInput -Depth 12
if($inputJson-match'test-api-key'){throw 'AI input must not contain API key.'}
if($inputJson-match'admin[^-]'){throw 'AI input must not contain username.'}

Write-Host 'PASS: AI input construction, path redaction, Top N, omitted, sort stability, prompt constraints.'

# === Phase 2 Regression: per-disk Top N, breakdown limits, trend sort ===

# Two disks each exceeding Top N, confirm per-disk truncation
$regSnap=[pscustomobject]@{scanId='reg';completedAt='2026-07-14T10:30:00Z';status='complete'}
$regChangesC=@(); $regChangesD=@()
for($i=1;$i -le 20;$i++){
    $regChangesC+=[pscustomobject]@{key="c-g$i";displayPath="C:\G$((200-$i).ToString('000'))";kind='directory';level=1;sizeBytes=[int64]($i*10);deltaBytes=[int64]($i*10);state='created'}
    $regChangesD+=[pscustomobject]@{key="d-g$i";displayPath="D:\G$((200-$i).ToString('000'))";kind='directory';level=1;sizeBytes=[int64]($i*10);deltaBytes=[int64]($i*10);state='created'}
}
$regDirC=[pscustomobject]@{drive='C:';status='complete';baselineScanId='base';changes=[array]$regChangesC;coverage=[pscustomobject]@{actualNetBytes=2000;locatedNetBytes=2000;addedBytes=2000;releasedBytes=0;rate=100;activityPreferred=$false;unexplainedBytes=0};errors=@();unavailable=@();excluded=@()}
$regDirD=[pscustomobject]@{drive='D:';status='complete';baselineScanId='base';changes=[array]$regChangesD;coverage=[pscustomobject]@{actualNetBytes=2000;locatedNetBytes=2000;addedBytes=2000;releasedBytes=0;rate=100;activityPreferred=$false;unexplainedBytes=0};errors=@();unavailable=@();excluded=@()}
$regInput=New-DiskPulseAIInput -DirectoryResults @($regDirC,$regDirD) -HistoryCenter @() -Snapshot $regSnap
$cGrowth=@($regInput.primaryGrowth | Where-Object { $_.drive -eq 'C:' })
$dGrowth=@($regInput.primaryGrowth | Where-Object { $_.drive -eq 'D:' })
if($cGrowth.Count-ne15){throw "C: must have 15 growth items, got $($cGrowth.Count)."}
if($dGrowth.Count-ne15){throw "D: must have 15 growth items, got $($dGrowth.Count)."}
if($regInput.primaryGrowth.Count-ne30){throw "Total growth must be 30 (15+15), got $($regInput.primaryGrowth.Count)."}
if($regInput.omitted.growthCount-ne10){throw "Omitted must be 10 (5+5), got $($regInput.omitted.growthCount)."}

# One parent with >5 children, confirm only 5 breakdown
$regParent=[pscustomobject]@{key='c-big';displayPath='C:\BigParent';kind='directory';level=1;sizeBytes=1000;deltaBytes=500;state='changed'}
$regChildren=@()
for($i=1;$i -le 8;$i++){
    $regChildren+=[pscustomobject]@{key="c-big-c$i";displayPath="C:\BigParent\Child$((10-$i))";kind='directory';level=2;sizeBytes=[int64]($i*10);deltaBytes=[int64]($i*10);state='changed'}
}
$regDir2=[pscustomobject]@{drive='C:';status='complete';baselineScanId='base';changes=@($regParent)+$regChildren;coverage=[pscustomobject]@{actualNetBytes=500;locatedNetBytes=500;addedBytes=500;releasedBytes=0;rate=100;activityPreferred=$false;unexplainedBytes=0};errors=@();unavailable=@();excluded=@()}
$regInput2=New-DiskPulseAIInput -DirectoryResults @($regDir2) -HistoryCenter @() -Snapshot $regSnap
$parentBd=@($regInput2.breakdown | Where-Object { $_.parentPath -eq 'C:\BigParent' })
if($parentBd.Count-ne5){throw "Breakdown must be capped at 5, got $($parentBd.Count)."}

# Omitted parent's children must NOT appear in breakdown
$omParent=[pscustomobject]@{key='c-omp';displayPath='C:\OmittedParent';kind='directory';level=1;sizeBytes=1000;deltaBytes=5;state='changed'}
$omChild=[pscustomobject]@{key='c-omp-c1';displayPath='C:\OmittedParent\Child1';kind='directory';level=2;sizeBytes=100;deltaBytes=4;state='changed'}
$omChanges=@()
for($i=1;$i -le 20;$i++){$omChanges+=[pscustomobject]@{key="c-om$i";displayPath="C:\O$((200-$i).ToString('000'))";kind='directory';level=1;sizeBytes=[int64]($i*100);deltaBytes=[int64]($i*100);state='changed'}}
$omChanges+=$omParent; $omChanges+=$omChild
$omDir=[pscustomobject]@{drive='C:';status='complete';baselineScanId='base';changes=[array]$omChanges;coverage=[pscustomobject]@{actualNetBytes=20000;locatedNetBytes=20000;addedBytes=20000;releasedBytes=0;rate=100;activityPreferred=$false;unexplainedBytes=0};errors=@();unavailable=@();excluded=@()}
$omInput=New-DiskPulseAIInput -DirectoryResults @($omDir) -HistoryCenter @() -Snapshot $regSnap
$omFound=@($omInput.breakdown | Where-Object { $_.parentPath -eq 'C:\OmittedParent' })
if($omFound.Count-ne0){throw "Omitted parent's children must not appear in breakdown."}

# historicalTrends: max 10, stable sort with tiebreaker
$trendsHC=@([pscustomobject]@{
    drive='C:';status='complete';selections=[pscustomobject]@{};comparisons=@()
    trends=@(
        [pscustomobject]@{key='c-t1';displayPath='C:\TrendA';level=1;label='持续增长';cumulativeBytes=100;samples=@();growthCount=3;releaseCount=0;occurrenceCount=3;comparisonCount=3;firstSeen='2026-07-13T10:00:00Z';lastSeen='2026-07-14T10:30:00Z'}
        [pscustomobject]@{key='c-t2';displayPath='C:\TrendB';level=1;label='持续释放';cumulativeBytes=-100;samples=@();growthCount=0;releaseCount=3;occurrenceCount=3;comparisonCount=3;firstSeen='2026-07-13T10:00:00Z';lastSeen='2026-07-14T10:30:00Z'}
        [pscustomobject]@{key='c-t3';displayPath='C:\TrendC';level=1;label='波动较大';cumulativeBytes=100;samples=@();growthCount=2;releaseCount=2;occurrenceCount=4;comparisonCount=4;firstSeen='2026-07-13T10:00:00Z';lastSeen='2026-07-14T10:30:00Z'}
        [pscustomobject]@{key='c-t4';displayPath='C:\TrendD';level=1;label='持续增长';cumulativeBytes=50;samples=@();growthCount=2;releaseCount=0;occurrenceCount=2;comparisonCount=2;firstSeen='2026-07-13T10:00:00Z';lastSeen='2026-07-14T10:30:00Z'}
    )
})
$trendsDir=[pscustomobject]@{drive='C:';status='complete';baselineScanId=$null;changes=@();coverage=$null;errors=@();unavailable=@();excluded=@()}
$trendsInput=New-DiskPulseAIInput -DirectoryResults @($trendsDir) -HistoryCenter $trendsHC -Snapshot $regSnap
$ht=$trendsInput.historicalTrends
if($ht.Count-ne4){throw "historicalTrends must have 4 items, got $($ht.Count)."}
# Sort: abs(100) first (two items), then abs(50). Among abs(100), C:\TrendA < C:\TrendC by path.
if($ht[0].path-ne'C:\TrendA'){throw "Trend sort: abs(100) C:\TrendA must be first, got $($ht[0].path)."}
if($ht[1].path-ne'C:\TrendB'){throw "Trend sort: abs(100) C:\TrendB must be second, got $($ht[1].path)."}
if($ht[2].path-ne'C:\TrendC'){throw "Trend sort: abs(100) C:\TrendC must be third, got $($ht[2].path)."}
if($ht[3].path-ne'C:\TrendD'){throw "Trend sort: abs(50) C:\TrendD must be fourth, got $($ht[3].path)."}

# historicalTrends cap at 12 items, confirm only 10 returned
$manyTrends=@()
for($i=1;$i -le 12;$i++){$manyTrends+=[pscustomobject]@{key="c-mt$i";displayPath="C:\MT$(($i).ToString('00'))";level=1;label='持续增长';cumulativeBytes=[int64]($i*10);samples=@();growthCount=1;releaseCount=0;occurrenceCount=1;comparisonCount=1;firstSeen='2026-07-13T10:00:00Z';lastSeen='2026-07-14T10:30:00Z'}}
$manyTrendHC=@([pscustomobject]@{drive='C:';status='complete';selections=[pscustomobject]@{};comparisons=@();trends=[array]$manyTrends})
$manyTrendInput=New-DiskPulseAIInput -DirectoryResults @($trendsDir) -HistoryCenter $manyTrendHC -Snapshot $regSnap
if($manyTrendInput.historicalTrends.Count-ne10){throw "historicalTrends must cap at 10, got $($manyTrendInput.historicalTrends.Count)."}

Write-Host 'PASS: Phase 2 regression — per-disk Top N, breakdown limits, omitted parent, trend sort.'

# === Phase 3: API Request, Response, Status, Result Tests ===
foreach($name in 'Invoke-DiskPulseAIRequest','ConvertFrom-DiskPulseAIResponse','New-DiskPulseAIStatus','Write-DiskPulseAIResult'){
    if(-not(Get-Command $name -ErrorAction SilentlyContinue)){throw "Missing Phase 3 function: $name"}
}

$script:tUri=$null; $script:tHeaders=$null; $script:tBody=$null
$remoteCfg=[pscustomobject]@{enabled=$true;endpoint='https://api.example.com/v1/chat/completions';model='test-model';protectedApiKey=(Protect-DiskPulseSecret 'test-api-key-12345');timeoutSeconds=10}
$localCfg=[pscustomobject]@{enabled=$true;endpoint='http://localhost:11434/v1/chat/completions';model='local-model';protectedApiKey='';timeoutSeconds=10}
$tp=[PSCustomObject]@{system='System prompt';user='User msg'}

# Test: Request body valid UTF-8 JSON with correct model/messages
$req=Invoke-DiskPulseAIRequest -Config $remoteCfg -Prompt $tp -Transport { param($u,$h,$b,$t) $script:tHeaders=$h; $script:tBody=$b; $m=[pscustomobject]@{content='ok'}; $c=[pscustomobject]@{message=$m}; return [pscustomobject]@{choices=@($c)} }
if(-not $req.ok){throw 'Request must succeed.'}
$bObj=[Text.Encoding]::UTF8.GetString($script:tBody) | ConvertFrom-Json
if($bObj.model-ne'test-model'){throw 'Model mismatch.'}
if($bObj.messages.Count-ne2){throw 'Must have 2 messages.'}
if($bObj.messages[0].role-ne'system'){throw 'First msg must be system.'}
if($bObj.messages[1].role-ne'user'){throw 'Second msg must be user.'}
if($bObj.temperature-ne0.2){throw 'Temperature must be 0.2.'}

# Test: Remote includes Bearer header
if($script:tHeaders['Authorization']-ne'Bearer test-api-key-12345'){throw 'Remote must include Bearer.'}

# Test: Local no-key omits Authorization
Invoke-DiskPulseAIRequest -Config $localCfg -Prompt $tp -Transport { param($u,$h,$b,$t) $script:tHeaders=$h; $m=[pscustomobject]@{content='ok'}; $c=[pscustomobject]@{message=$m}; return [pscustomobject]@{choices=@($c)} }
if($script:tHeaders.ContainsKey('Authorization')){throw 'Local must not include Authorization.'}

# Test: Structured JSON response
$tStruct={ param($u,$h,$b,$t) $msg=[pscustomobject]@{content='{ "summary":"S", "possibleCauses":["C"], "confidence":"high", "evidence":["E"], "recommendations":["R"], "cautions":["X"] }'}; $ch=[pscustomobject]@{message=$msg}; return [pscustomobject]@{choices=@($ch)} }
$parsed=ConvertFrom-DiskPulseAIResponse (Invoke-DiskPulseAIRequest -Config $remoteCfg -Prompt $tp -Transport $tStruct)
if($parsed.status-ne'success'){throw 'Structured status must be success.'}
if($parsed.format-ne'structured'){throw 'Format must be structured.'}
if($parsed.analysis.summary-ne'S'){throw 'Summary must be S.'}
if($parsed.analysis.possibleCauses[0]-ne'C'){throw 'possibleCauses must contain C.'}
if($parsed.analysis.confidence-ne'high'){throw 'confidence must be high.'}

# Test: Fenced JSON (backtick-fence)
$bt=[string][char]0x60*3
$fenceContent=$bt+"json`n"+'{ "summary":"F", "possibleCauses":[], "confidence":"low", "evidence":[], "recommendations":[], "cautions":[] }'+"`n"+$bt
$tFenced={ param($u,$h,$b,$t) $msg=[pscustomobject]@{content=$fenceContent}; $ch=[pscustomobject]@{message=$msg}; return [pscustomobject]@{choices=@($ch)} }
$fenced=ConvertFrom-DiskPulseAIResponse (Invoke-DiskPulseAIRequest -Config $remoteCfg -Prompt $tp -Transport $tFenced)
if($fenced.status-ne'success'){throw 'Fenced must succeed.'}
if($fenced.format-ne'structured'){throw 'Fenced format must be structured.'}

# Test: Plain text fallback
$tPlain={ param($u,$h,$b,$t) $msg=[pscustomobject]@{content='Just text.'}; $ch=[pscustomobject]@{message=$msg}; return [pscustomobject]@{choices=@($ch)} }
$plain=ConvertFrom-DiskPulseAIResponse (Invoke-DiskPulseAIRequest -Config $remoteCfg -Prompt $tp -Transport $tPlain)
if($plain.status-ne'success'){throw 'Plain text must succeed.'}
if($plain.format-ne'text'){throw 'Format must be text.'}
if($plain.rawText-ne'Just text.'){throw 'rawText must match.'}

# Test: Empty content
$tEmpty={ param($u,$h,$b,$t) $msg=[pscustomobject]@{content=''}; $ch=[pscustomobject]@{message=$msg}; return [pscustomobject]@{choices=@($ch)} }
$empty=ConvertFrom-DiskPulseAIResponse (Invoke-DiskPulseAIRequest -Config $remoteCfg -Prompt $tp -Transport $tEmpty)
if($empty.status-ne'invalid-response'){throw 'Empty content must be invalid-response.'}

# Test: Missing choices
$tNoCh={ param($u,$h,$b,$t) return [pscustomobject]@{notchoices=@($null)} }
$noCh=ConvertFrom-DiskPulseAIResponse (Invoke-DiskPulseAIRequest -Config $remoteCfg -Prompt $tp -Transport $tNoCh)
if($noCh.status-ne'invalid-response'){throw 'Missing choices must be invalid-response.'}

# Test: Missing message
$tNoMsg={ param($u,$h,$b,$t) $ch=[pscustomobject]@{nomessage='x'}; return [pscustomobject]@{choices=@($ch)} }
$noMsg=ConvertFrom-DiskPulseAIResponse (Invoke-DiskPulseAIRequest -Config $remoteCfg -Prompt $tp -Transport $tNoMsg)
if($noMsg.status-ne'invalid-response'){throw 'Missing message must be invalid-response.'}

# Test: Non-string fields normalized
$tNonStr={ param($u,$h,$b,$t) $msg=[pscustomobject]@{content='{ "summary":123, "possibleCauses":"single", "confidence":true, "evidence":null, "recommendations":42, "cautions":false }'}; $ch=[pscustomobject]@{message=$msg}; return [pscustomobject]@{choices=@($ch)} }
$ns=ConvertFrom-DiskPulseAIResponse (Invoke-DiskPulseAIRequest -Config $remoteCfg -Prompt $tp -Transport $tNonStr)
if($ns.analysis.summary-ne'123'){throw 'Non-string summary must be stringified.'}
if($ns.analysis.confidence-ne'true'){throw 'Non-string confidence must be stringified.'}
if($ns.analysis.possibleCauses.Count-ne0){throw 'Non-array possibleCauses must become empty.'}
if($ns.analysis.evidence.Count-ne0){throw 'Null evidence must become empty.'}

# Test: Truncation — summary 4000, lists 10 items, item 1000 chars
$causeArr=@(); for($i=0;$i-lt 15;$i++){$causeArr+=('item'+$i)}
$causeJson=($causeArr | ForEach-Object { '"' + $_ + '"' }) -join ','
$longEv='B'*2000
$tTrunc={ param($u,$h,$b,$t) $jsonStr=('{ "summary":"' + ('A'*5000) + '", "possibleCauses":[' + $causeJson + '], "confidence":"low", "evidence":["' + $longEv + '"], "recommendations":[], "cautions":[] }'); $msg=[pscustomobject]@{content=$jsonStr}; $ch=[pscustomobject]@{message=$msg}; return [pscustomobject]@{choices=@($ch)} }
$tr=ConvertFrom-DiskPulseAIResponse (Invoke-DiskPulseAIRequest -Config $remoteCfg -Prompt $tp -Transport $tTrunc)
if($tr.analysis.summary.Length-gt4000){throw 'Summary capped at 4000.'}
if($tr.analysis.possibleCauses.Count-gt10){throw 'List capped at 10.'}
if($tr.analysis.evidence[0].Length-gt1000){throw 'Item capped at 1000.'}

# Test: Raw text truncation
$longPlain='X'*20000
$tRaw={ param($u,$h,$b,$t) $msg=[pscustomobject]@{content=$longPlain}; $ch=[pscustomobject]@{message=$msg}; return [pscustomobject]@{choices=@($ch)} }
$rt=ConvertFrom-DiskPulseAIResponse (Invoke-DiskPulseAIRequest -Config $remoteCfg -Prompt $tp -Transport $tRaw)
if($rt.rawText.Length-gt16000){throw 'RawText capped at 16000.'}

# Test: Error classification
$e401=Invoke-DiskPulseAIRequest -Config $remoteCfg -Prompt $tp -Transport { param($u,$h,$b,$t) throw (New-Object System.Net.WebException('401')) }
if($e401.error-ne'authentication-failed'){throw '401 must map to authentication-failed.'}
$e429=Invoke-DiskPulseAIRequest -Config $remoteCfg -Prompt $tp -Transport { param($u,$h,$b,$t) throw (New-Object System.Net.WebException('429')) }
if($e429.error-ne'rate-limited'){throw '429 must map to rate-limited.'}
$eTO=Invoke-DiskPulseAIRequest -Config $remoteCfg -Prompt $tp -Transport { param($u,$h,$b,$t) throw (New-Object System.Net.WebException('The operation has timed out')) }
if($eTO.error-ne'timeout'){throw 'Timeout must map to timeout.'}
$eDNS=Invoke-DiskPulseAIRequest -Config $remoteCfg -Prompt $tp -Transport { param($u,$h,$b,$t) throw (New-Object System.Net.WebException('The remote name could not be resolved')) }
if($eDNS.error-ne'connection-failed'){throw 'DNS must map to connection-failed.'}
$eUnk=Invoke-DiskPulseAIRequest -Config $remoteCfg -Prompt $tp -Transport { param($u,$h,$b,$t) throw (New-Object System.Net.WebException('random error')) }
if($eUnk.error-ne'unknown-error'){throw 'Unknown must map to unknown-error.'}

# Test: Error must not leak API key
$eKey=Invoke-DiskPulseAIRequest -Config $remoteCfg -Prompt $tp -Transport { param($u,$h,$b,$t) throw (New-Object System.Net.WebException('Error with key abc123secret')) }
$eKeyStr=ConvertTo-Json -InputObject $eKey -Compress
if($eKeyStr-match'abc123secret'){throw 'Error must not contain API key.'}

# Test: Write-DiskPulseAIResult round-trip
$rDir=Join-Path ([IO.Path]::GetTempPath()) ('DiskPulse-P3-'+[guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($rDir)|Out-Null
try{
    $rp=Join-Path $rDir 'last-ai-analysis.json'
    $aObj=[PSCustomObject]@{summary='Test summary';possibleCauses=@('c1');confidence='medium';evidence=@('e1');recommendations=@('r1');cautions=@('x1')}
    Write-DiskPulseAIResult -ScanId 'scan-123' -Status 'success' -Model 'test-model' -Format 'structured' -Analysis $aObj -RawText $null -OutputPath $rp
    if(-not(Test-Path -LiteralPath $rp)){throw 'Result file must exist.'}
    $sv=Get-Content -Raw -LiteralPath $rp -Encoding UTF8 | ConvertFrom-Json
    if($sv.scanId-ne'scan-123'){throw 'scanId round-trip failed.'}
    if($sv.status-ne'success'){throw 'status round-trip failed.'}
    if($sv.model-ne'test-model'){throw 'model round-trip failed.'}
    if($sv.analysis.summary-ne'Test summary'){throw 'analysis round-trip failed.'}
    if($sv.PSObject.Properties.Name -contains 'endpoint'){throw 'Result must not contain endpoint.'}
    if($sv.PSObject.Properties.Name -contains 'protectedApiKey'){throw 'Result must not contain protectedApiKey.'}
    $rp2=Join-Path $rDir 'raw.json'
    Write-DiskPulseAIResult -ScanId 's2' -Status 'success' -Model 'm' -Format 'text' -Analysis $null -RawText 'Plain text.' -OutputPath $rp2
    $sv2=Get-Content -Raw -LiteralPath $rp2 -Encoding UTF8 | ConvertFrom-Json
    if($sv2.rawText-ne'Plain text.'){throw 'rawText round-trip failed.'}
    if($sv2.analysis){throw 'Analysis must be null for text.'}
}
finally{ if(Test-Path -LiteralPath $rDir){Remove-Item -LiteralPath $rDir -Recurse -Force} }

# Test: New-DiskPulseAIStatus structure
$ns2=New-DiskPulseAIStatus -ScanId 's1' -Status 'success' -Model 'm1' -Analysis ([pscustomobject]@{summary='s'}) -RawText $null -Format 'structured'
if($ns2.scanId-ne's1'){throw 'Status scanId mismatch.'}
if($ns2.status-ne'success'){throw 'Status status mismatch.'}
if($ns2.generatedAt-notmatch'^\d{4}-'){throw 'Status generatedAt must be ISO date.'}

Write-Host 'PASS: Phase 3 API request, response parsing, error classification, result I/O.'

# === Phase 3 Fixes: Unicode, 403, Auth Rule, TLS ===

# Unicode-safe truncation
if(-not(Get-Command Limit-DiskPulseAIText -ErrorAction SilentlyContinue)){throw 'Missing Limit-DiskPulseAIText.'}
$emoji='aaa' + [char]0xD83D + [char]0xDE00 + 'bbb'
# Cut at boundary before emoji (high surrogate at position 3)
$r1=Limit-DiskPulseAIText $emoji 3
if($r1.Length-ne3){throw "Unicode cut before emoji: length must be 3, got $($r1.Length)."}
# Cut at boundary after emoji (position 5 = after low surrogate)
$r2=Limit-DiskPulseAIText $emoji 5
if($r2.Length-ne5){throw "Unicode cut after emoji: length must be 5, got $($r2.Length)."}
# Cut at high surrogate boundary (position 4 = high surrogate only) must pull back
$r3=Limit-DiskPulseAIText $emoji 4
if($r3.Length-ne3){throw "Unicode cut at high surrogate must pull back to 3, got $($r3.Length)."}
# Round-trip through JSON
$jsonSafe=ConvertTo-DiskPulseSafeJSON ([pscustomobject]@{t=$r2})
try{$null=$jsonSafe|ConvertFrom-Json}catch{throw 'Unicode-truncated text must be valid JSON.'}
# In JS context
$emojiJs='const x = ' + $jsonSafe + ';'
$emojiTmp=Join-Path ([IO.Path]::GetTempPath()) ('dp-emoji-'+[guid]::NewGuid().ToString('N')+'.js')
[IO.File]::WriteAllText($emojiTmp,$emojiJs,[Text.UTF8Encoding]::new($false))
try{
    & node --check $emojiTmp
    if($LASTEXITCODE-ne0){throw 'Unicode-truncated text must pass node --check.'}
}finally{Remove-Item -LiteralPath $emojiTmp -Force}

# 403 test
$e403=Invoke-DiskPulseAIRequest -Config $remoteCfg -Prompt $tp -Transport { param($u,$h,$b,$t) throw (New-Object System.Net.WebException('403 Forbidden')) }
if($e403.error-ne'authentication-failed'){throw '403 must map to authentication-failed.'}
$e403str=ConvertTo-Json -InputObject $e403 -Compress
if($e403str-match'test-api-key'){throw '403 result must not contain API key.'}

# Local endpoint: no key → no Authorization
$localNoKeyCfg=[pscustomobject]@{enabled=$true;endpoint='http://localhost:11434/v1';model='m';protectedApiKey='';timeoutSeconds=10}
Invoke-DiskPulseAIRequest -Config $localNoKeyCfg -Prompt $tp -Transport { param($u,$h,$b,$t) $script:tHeaders=$h; $m=[pscustomobject]@{content='ok'}; $c=[pscustomobject]@{message=$m}; return [pscustomobject]@{choices=@($c)} }
if($script:tHeaders.ContainsKey('Authorization')){throw 'Local + no key must not include Authorization.'}

# Local endpoint: valid key → includes Authorization
$localKeyCfg=[pscustomobject]@{enabled=$true;endpoint='http://127.0.0.1:8080/v1';model='m';protectedApiKey=(Protect-DiskPulseSecret 'local-key-123');timeoutSeconds=10}
Invoke-DiskPulseAIRequest -Config $localKeyCfg -Prompt $tp -Transport { param($u,$h,$b,$t) $script:tHeaders=$h; $m=[pscustomobject]@{content='ok'}; $c=[pscustomobject]@{message=$m}; return [pscustomobject]@{choices=@($c)} }
if($script:tHeaders['Authorization']-ne'Bearer local-key-123'){throw 'Local + valid key must include Authorization.'}

# TLS restoration
$protoBefore=[Net.ServicePointManager]::SecurityProtocol
$null=Invoke-DiskPulseAIRequest -Config $remoteCfg -Prompt $tp -Transport { param($u,$h,$b,$t) throw (New-Object System.Net.WebException('fail')) }
$protoAfter=[Net.ServicePointManager]::SecurityProtocol
if($protoBefore-ne$protoAfter){throw "TLS SecurityProtocol must be restored. Before=$protoBefore After=$protoAfter."}

Write-Host 'PASS: Phase 3 fixes — Unicode truncation, 403, local auth, TLS restoration.'

# === Phase 4 Backend: Orchestration Tests ===
if(-not(Get-Command Invoke-DiskPulseAIAnalysis -ErrorAction SilentlyContinue)){throw 'Missing Invoke-DiskPulseAIAnalysis.'}

# --- Shared test data ---
$orcDir=@([pscustomobject]@{drive='C:';status='complete';baselineScanId='base';changes=@([pscustomobject]@{key='c-g';displayPath='C:\Grow';kind='directory';level=1;sizeBytes=100;deltaBytes=50;state='changed'});coverage=[pscustomobject]@{actualNetBytes=50;locatedNetBytes=50;addedBytes=50;releasedBytes=0;rate=100;activityPreferred=$false;unexplainedBytes=0};errors=@();unavailable=@();excluded=@()})
$orcSnap=[pscustomobject]@{scanId='orc-test';completedAt='2026-07-14T10:30:00Z';status='complete'}
$orcDirNoBaseline=@([pscustomobject]@{drive='C:';status='baseline';baselineScanId=$null;changes=@();coverage=$null;errors=@();unavailable=@();excluded=@()})
$orcDirNoChange=@([pscustomobject]@{drive='C:';status='complete';baselineScanId='base';changes=@([pscustomobject]@{key='c-u';displayPath='C:\Unchanged';kind='directory';level=1;sizeBytes=100;deltaBytes=0;state='unchanged'});coverage=[pscustomobject]@{actualNetBytes=0;locatedNetBytes=0;addedBytes=0;releasedBytes=0;rate=100;activityPreferred=$false;unexplainedBytes=0};errors=@();unavailable=@();excluded=@()})
$orcDirAllFailed=@([pscustomobject]@{drive='C:';status='failed';baselineScanId='base';changes=@();coverage=$null;errors=@([pscustomobject]@{path='C:\';reason='fail'});unavailable=@();excluded=@()})

$validKey=Protect-DiskPulseSecret 'test-key-12345'
$validCfgObj=@{schemaVersion=1;enabled=$true;endpoint='https://api.example.com/v1/chat/completions';model='test-model';protectedApiKey=$validKey;timeoutSeconds=10}

# --- Snapshot original config for post-test integrity check ---
$origRuntimeRoot=Join-Path $root 'runtime'
$origCfgFile=Join-Path $origRuntimeRoot 'ai-config.local.json'
$origCfgExists=Test-Path -LiteralPath $origCfgFile
$origCfgHash=$null
if($origCfgExists){$origCfgHash=(Get-FileHash -LiteralPath $origCfgFile -Algorithm SHA256).Hash}

# --- Create isolated temp root for all test subdirectories ---
$orcTempRoot=Join-Path ([IO.Path]::GetTempPath()) ('orc-'+[guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($orcTempRoot)|Out-Null

try{
    # Helper: create test subdirectory, optionally write config, return path bundle
    function New-TD([string]$name,$cfgObj){
        $d=Join-Path $orcTempRoot $name
        [IO.Directory]::CreateDirectory($d)|Out-Null
        $cp=Join-Path $d 'config.json'
        if($null-ne$cfgObj){$cfgObj|ConvertTo-Json|Set-Content -LiteralPath $cp -Encoding UTF8}
        return @{dir=$d;cfgPath=$cp;outPath=Join-Path $d 'result.json'}
    }

    # ========== ALL STATES write result file (verify scanId, generatedAt, no secrets) ==========

    # Helper: verify result file for any state
    function Verify-ResultFile($td, $expectedStatus, $scanId) {
        if(-not(Test-Path -LiteralPath $td.outPath)){throw "${expectedStatus}: output must exist"}
        $sv=Get-Content -Raw -LiteralPath $td.outPath -Encoding UTF8
        $saved=$sv|ConvertFrom-Json
        if($saved.status-ne$expectedStatus){throw "${expectedStatus}: saved status mismatch, got '$($saved.status)'"}
        if($saved.scanId-ne$scanId){throw "${expectedStatus}: scanId must match, got '$($saved.scanId)'"}
        if(-not $saved.generatedAt){throw "${expectedStatus}: generatedAt must exist"}
        if($sv-match'api\.example\.com'){throw "${expectedStatus}: saved JSON must not contain endpoint"}
        if($sv-match'test-key'){throw "${expectedStatus}: saved JSON must not contain API key"}
        if($sv-match'Bearer'){throw "${expectedStatus}: saved JSON must not contain Bearer"}
        if($sv-match'WebException'){throw "${expectedStatus}: saved JSON must not contain exception text"}
    }

    # 1. disabled: enabled=false in config
    $td=New-TD 'disabled' (@{schemaVersion=1;enabled=$false;endpoint='https://api.example.com/v1';model='test-model'})
    $script:tc=0; $st={ $script:tc++; throw 'Transport must not be called' }
    $r=Invoke-DiskPulseAIAnalysis -ScanId 's1' -DirectoryResults $orcDir -HistoryCenter @() -Snapshot $orcSnap -ConfigPath $td.cfgPath -OutputPath $td.outPath -Transport $st
    if($r.status-ne'disabled'){throw "disabled: expected 'disabled', got '$($r.status)'"}
    if($r.format-ne'none'){throw "disabled: format must be 'none'"}
    if($script:tc-ne 0){throw "disabled: transport called $($script:tc) times, expected 0"}
    Verify-ResultFile $td 'disabled' 's1'

    # 2. not-configured: config file doesn't exist
    $td=New-TD 'not-configured' $null
    $ncCfg=Join-Path $td.dir 'non-existent.json'
    $script:tc=0
    $r=Invoke-DiskPulseAIAnalysis -ScanId 's2' -DirectoryResults $orcDir -HistoryCenter @() -Snapshot $orcSnap -ConfigPath $ncCfg -OutputPath $td.outPath -Transport $st
    if($r.status-ne'not-configured'){throw "not-configured: expected 'not-configured', got '$($r.status)'"}
    if($script:tc-ne 0){throw "not-configured: transport called $($script:tc) times, expected 0"}
    Verify-ResultFile $td 'not-configured' 's2'

    # 3. configuration-error: endpoint invalid
    $td=New-TD 'cfg-err-ep' (@{schemaVersion=1;enabled=$true;endpoint='http://invalid.example.com';model='test-model';protectedApiKey=$validKey;timeoutSeconds=10})
    $script:tc=0
    $r=Invoke-DiskPulseAIAnalysis -ScanId 's3' -DirectoryResults $orcDir -HistoryCenter @() -Snapshot $orcSnap -ConfigPath $td.cfgPath -OutputPath $td.outPath -Transport $st
    if($r.status-ne'configuration-error'){throw "cfg-err-ep: expected 'configuration-error', got '$($r.status)'"}
    if($script:tc-ne 0){throw "cfg-err-ep: transport called $($script:tc) times, expected 0"}
    Verify-ResultFile $td 'configuration-error' 's3'

    # 4. configuration-error: remote empty key
    $td=New-TD 'cfg-err-key' (@{schemaVersion=1;enabled=$true;endpoint='https://api.example.com/v1/chat/completions';model='test-model';protectedApiKey='';timeoutSeconds=10})
    $script:tc=0
    $r=Invoke-DiskPulseAIAnalysis -ScanId 's4' -DirectoryResults $orcDir -HistoryCenter @() -Snapshot $orcSnap -ConfigPath $td.cfgPath -OutputPath $td.outPath -Transport $st
    if($r.status-ne'configuration-error'){throw "cfg-err-key: expected 'configuration-error', got '$($r.status)'"}
    if($script:tc-ne 0){throw "cfg-err-key: transport called $($script:tc) times, expected 0"}
    Verify-ResultFile $td 'configuration-error' 's4'

    # 5. configuration-error: DPAPI decrypt failure
    $fakeKey=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('not-dpapi-data'))
    $td=New-TD 'cfg-err-dpapi' (@{schemaVersion=1;enabled=$true;endpoint='https://api.example.com/v1/chat/completions';model='test-model';protectedApiKey=$fakeKey;timeoutSeconds=10})
    $script:tc=0
    $r=Invoke-DiskPulseAIAnalysis -ScanId 's5' -DirectoryResults $orcDir -HistoryCenter @() -Snapshot $orcSnap -ConfigPath $td.cfgPath -OutputPath $td.outPath -Transport $st
    if($r.status-ne'configuration-error'){throw "cfg-err-dpapi: expected 'configuration-error', got '$($r.status)'"}
    if($script:tc-ne 0){throw "cfg-err-dpapi: transport called $($script:tc) times, expected 0"}
    Verify-ResultFile $td 'configuration-error' 's5'

    # 6. baseline-required
    $td=New-TD 'baseline-req' $validCfgObj
    $script:tc=0
    $r=Invoke-DiskPulseAIAnalysis -ScanId 's6' -DirectoryResults $orcDirNoBaseline -HistoryCenter @() -Snapshot $orcSnap -ConfigPath $td.cfgPath -OutputPath $td.outPath -Transport $st
    if($r.status-ne'baseline-required'){throw "baseline-required: expected 'baseline-required', got '$($r.status)'"}
    if($script:tc-ne 0){throw "baseline-required: transport called $($script:tc) times, expected 0"}
    Verify-ResultFile $td 'baseline-required' 's6'

    # 7. no-reliable-changes
    $td=New-TD 'no-changes' $validCfgObj
    $script:tc=0
    $r=Invoke-DiskPulseAIAnalysis -ScanId 's7' -DirectoryResults $orcDirNoChange -HistoryCenter @() -Snapshot $orcSnap -ConfigPath $td.cfgPath -OutputPath $td.outPath -Transport $st
    if($r.status-ne'no-reliable-changes'){throw "no-changes: expected 'no-reliable-changes', got '$($r.status)'"}
    if($script:tc-ne 0){throw "no-changes: transport called $($script:tc) times, expected 0"}
    Verify-ResultFile $td 'no-reliable-changes' 's7'

    # 8. all-failed
    $td=New-TD 'all-failed' $validCfgObj
    $script:tc=0
    $r=Invoke-DiskPulseAIAnalysis -ScanId 's8' -DirectoryResults $orcDirAllFailed -HistoryCenter @() -Snapshot $orcSnap -ConfigPath $td.cfgPath -OutputPath $td.outPath -Transport $st
    if($r.status-ne'no-reliable-changes'){throw "all-failed: expected 'no-reliable-changes', got '$($r.status)'"}
    if($script:tc-ne 0){throw "all-failed: transport called $($script:tc) times, expected 0"}
    Verify-ResultFile $td 'no-reliable-changes' 's8'

    # ========== REQUEST STATES (Transport called once, call count = 1) ==========

    # 9. success structured: mock returns valid JSON
    $td=New-TD 'success-struct' $validCfgObj
    $script:tc=0
    $okT={ $script:tc++; $msg=[pscustomobject]@{content='{ "summary":"Disk analysis OK", "possibleCauses":["normal usage"], "confidence":"high", "evidence":["scan complete"], "recommendations":["monitor"], "cautions":[] }'}; $ch=[pscustomobject]@{message=$msg}; return [pscustomobject]@{choices=@($ch)} }
    $r=Invoke-DiskPulseAIAnalysis -ScanId 's9' -DirectoryResults $orcDir -HistoryCenter @() -Snapshot $orcSnap -ConfigPath $td.cfgPath -OutputPath $td.outPath -Transport $okT
    if($r.status-ne'success'){throw "success-struct: expected 'success', got '$($r.status)'"}
    if($r.format-ne'structured'){throw "success-struct: format must be 'structured'"}
    if($r.analysis.summary-ne'Disk analysis OK'){throw "success-struct: summary mismatch"}
    if($r.analysis.confidence-ne'high'){throw "success-struct: confidence mismatch"}
    if($script:tc-ne 1){throw "success-struct: transport called $($script:tc) times, expected 1"}
    if(-not(Test-Path -LiteralPath $td.outPath)){throw "success-struct: output must exist"}
    $sv=Get-Content -Raw -LiteralPath $td.outPath -Encoding UTF8
    if(($sv|ConvertFrom-Json).status-ne'success'){throw "success-struct: saved status must be 'success'"}
    if($sv-match'api\.example\.com'){throw "success-struct: saved JSON must not contain endpoint"}
    if($sv-match'test-key'){throw "success-struct: saved JSON must not contain API key"}
    if($sv-match'Bearer'){throw "success-struct: saved JSON must not contain Bearer"}
    if($sv-match'WebException'){throw "success-struct: saved JSON must not contain exception text"}

    # 10. success text fallback: mock returns plain text
    $td=New-TD 'success-text' $validCfgObj
    $script:tc=0
    $txtT={ $script:tc++; $msg=[pscustomobject]@{content='Plain text analysis result.'}; $ch=[pscustomobject]@{message=$msg}; return [pscustomobject]@{choices=@($ch)} }
    $r=Invoke-DiskPulseAIAnalysis -ScanId 's10' -DirectoryResults $orcDir -HistoryCenter @() -Snapshot $orcSnap -ConfigPath $td.cfgPath -OutputPath $td.outPath -Transport $txtT
    if($r.status-ne'success'){throw "success-text: expected 'success', got '$($r.status)'"}
    if($r.format-ne'text'){throw "success-text: format must be 'text'"}
    if($r.rawText-ne'Plain text analysis result.'){throw "success-text: rawText mismatch"}
    if($script:tc-ne 1){throw "success-text: transport called $($script:tc) times, expected 1"}
    if(-not(Test-Path -LiteralPath $td.outPath)){throw "success-text: output must exist"}
    $sv=Get-Content -Raw -LiteralPath $td.outPath -Encoding UTF8
    if(($sv|ConvertFrom-Json).status-ne'success'){throw "success-text: saved status must be 'success'"}
    if(($sv|ConvertFrom-Json).format-ne'text'){throw "success-text: saved format must be 'text'"}
    if($sv-match'api\.example\.com'){throw "success-text: saved JSON must not contain endpoint"}
    if($sv-match'test-key'){throw "success-text: saved JSON must not contain API key"}

    # 11. timeout: mock throws timeout
    $td=New-TD 'timeout' $validCfgObj
    $script:tc=0
    $toT={ $script:tc++; throw (New-Object System.Net.WebException('The operation has timed out')) }
    $r=Invoke-DiskPulseAIAnalysis -ScanId 's11' -DirectoryResults $orcDir -HistoryCenter @() -Snapshot $orcSnap -ConfigPath $td.cfgPath -OutputPath $td.outPath -Transport $toT
    if($r.status-ne'timeout'){throw "timeout: expected 'timeout', got '$($r.status)'"}
    if($script:tc-ne 1){throw "timeout: transport called $($script:tc) times, expected 1"}
    if(-not(Test-Path -LiteralPath $td.outPath)){throw "timeout: output must exist"}
    $sv=Get-Content -Raw -LiteralPath $td.outPath -Encoding UTF8
    if(($sv|ConvertFrom-Json).status-ne'timeout'){throw "timeout: saved status must be 'timeout'"}
    if($sv-match'WebException'){throw "timeout: saved JSON must not contain exception text"}
    if($sv-match'api\.example\.com'){throw "timeout: saved JSON must not contain endpoint"}

    # 12. authentication-failed 401
    $td=New-TD 'auth-401' $validCfgObj
    $script:tc=0
    $e401T={ $script:tc++; throw (New-Object System.Net.WebException('401 Unauthorized')) }
    $r=Invoke-DiskPulseAIAnalysis -ScanId 's12' -DirectoryResults $orcDir -HistoryCenter @() -Snapshot $orcSnap -ConfigPath $td.cfgPath -OutputPath $td.outPath -Transport $e401T
    if($r.status-ne'authentication-failed'){throw "auth-401: expected 'authentication-failed', got '$($r.status)'"}
    if($script:tc-ne 1){throw "auth-401: transport called $($script:tc) times, expected 1"}
    if(-not(Test-Path -LiteralPath $td.outPath)){throw "auth-401: output must exist"}
    $sv=Get-Content -Raw -LiteralPath $td.outPath -Encoding UTF8
    if(($sv|ConvertFrom-Json).status-ne'authentication-failed'){throw "auth-401: saved status must be 'authentication-failed'"}
    if($sv-match'401'){throw "auth-401: saved JSON must not contain raw '401'"}
    if($sv-match'Unauthorized'){throw "auth-401: saved JSON must not contain 'Unauthorized'"}
    if($sv-match'api\.example\.com'){throw "auth-401: saved JSON must not contain endpoint"}

    # 13. authentication-failed 403
    $td=New-TD 'auth-403' $validCfgObj
    $script:tc=0
    $e403T={ $script:tc++; throw (New-Object System.Net.WebException('403 Forbidden')) }
    $r=Invoke-DiskPulseAIAnalysis -ScanId 's13' -DirectoryResults $orcDir -HistoryCenter @() -Snapshot $orcSnap -ConfigPath $td.cfgPath -OutputPath $td.outPath -Transport $e403T
    if($r.status-ne'authentication-failed'){throw "auth-403: expected 'authentication-failed', got '$($r.status)'"}
    if($script:tc-ne 1){throw "auth-403: transport called $($script:tc) times, expected 1"}
    if(-not(Test-Path -LiteralPath $td.outPath)){throw "auth-403: output must exist"}
    $sv=Get-Content -Raw -LiteralPath $td.outPath -Encoding UTF8
    if(($sv|ConvertFrom-Json).status-ne'authentication-failed'){throw "auth-403: saved status must be 'authentication-failed'"}
    if($sv-match'403'){throw "auth-403: saved JSON must not contain raw '403'"}
    if($sv-match'Forbidden'){throw "auth-403: saved JSON must not contain 'Forbidden'"}
    if($sv-match'api\.example\.com'){throw "auth-403: saved JSON must not contain endpoint"}

    # 14. rate-limited 429
    $td=New-TD 'rate-429' $validCfgObj
    $script:tc=0
    $e429T={ $script:tc++; throw (New-Object System.Net.WebException('429 Too Many Requests')) }
    $r=Invoke-DiskPulseAIAnalysis -ScanId 's14' -DirectoryResults $orcDir -HistoryCenter @() -Snapshot $orcSnap -ConfigPath $td.cfgPath -OutputPath $td.outPath -Transport $e429T
    if($r.status-ne'rate-limited'){throw "rate-429: expected 'rate-limited', got '$($r.status)'"}
    if($script:tc-ne 1){throw "rate-429: transport called $($script:tc) times, expected 1"}
    if(-not(Test-Path -LiteralPath $td.outPath)){throw "rate-429: output must exist"}
    $sv=Get-Content -Raw -LiteralPath $td.outPath -Encoding UTF8
    if(($sv|ConvertFrom-Json).status-ne'rate-limited'){throw "rate-429: saved status must be 'rate-limited'"}
    if($sv-match'429'){throw "rate-429: saved JSON must not contain raw '429'"}
    if($sv-match'Too Many'){throw "rate-429: saved JSON must not contain 'Too Many'"}
    if($sv-match'api\.example\.com'){throw "rate-429: saved JSON must not contain endpoint"}

    # 15. connection-failed: DNS error
    $td=New-TD 'conn-fail' $validCfgObj
    $script:tc=0
    $dnsT={ $script:tc++; throw (New-Object System.Net.WebException('The remote name could not be resolved: api.example.com')) }
    $r=Invoke-DiskPulseAIAnalysis -ScanId 's15' -DirectoryResults $orcDir -HistoryCenter @() -Snapshot $orcSnap -ConfigPath $td.cfgPath -OutputPath $td.outPath -Transport $dnsT
    if($r.status-ne'connection-failed'){throw "conn-fail: expected 'connection-failed', got '$($r.status)'"}
    if($script:tc-ne 1){throw "conn-fail: transport called $($script:tc) times, expected 1"}
    if(-not(Test-Path -LiteralPath $td.outPath)){throw "conn-fail: output must exist"}
    $sv=Get-Content -Raw -LiteralPath $td.outPath -Encoding UTF8
    if(($sv|ConvertFrom-Json).status-ne'connection-failed'){throw "conn-fail: saved status must be 'connection-failed'"}
    if($sv-match'resolve'){throw "conn-fail: saved JSON must not contain 'resolve'"}
    if($sv-match'api\.example\.com'){throw "conn-fail: saved JSON must not contain endpoint"}

    # 16. invalid-response: mock returns empty content
    $td=New-TD 'inv-resp' $validCfgObj
    $script:tc=0
    $empT={ $script:tc++; $msg=[pscustomobject]@{content=''}; $ch=[pscustomobject]@{message=$msg}; return [pscustomobject]@{choices=@($ch)} }
    $r=Invoke-DiskPulseAIAnalysis -ScanId 's16' -DirectoryResults $orcDir -HistoryCenter @() -Snapshot $orcSnap -ConfigPath $td.cfgPath -OutputPath $td.outPath -Transport $empT
    if($r.status-ne'invalid-response'){throw "inv-resp: expected 'invalid-response', got '$($r.status)'"}
    if($script:tc-ne 1){throw "inv-resp: transport called $($script:tc) times, expected 1"}
    if(-not(Test-Path -LiteralPath $td.outPath)){throw "inv-resp: output must exist"}
    $sv=Get-Content -Raw -LiteralPath $td.outPath -Encoding UTF8
    if(($sv|ConvertFrom-Json).status-ne'invalid-response'){throw "inv-resp: saved status must be 'invalid-response'"}
    if($sv-match'api\.example\.com'){throw "inv-resp: saved JSON must not contain endpoint"}
    if($sv-match'WebException'){throw "inv-resp: saved JSON must not contain exception text"}

    # 17. unknown-error: random error not matching any classification
    $td=New-TD 'unknown-err' $validCfgObj
    $script:tc=0
    $unkT={ $script:tc++; throw 'Something completely unexpected happened' }
    $r=Invoke-DiskPulseAIAnalysis -ScanId 's17' -DirectoryResults $orcDir -HistoryCenter @() -Snapshot $orcSnap -ConfigPath $td.cfgPath -OutputPath $td.outPath -Transport $unkT
    if($r.status-ne'unknown-error'){throw "unknown-err: expected 'unknown-error', got '$($r.status)'"}
    if($script:tc-ne 1){throw "unknown-err: transport called $($script:tc) times, expected 1"}
    if(-not(Test-Path -LiteralPath $td.outPath)){throw "unknown-err: output must exist"}
    $sv=Get-Content -Raw -LiteralPath $td.outPath -Encoding UTF8
    if(($sv|ConvertFrom-Json).status-ne'unknown-error'){throw "unknown-err: saved status must be 'unknown-error'"}
    if($sv-match'unexpected'){throw "unknown-err: saved JSON must not contain exception text"}
    if($sv-match'api\.example\.com'){throw "unknown-err: saved JSON must not contain endpoint"}

}finally{
    if(Test-Path -LiteralPath $orcTempRoot){Remove-Item -LiteralPath $orcTempRoot -Recurse -Force -ErrorAction SilentlyContinue}
}

# --- Verify original runtime/ai-config.local.json was NOT modified ---
if($origCfgExists){
    $postHash=(Get-FileHash -LiteralPath $origCfgFile -Algorithm SHA256).Hash
    if($postHash-ne$origCfgHash){throw 'Original runtime/ai-config.local.json was modified during orchestration tests!'}
}else{
    if(Test-Path -LiteralPath $origCfgFile){throw 'Original runtime/ai-config.local.json was created during orchestration tests!'}
}

Write-Host 'PASS: AI analysis orchestration — 17 states (skip + request), transport counts, saved JSON security, config integrity.'
