$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'TestHelpers.ps1')
$canonical=New-DiskPulseCanonicalTestSource -Components @('Common','Scanner','History','Persistence','AI','Migration')
. $canonical
$testRoot=Join-Path $env:TEMP ('DiskPulse-Audit-'+[guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($testRoot) | Out-Null
function Assert($Condition,[string]$Message) { if(-not $Condition){throw $Message} }
function Paths([string]$Name) {
    $root=Join-Path $testRoot $Name; $runtime=Join-Path $root 'runtime'
    [IO.Directory]::CreateDirectory((Join-Path $runtime 'snapshots')) | Out-Null
    [pscustomobject]@{Root=$root;Runtime=$runtime;Snapshots=(Join-Path $runtime 'snapshots');Events=(Join-Path $runtime 'scans.jsonl');Lock=(Join-Path $runtime 'DiskPulse.lock')}
}
function Seed($Paths,[string]$Id) {
    $snap=[pscustomobject]@{scanId=$Id;status='complete';startedAt='2026-01-01T00:00:00Z';completedAt='2026-01-01T00:01:00Z';drives=@([pscustomobject]@{drive='T:';status='complete';rootPath='T:\';usedBytes=10;records=@()})}
    Write-DiskPulseAtomicText (Join-Path $Paths.Snapshots ($Id+'.json')) (ConvertTo-Json $snap -Depth 12)
    Write-ScanEvent $Paths ([pscustomobject]@{scanId=$Id;status='complete'})
}
function Wait-File([string]$Path,$Process) {
    $watch=[Diagnostics.Stopwatch]::StartNew()
    while(-not [IO.File]::Exists($Path)) {
        if($Process.HasExited){if([IO.File]::Exists($Path)){return};throw "Child exited before barrier $Path : $($Process.ExitCode)"}
        if($watch.ElapsedMilliseconds -gt 15000){throw 'Barrier timed out.'}
        Start-Sleep -Milliseconds 20
    }
}
function Child([string]$Body,[string]$Ready,[string]$Gate) {
    $file=Join-Path $testRoot ([guid]::NewGuid().ToString('N')+'.ps1')
    $prefix="`$ErrorActionPreference='Stop'; . '$($canonical.Replace("'","''"))'; `$ready='$($Ready.Replace("'","''"))'; `$gate='$($Gate.Replace("'","''"))'; "
    [IO.File]::WriteAllText($file,$prefix+$Body,(New-Object Text.UTF8Encoding $true))
    $exe=(Get-Process -Id $PID).Path
    $info=New-Object Diagnostics.ProcessStartInfo
    $info.FileName=$exe; $info.Arguments='-NoProfile -ExecutionPolicy Bypass -File "'+$file+'"'
    $info.UseShellExecute=$false; $info.CreateNoWindow=$true; $info.WindowStyle='Hidden'
    $process=[Diagnostics.Process]::Start($info)
    $script:children+=@($process)
    return $process
}
$script:children=@()
$links=@()
try {
    $paths=Paths 'config'; $cfg=Join-Path $paths.Runtime 'ai-config.local.json'
    $config=[pscustomobject]@{schemaVersion=1;enabled=$true;endpoint='http://localhost:9999/v1';model='fixture';protectedApiKey=(Protect-DiskPulseSecret 'offline-fixture-key');timeoutSeconds=5}
    Save-DiskPulseAIConfig $cfg $config -Enable
    $before=[IO.File]::ReadAllText($cfg)
    $bad=$config | ConvertTo-Json | ConvertFrom-Json; $bad.model=''
    try { Save-DiskPulseAIConfig $cfg $bad; throw 'Validation unexpectedly succeeded.' } catch { Assert ($_.Exception.Message -ne 'Validation unexpectedly succeeded.') 'Validation must reject empty model.' }
    Assert ([IO.File]::ReadAllText($cfg) -eq $before) 'Invalid save replaced configuration.'
    # Exercise actual menu branches with offline connection handling.
    function Get-DiskPulsePaths { $paths }
    function Test-DiskPulseAIConnection { param($Config) [pscustomobject]@{ok=$true;message='offline fixture';response=''} }
    $script:answers=New-Object 'Collections.Generic.Queue[string]'
    function Read-Host { param($Prompt,[switch]$AsSecureString) $script:answers.Dequeue() }
    foreach($answer in @('3','6')){$script:answers.Enqueue($answer)}
    Invoke-DiskPulseAIConfigure
    $disabled=Get-Content -Raw $cfg | ConvertFrom-Json
    Assert (-not $disabled.enabled -and $disabled.endpoint -eq $config.endpoint -and $disabled.protectedApiKey -eq $config.protectedApiKey) 'Disable menu lost fields.'
    foreach($answer in @('2','','modified','n','','6')){$script:answers.Enqueue($answer)}
    Invoke-DiskPulseAIConfigure
    Assert ((Get-DiskPulseAIConfig $cfg).model -eq 'modified') 'Modify menu did not persist.'
    foreach($answer in @('4','6')){$script:answers.Enqueue($answer)}
    Invoke-DiskPulseAIConfigure
    Assert ((Test-Path ($cfg+'.deleted')) -and -not (Get-DiskPulseAIConfig $cfg)) 'Deletion must revoke authorization.'
    # Crash-equivalent persisted tombstone with an old config still present.
    Write-DiskPulseAtomicText $cfg $before
    Assert (-not (Get-DiskPulseAIConfig $cfg)) 'Tombstone must dominate existing configuration.'
    foreach($answer in @('1','5','http://localhost:9999/v1','new','n','','6')){$script:answers.Enqueue($answer)}
    Invoke-DiskPulseAIConfigure
    Assert ((Get-DiskPulseAIConfig $cfg).model -eq 'new' -and -not (Test-Path ($cfg+'.deleted'))) 'Create menu must publish before clearing revocation.'

    $paths=Paths 'journal'
    Write-ScanEvent $paths ([pscustomobject]@{scanId='one';status='complete'})
    [IO.File]::AppendAllText($paths.Events,'{"scanId":')
    Assert (@(Read-DiskPulseScanEvents $paths.Events).Count -eq 1) 'Torn tail lost earlier events.'
    Write-ScanEvent $paths ([pscustomobject]@{scanId='two';status='complete'})
    Assert (@(Read-DiskPulseScanEvents $paths.Events).Count -eq 2) 'Append did not repair torn tail.'

    # Real process death while holding each lock must release OS ownership.
    foreach($kind in @('run','publish')) {
        $ready=Join-Path $testRoot ($kind+'.ready'); $gate=Join-Path $testRoot ($kind+'.gate')
        $runtime=$paths.Runtime.Replace("'","''"); $lock=$paths.Lock.Replace("'","''")
        $body=if($kind -eq 'run'){"`$owner=Acquire-DiskPulseLock ([pscustomobject]@{Lock='$lock'}) 'child'; [IO.File]::WriteAllText(`$ready,'ready'); while(-not [IO.File]::Exists(`$gate)){Start-Sleep -Milliseconds 20}"}else{"Invoke-DiskPulsePublication '$runtime' { [IO.File]::WriteAllText(`$ready,'ready'); while(-not [IO.File]::Exists(`$gate)){Start-Sleep -Milliseconds 20} }"}
        $child=Child $body $ready $gate; Wait-File $ready $child
        if($kind -eq 'run') {
            $bytes=[IO.File]::ReadAllText($paths.Events)
            try { Acquire-DiskPulseLock $paths 'other' | Out-Null; throw 'Concurrent owner accepted.' } catch { Assert ($_.Exception.Message -ne 'Concurrent owner accepted.') 'Concurrent owner must fail.' }
            Assert ([IO.File]::ReadAllText($paths.Events) -eq $bytes) 'Rejected owner modified journal.'
            $appReady=Join-Path $testRoot 'app.ready';$appGate=Join-Path $testRoot 'app.gate'
            $repo=Split-Path -Parent $PSScriptRoot
            $body="`$env:DISKPULSE_TEST_MODE='1';`$env:DISKPULSE_ROOT='$repo';`$env:DISKPULSE_DATA_ROOT='$($paths.Root)';`$s=Get-Content -Raw -LiteralPath '$repo\check.bat' -Encoding UTF8;Invoke-Expression `$s.Substring(`$s.IndexOf('#>')+2);try{Invoke-DiskPulse;throw 'Duplicate app accepted'}catch{if(`$_.Exception.Message -notmatch 'already running'){throw}};[IO.File]::WriteAllText(`$ready,'rejected')"
            $duplicate=Child $body $appReady $appGate;Wait-File $appReady $duplicate;$duplicate.WaitForExit()
            Assert ($duplicate.ExitCode -eq 0 -and [IO.File]::ReadAllText($paths.Events) -eq $bytes) 'Duplicate application entry mutated active journal.'
        }
        $child.Kill(); $child.WaitForExit()
        $owner=Acquire-DiskPulseLock $paths 'recovered'; Release-DiskPulseLock $paths $owner
        Invoke-DiskPulsePublication $paths.Runtime { Write-ScanEvent $paths ([pscustomobject]@{scanId='after-'+$kind;status='complete'}) }
    }

    # Same scan, two independent jobs: B commits before A resumes.
    $paths=Paths 'ai'; Seed $paths 'same'
    $html=Join-Path $paths.Runtime 'DiskPulse.html'
    Write-DiskPulseAtomicText $html 'const RAW_SCAN_META = {"scanId":"same"}; /* DISKPULSE_AI_RESULT_START */ const RAW_AI_ANALYSIS = {}; /* DISKPULSE_AI_RESULT_END */'
    $a='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'; $b='bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
    Write-DiskPulseAtomicText (Join-Path $paths.Runtime 'ai-current.json') (ConvertTo-Json @{scanId='same';analysisId=$b})
    $ready=Join-Path $testRoot 'ai.ready'; $gate=Join-Path $testRoot 'ai.gate'
    $runtime=$paths.Runtime.Replace("'","''"); $htmlLiteral=$html.Replace("'","''")
    $body="`$p=[pscustomobject]@{Runtime='$runtime';Events=(Join-Path '$runtime' 'scans.jsonl')}; `$r=New-DiskPulseAIStatus 'same' 'success' 'test' `$null 'A' 'raw'; `$r|Add-Member analysisId '$a'; [IO.File]::WriteAllText(`$ready,'ready'); while(-not [IO.File]::Exists(`$gate)){Start-Sleep -Milliseconds 20}; if(Submit-DiskPulseAIResult `$p '$htmlLiteral' `$r){throw 'A committed'}"
    $child=Child $body $ready $gate; Wait-File $ready $child
    $result=New-DiskPulseAIStatus 'same' 'success' 'test' $null 'B' 'raw'; $result | Add-Member analysisId $b
    Assert (Submit-DiskPulseAIResult $paths $html $result) 'Current B must commit.'
    $published=[IO.File]::ReadAllText($html)
    [IO.File]::WriteAllText($gate,'go'); $child.WaitForExit(); Assert ($child.ExitCode -eq 0) 'A did not discard.'
    Assert ([IO.File]::ReadAllText($html) -eq $published) 'A rolled back B HTML.'
    Assert ((Get-Content -Raw (Join-Path $paths.Runtime 'last-ai-analysis.json') | ConvertFrom-Json).analysisId -eq $b) 'A rolled back B JSON.'
    Assert (-not (Test-Path (Join-Path $paths.Runtime ('ai-live-same-'+$a+'.js')))) 'Stale probe published.'

    # Pause A after reading its HTML and before File.Replace. B must wait, then remain final.
    Write-DiskPulseAtomicText (Join-Path $paths.Runtime 'ai-current.json') (ConvertTo-Json @{scanId='same';analysisId=$a})
    $ready=Join-Path $testRoot 'html-a.ready';$gate=Join-Path $testRoot 'html-a.gate'
    $body=@'
$p=[pscustomobject]@{Runtime='__RUNTIME__';Events=(Join-Path '__RUNTIME__' 'scans.jsonl')}
$html=Join-Path $p.Runtime 'DiskPulse.html';$original=${function:Publish-DiskPulseAtomicFile}
function Publish-DiskPulseAtomicFile {param($FinalPath,$TemporaryPath) if($FinalPath -eq (Join-Path $p.Runtime 'DiskPulse.html')){[IO.File]::WriteAllText($ready,'ready');while(-not [IO.File]::Exists($gate)){Start-Sleep -Milliseconds 20}}; & $original $FinalPath $TemporaryPath}
$r=New-DiskPulseAIStatus 'same' 'success' 'test' $null 'A' 'raw';$r|Add-Member analysisId 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
if(-not (Submit-DiskPulseAIResult $p $html $r)){throw 'A should publish before B obtains the lock.'}
'@
    $htmlWorker=Child ($body.Replace('__RUNTIME__',$paths.Runtime)) $ready $gate;Wait-File $ready $htmlWorker
    $newReady=Join-Path $testRoot 'html-b.ready';$newDone=Join-Path $testRoot 'html-b.done'
    $body=@'
$p=[pscustomobject]@{Runtime='__RUNTIME__';Events=(Join-Path '__RUNTIME__' 'scans.jsonl')}
[IO.File]::WriteAllText($ready,'ready')
Invoke-DiskPulsePublication $p.Runtime {
    Write-DiskPulseAtomicText (Join-Path $p.Runtime 'ai-current.json') '{"scanId":"next","analysisId":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}'
    Write-DiskPulseAtomicText (Join-Path $p.Runtime 'DiskPulse.html') 'const RAW_SCAN_META = {"scanId":"next"}; NEW CAPACITY B'
    Write-DiskPulseAtomicText (Join-Path $p.Runtime 'last-ai-analysis.json') '{"scanId":"next","analysisId":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","status":"analyzing"}'
    Write-ScanEvent $p ([pscustomobject]@{scanId='next';status='complete'})
}
[IO.File]::WriteAllText($gate,'done')
'@
    $newScan=Child ($body.Replace('__RUNTIME__',$paths.Runtime)) $newReady $newDone;Wait-File $newReady $newScan
    Assert (-not [IO.File]::Exists($newDone)) 'New scan bypassed an active HTML publication.'
    [IO.File]::WriteAllText($gate,'go');$htmlWorker.WaitForExit();$newScan.WaitForExit()
    Assert ($htmlWorker.ExitCode -eq 0 -and $newScan.ExitCode -eq 0) 'HTML boundary processes failed.'
    Assert ([IO.File]::ReadAllText($html).Contains('NEW CAPACITY B')) 'Old HTML replaced the new report.'
    Assert ((Get-Content -Raw (Join-Path $paths.Runtime 'last-ai-analysis.json') | ConvertFrom-Json).scanId -eq 'next') 'Old JSON replaced the new scan.'

    # Kill at real atomic publication boundaries, not just at the mocked transport.
    foreach($phase in @('before-replace','after-replace','after-tombstone','after-config')) {
        $crash=Paths $phase; $target=Join-Path $crash.Runtime 'ai-config.local.json'
        Save-DiskPulseAIConfig $target $config -Enable
        if($phase -eq 'after-config'){Write-DiskPulseAtomicText ($target+'.deleted') '{"deleted":true}'}
        $ready=Join-Path $testRoot ($phase+'.ready'); $gate=Join-Path $testRoot ($phase+'.gate')
        $body=@'
$target='__TARGET__'; $phase='__PHASE__'
$original=${function:Publish-DiskPulseAtomicFile}
function Publish-DiskPulseAtomicFile {
    param($FinalPath,$TemporaryPath)
    $pause=($phase -in @('before-replace','after-replace','after-config') -and $FinalPath -eq $target) -or ($phase -eq 'after-tombstone' -and $FinalPath -eq ($target+'.deleted'))
    if($pause -and $phase -eq 'before-replace') {
        $stream=[IO.File]::Open($TemporaryPath,'Open','ReadWrite','None');$stream.Flush($true);$stream.Dispose()
        [IO.File]::WriteAllText($ready,'ready'); while(-not [IO.File]::Exists($gate)){Start-Sleep -Milliseconds 20}
    }
    & $original $FinalPath $TemporaryPath
    if($pause -and $phase -ne 'before-replace') {
        [IO.File]::WriteAllText($ready,'ready'); while(-not [IO.File]::Exists($gate)){Start-Sleep -Milliseconds 20}
    }
}
if($phase -eq 'after-tombstone'){Remove-DiskPulseAIConfig $target}
else {Save-DiskPulseAIConfig $target ([pscustomobject]@{schemaVersion=1;enabled=$true;endpoint='http://localhost:9999/v1';model='replacement';protectedApiKey=''}) -Enable}
'@
        $body=$body.Replace('__TARGET__',$target.Replace("'","''")).Replace('__PHASE__',$phase)
        $child=Child $body $ready $gate; Wait-File $ready $child; $child.Kill();$child.WaitForExit()
        $saved=Get-Content -Raw $target | ConvertFrom-Json
        if($phase -eq 'before-replace'){Assert ($saved.model -eq 'fixture') 'Crash before replace lost old file.'}
        elseif($phase -eq 'after-replace'){Assert ($saved.model -eq 'replacement') 'Crash after replace lost new file.'}
        else {Assert (-not (Get-DiskPulseAIConfig $target)) 'Crash re-enabled revoked config.'}
    }

    # A compactor pauses after reading. Another process cannot append until replacement finishes.
    $compact=Paths 'compact'
    1..8 | ForEach-Object { Write-ScanEvent $compact ([pscustomobject]@{scanId="old$_";status='complete';completedAt='2026-01-01T00:00:00Z'}) }
    $ready=Join-Path $testRoot 'compact.ready';$gate=Join-Path $testRoot 'compact.gate'
    $body=@'
$p=[pscustomobject]@{Runtime='__RUNTIME__';Events='__EVENTS__';Snapshots='__SNAPSHOTS__'}
$original=${function:Publish-DiskPulseAtomicFile}
function Publish-DiskPulseAtomicFile {param($FinalPath,$TemporaryPath) [IO.File]::WriteAllText($ready,'ready');while(-not [IO.File]::Exists($gate)){Start-Sleep -Milliseconds 20}; & $original $FinalPath $TemporaryPath}
Compact-ScanEvents $p -MaxLines 2 -RecentFinalizedScans 1
'@
    $body=$body.Replace('__RUNTIME__',$compact.Runtime).Replace('__EVENTS__',$compact.Events).Replace('__SNAPSHOTS__',$compact.Snapshots)
    $compactor=Child $body $ready $gate;Wait-File $ready $compactor
    $writerReady=Join-Path $testRoot 'writer.ready';$writerDone=Join-Path $testRoot 'writer.done'
    $body="[IO.File]::WriteAllText(`$ready,'ready');Write-ScanEvent ([pscustomobject]@{Events='$($compact.Events)'}) ([pscustomobject]@{scanId='new';status='complete'});[IO.File]::WriteAllText(`$gate,'done')"
    $writer=Child $body $writerReady $writerDone;Wait-File $writerReady $writer
    Assert (-not [IO.File]::Exists($writerDone)) 'Writer bypassed publication lock.'
    [IO.File]::WriteAllText($gate,'go');$compactor.WaitForExit();$writer.WaitForExit()
    Assert ($compactor.ExitCode -eq 0 -and $writer.ExitCode -eq 0) 'Compaction interleaving failed.'
    Assert (@(Read-DiskPulseScanEvents $compact.Events | Where-Object scanId -eq 'new').Count -eq 1) 'Compaction lost committed event.'

    foreach($phase in @('snapshot','ledger')) {
        $from=Paths ('from-'+$phase);$to=Paths ('to-'+$phase);Seed $from 'recover'
        $ready=Join-Path $testRoot ('migrate-'+$phase+'.ready');$gate=Join-Path $testRoot ('migrate-'+$phase+'.gate')
        $body=@'
$p=[pscustomobject]@{Runtime='__RUNTIME__';Snapshots='__SNAPSHOTS__';Events='__EVENTS__';Lock='__LOCK__'}
$original=${function:Publish-DiskPulseAtomicFile}
function Publish-DiskPulseAtomicFile {
    param($FinalPath,$TemporaryPath)
    & $original $FinalPath $TemporaryPath
    if(('__PHASE__' -eq 'snapshot' -and $FinalPath -eq (Join-Path $p.Snapshots 'recover.json')) -or
       ('__PHASE__' -eq 'ledger' -and $FinalPath.EndsWith('migration-ledger.json') -and (Test-Path $p.Events))) {
        [IO.File]::WriteAllText($ready,'ready');while(-not [IO.File]::Exists($gate)){Start-Sleep -Milliseconds 20}
    }
}
Invoke-DiskPulseMigration $p @('__SOURCE__')
'@
        $body=$body.Replace('__RUNTIME__',$to.Runtime).Replace('__SNAPSHOTS__',$to.Snapshots).Replace('__EVENTS__',$to.Events).Replace('__LOCK__',$to.Lock).Replace('__PHASE__',$phase).Replace('__SOURCE__',$from.Runtime)
        $child=Child $body $ready $gate;Wait-File $ready $child;$child.Kill();$child.WaitForExit()
        Invoke-DiskPulseMigration $to @($from.Runtime)
        Assert (@(Read-Snapshots $to).Count -eq 1) 'Interrupted migration did not recover visible history.'
        Invoke-DiskPulseMigration $to @($from.Runtime)
        Assert (@(Read-DiskPulseScanEvents $to.Events).Count -eq 1) 'Recovered migration duplicated terminal event.'
    }

    $destination=Paths 'migration'; $old=Paths 'old'; $other=Paths 'other'
    Seed $destination 'new'; Seed $old 'old'; Seed $other 'other'
    Save-DiskPulseAIConfig (Join-Path $old.Runtime 'ai-config.local.json') $config -Enable
    Invoke-DiskPulseMigration $destination @($old.Runtime,$other.Runtime)
    Assert (@(Read-Snapshots $destination).Count -eq 3) 'Multi-source migration must preserve snapshot/terminal associations.'
    Assert ((Get-DiskPulseAILatestScanEvent $destination.Events).scanId -eq 'new') 'Imported old events must not become the current scan.'
    Assert (-not (Get-DiskPulseAIConfig (Join-Path $destination.Runtime 'ai-config.local.json')).enabled) 'Migrated AI must be disabled.'
    $invalid=Paths 'invalid-source';Seed $invalid 'new';Seed $invalid 'failed';Seed $invalid 'running';Seed $invalid 'missing-terminal'
    $conflict=Join-Path $invalid.Snapshots 'new.json'
    [IO.File]::AppendAllText($conflict,' ')
    Write-ScanEvent $invalid ([pscustomobject]@{scanId='failed';status='failed'})
    Write-ScanEvent $invalid ([pscustomobject]@{scanId='running';status='running'})
    $events=@(Read-DiskPulseScanEvents $invalid.Events | Where-Object scanId -ne 'missing-terminal' | ForEach-Object { ConvertTo-Json $_ -Compress })
    Write-DiskPulseAtomicText $invalid.Events ($events -join "`n")
    Write-DiskPulseAtomicText (Join-Path $invalid.Snapshots 'broken.json') '{broken'
    $existing=[IO.File]::ReadAllText((Join-Path $destination.Snapshots 'new.json'))
    Invoke-DiskPulseMigration $destination @($invalid.Runtime)
    Assert (@(Read-Snapshots $destination).Count -eq 3) 'Untrusted snapshots gained terminal status.'
    Assert ([IO.File]::ReadAllText((Join-Path $destination.Snapshots 'new.json')) -eq $existing) 'scanId conflict overwrote current data.'
    Remove-DiskPulseAIConfig (Join-Path $destination.Runtime 'ai-config.local.json')
    [IO.File]::Delete((Join-Path $destination.Snapshots 'old.json'))
    Invoke-DiskPulseMigration $destination @($old.Runtime,$other.Runtime)
    Assert (-not (Test-Path (Join-Path $destination.Snapshots 'old.json'))) 'Completed source resurrected deleted history.'
    Assert (-not (Test-Path (Join-Path $destination.Runtime 'ai-config.local.json'))) 'Completed source resurrected config.'
    $ledger=Join-Path $destination.Root 'migration-ledger.json'; [IO.File]::WriteAllText($ledger,'broken')
    try { Invoke-DiskPulseMigration $destination @($old.Runtime); throw 'Corrupt ledger accepted.' } catch { Assert ($_.Exception.Message -ne 'Corrupt ledger accepted.') 'Corrupt ledger must fail closed.' }
    Assert ([IO.File]::ReadAllText($ledger) -eq 'broken') 'Corrupt ledger was overwritten.'
    $lost=Paths 'lost-ledger';Invoke-DiskPulseMigration $lost @()
    [IO.File]::Delete((Join-Path $lost.Root 'migration-ledger.json'))
    try { Invoke-DiskPulseMigration $lost @($old.Runtime);throw 'Missing ledger accepted.' } catch { Assert ($_.Exception.Message -ne 'Missing ledger accepted.') 'Missing initialized ledger must fail closed.' }
    Assert (@(Read-Snapshots $lost).Count -eq 0) 'Missing ledger restarted migration.'
    $linked=Join-Path $testRoot 'linked-root'; cmd /c mklink /J "$linked" "$old.Runtime" | Out-Null
    if($LASTEXITCODE -ne 0){throw 'Root junction fixture creation failed.'}; $links+=@($linked)
    $safe=Paths 'linked-target'; Invoke-DiskPulseMigration $safe @($linked)
    Assert (@(Read-Snapshots $safe).Count -eq 0) 'Root junction was traversed.'
    $unicode=Paths '旧版-é-日本-😀'
    $marker=Join-Path $testRoot 'marker.txt'; [IO.File]::WriteAllText($marker,$unicode.Runtime,(New-Object Text.UnicodeEncoding $false,$true,$true))
    Assert ((Read-DiskPulseMigrationMarker $marker) -eq $unicode.Runtime) 'Unicode marker did not round-trip.'
    [IO.File]::WriteAllText($marker,$old.Runtime,(New-Object Text.UTF8Encoding $false))
    Assert ((Read-DiskPulseMigrationMarker $marker) -eq $old.Runtime) 'ASCII marker candidates must deduplicate.'
    $accented=Join-Path $testRoot 'café';[IO.Directory]::CreateDirectory($accented) | Out-Null
    $utf8=(New-Object Text.UTF8Encoding $false,$true).GetBytes($accented)
    [IO.File]::WriteAllBytes($marker,$utf8)
    Assert ((Read-DiskPulseMigrationMarker $marker) -ceq $accented) 'Unique UTF-8 candidate must be selected.'
    $acp=[DiskPulseCodePage]::GetACP();$encoding=[Text.Encoding]::GetEncoding($acp)
    $alternative=$encoding.GetString($utf8)
    if($alternative -cne $accented -and $alternative.StartsWith($testRoot+'\',[StringComparison]::OrdinalIgnoreCase)) {
        [IO.Directory]::CreateDirectory($alternative) | Out-Null
        try { Read-DiskPulseMigrationMarker $marker | Out-Null;throw 'Ambiguous marker accepted.' } catch { Assert ($_.Exception.Message -ne 'Ambiguous marker accepted.') 'Two existing decoding candidates must be rejected.' }
    }
    $legacyBytes=$encoding.GetBytes($accented)
    if($encoding.GetString($legacyBytes) -ceq $accented) {
        [IO.File]::WriteAllBytes($marker,$legacyBytes)
        Assert ((Read-DiskPulseMigrationMarker $marker) -ceq $accented) 'Legacy ACP marker must decode without loss.'
    }
    Write-Host "Marker decoding tested with system ACP $acp."
    Write-Host 'PASS: audit configuration menus, lock death, journal recovery, conditional commit and migration.'
} finally {
    foreach($child in $script:children){if(-not $child.HasExited){$child.Kill();$child.WaitForExit()};$child.Dispose()}
    foreach($link in $links){[IO.Directory]::Delete($link)}
    # Only this generated fixture tree; links are removed before enumeration.
    foreach($file in @(Get-ChildItem -LiteralPath $testRoot -Recurse -File -Force)){[IO.File]::Delete($file.FullName)}
    foreach($dir in @(Get-ChildItem -LiteralPath $testRoot -Recurse -Directory -Force | Sort-Object { $_.FullName.Length } -Descending)){[IO.Directory]::Delete($dir.FullName)}
    [IO.Directory]::Delete($testRoot); [IO.File]::Delete($canonical)
}
