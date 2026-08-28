function Read-Snapshots {
    param($Paths)
    $finalStatus = @{}
    if (Test-Path -LiteralPath $Paths.Events) {
        Get-Content -LiteralPath $Paths.Events -Encoding UTF8 | Where-Object { $_.Trim() } | ForEach-Object {
            try { $event = $_ | ConvertFrom-Json; $finalStatus[[string]$event.scanId] = [string]$event.status } catch {}
        }
    }
    @((Get-ChildItem -LiteralPath $Paths.Snapshots -Filter '*.json' -File -ErrorAction SilentlyContinue | ForEach-Object {
        $snapshotFile = $_
        try {
            $snapshot = Get-Content -Raw -LiteralPath $snapshotFile.FullName -Encoding UTF8 | ConvertFrom-Json
            if ($finalStatus[[string]$snapshot.scanId] -in @('complete','partial')) { $snapshot }
        }
        catch { Write-Warning "无法读取快照 $($snapshotFile.Name)" }
    }))
}

function Find-DriveBaseline {
    param([array]$Snapshots,[string]$Drive,$Current)
    if (-not $Snapshots -or $Snapshots.Count -eq 0) { return $null }
    $currentDrive = if ($Current.PSObject.Properties.Name -contains 'drives') { @($Current.drives | Where-Object { $_.drive -eq $Drive }) | Select-Object -First 1 } else { $null }
    $expectedRoot = if ($currentDrive) { [string]$currentDrive.rootPath } else { $null }
    $Snapshots | Where-Object {
        $_.scanId -ne $Current.scanId -and [datetime]$_.completedAt -lt [datetime]$Current.startedAt -and
        @($_.drives | Where-Object {
            $_.drive -eq $Drive -and $_.status -in @('baseline','complete') -and
            $_.PSObject.Properties.Name -contains 'usedBytes' -and
            (-not $expectedRoot -or [string]$_.rootPath -eq $expectedRoot)
        }).Count
    } | Sort-Object { [datetime]$_.completedAt } -Descending | Select-Object -First 1
}

function Get-DriveHistoryCandidates {
    param([array]$Snapshots,[string]$Drive,$Current)
    if (-not $Snapshots -or $Snapshots.Count -eq 0) { return @() }
    $currentDrive = @($Current.drives | Where-Object { $_.drive -eq $Drive }) | Select-Object -First 1
    if (-not $currentDrive) { return @() }
    $expectedRoot = [string]$currentDrive.rootPath
    @($Snapshots | Where-Object {
        $_.scanId -ne $Current.scanId -and
        (-not ($_.PSObject.Properties.Name -contains 'status') -or $_.status -ne 'failed') -and
        [datetime]$_.completedAt -lt [datetime]$Current.startedAt -and
        @($_.drives | Where-Object {
            $_.drive -eq $Drive -and $_.status -in @('baseline','complete') -and
            $_.PSObject.Properties.Name -contains 'usedBytes' -and [string]$_.rootPath -eq $expectedRoot
        }).Count
    } | Sort-Object { [datetime]$_.completedAt } -Descending)
}

function Select-DriveHistoryBaseline {
    param([array]$Candidates,[string]$Mode,$Current,[string]$CustomScanId)
    if (-not $Candidates -or $Candidates.Count -eq 0) { return $null }
    if ($Mode -eq 'previous') { return $Candidates | Select-Object -First 1 }
    if ($Mode -eq 'earliest') { return $Candidates | Select-Object -Last 1 }
    if ($Mode -eq 'custom') { return $Candidates | Where-Object { $_.scanId -eq $CustomScanId } | Select-Object -First 1 }
    $days = if ($Mode -eq 'day') { 1 } elseif ($Mode -eq 'week') { 7 } else { return $null }
    $target = ([datetime]$Current.startedAt).AddDays(-$days)
    $Candidates | Sort-Object @{Expression={ [math]::Abs((([datetime]$_.completedAt)-$target).TotalSeconds) }},@{Expression={ [datetime]$_.completedAt };Descending=$true} | Select-Object -First 1
}

function Test-PathEvidenceMatch {
    param([string]$Path,[array]$Evidence)
    foreach($item in $Evidence){
        $e=[string]$item.path
        if($e -and ($Path.Equals($e,[StringComparison]::OrdinalIgnoreCase) -or $Path.StartsWith($e.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase))){return $true}
    }
    return $false
}

function Compare-DriveRecords {
    param($Current,$Baseline)
    $old=@{};if($Baseline){foreach($r in @($Baseline.records)){$old[[string]$r.key]=$r}}
    $seen=@{};$result=New-Object 'Collections.Generic.List[object]'
    foreach($r in @($Current.records)){
        $seen[[string]$r.key]=$true;$prior=$old[[string]$r.key]
        $state=if(-not $Baseline){'unknown'}elseif(-not $prior){'created'}elseif([int64]$r.sizeBytes-ne[int64]$prior.sizeBytes){'changed'}else{'unchanged'}
        $delta=if($prior){[int64]$r.sizeBytes-[int64]$prior.sizeBytes}else{[int64]$r.sizeBytes}
        $result.Add([pscustomobject]@{key=$r.key;displayPath=$r.displayPath;kind=$r.kind;level=$r.level;sizeBytes=[int64]$r.sizeBytes;deltaBytes=$delta;state=$state})
    }
    if($Baseline){foreach($r in @($Baseline.records)){if($seen.ContainsKey([string]$r.key)){continue}
        $state=if(Test-PathEvidenceMatch $r.displayPath @($Current.unavailable)){'unavailable'}elseif(Test-PathEvidenceMatch $r.displayPath @($Current.excluded)){'unknown'}elseif($Current.status-eq'complete'){'removed'}else{'unknown'}
        $result.Add([pscustomobject]@{key=$r.key;displayPath=$r.displayPath;kind=$r.kind;level=$r.level;sizeBytes=[int64]0;deltaBytes=-[int64]$r.sizeBytes;state=$state})
    }}
    [object[]]$result
}

function Get-ChangeCoverage {
    param($Current,$Baseline,[array]$Rows)
    $top=@($Rows|Where-Object{$_.level-eq 1-and$_.state-in@('created','changed','removed')});[int64]$added=0;[int64]$released=0;[int64]$located=0
    foreach($r in $top){$located+=[int64]$r.deltaBytes;if($r.deltaBytes-gt 0){$added+=[int64]$r.deltaBytes}elseif($r.deltaBytes-lt 0){$released+=[math]::Abs([int64]$r.deltaBytes)}}
    $actual=if($Baseline){[int64]$Current.usedBytes-[int64]$Baseline.usedBytes}else{[int64]0}
    $rate=if([math]::Abs($actual)-lt 1){0}else{[math]::Max(0,[math]::Min(100,[math]::Round(([math]::Abs($located)/[math]::Abs($actual))*100,1)))}
    [pscustomobject]@{addedBytes=$added;releasedBytes=$released;locatedNetBytes=$located;actualNetBytes=$actual;unexplainedBytes=$actual-$located;rate=$rate;activityPreferred=([math]::Abs($actual)-lt 1-or[math]::Sign($actual)-ne[math]::Sign($located)-or($added-gt 0-and$released-gt 0))}
}

function New-HistoryComparison {
    param($CurrentDrive,$BaselineDrive,$BaselineSnapshot)
    $changes = @(Compare-DriveRecords $CurrentDrive $BaselineDrive | Where-Object { $_.state -ne 'unchanged' })
    [pscustomobject]@{
        scanId = [string]$BaselineSnapshot.scanId
        completedAt = [string]$BaselineSnapshot.completedAt
        changes = [object[]]$changes
        coverage = Get-ChangeCoverage $CurrentDrive $BaselineDrive $changes
    }
}

function Get-DirectoryTrendClassification {
    param([array]$Comparisons)
    if (-not $Comparisons) {
        return [pscustomobject]@{ label='数据不足'; cumulativeBytes=[int64]0; growthCount=0; releaseCount=0; occurrenceCount=0; comparisonCount=0 }
    }
    $valid = @($Comparisons | Where-Object { $_.state -in @('created','changed','removed','unchanged') })
    $recent = @($valid | Select-Object -Last 5)
    $growth = @($recent | Where-Object { [int64]$_.deltaBytes -gt 0 }).Count
    $release = @($recent | Where-Object { [int64]$_.deltaBytes -lt 0 }).Count
    [int64]$cumulative = 0
    foreach ($row in $valid) { $cumulative += [int64]$row.deltaBytes }
    $label = '数据不足'
    $last = if ($valid.Count) { $valid[-1] } else { $null }
    if ($last -and $last.state -eq 'created' -and @($valid | Select-Object -SkipLast 1 | Where-Object { [int64]$_.deltaBytes -ne 0 }).Count -eq 0) {
        $label = '首次出现'
    }
    elseif ($valid.Count -ge 3) {
            $priorGrowth = @($valid | Select-Object -SkipLast 1 | Where-Object { [int64]$_.deltaBytes -gt 0 } | ForEach-Object { [int64]$_.deltaBytes } | Sort-Object)
            $median = if (-not $priorGrowth.Count) { 0 } elseif ($priorGrowth.Count % 2) { [double]$priorGrowth[[math]::Floor($priorGrowth.Count / 2)] } else { ([double]$priorGrowth[$priorGrowth.Count / 2 - 1] + [double]$priorGrowth[$priorGrowth.Count / 2]) / 2 }
            if ([int64]$last.deltaBytes -gt 0 -and $median -gt 0 -and [int64]$last.deltaBytes -ge (3 * $median)) { $label = '本次突增' }
            elseif ($growth -ge 3) { $label = '持续增长' }
            elseif ($release -ge 3) { $label = '持续释放' }
            elseif ($growth -gt 0 -and $release -gt 0) { $label = '波动较大' }
    }
    [pscustomobject]@{ label=$label; cumulativeBytes=$cumulative; growthCount=$growth; releaseCount=$release; occurrenceCount=($growth+$release); comparisonCount=$valid.Count }
}

function New-HistoryComparisonCenter {
    param([array]$Snapshots,$Current)
    if ($profileMode) { Profile-Mark "history:indexSnapshots" }
    $result = New-Object 'Collections.Generic.List[object]'
    foreach ($currentDrive in @($Current.drives)) {
        $candidates = @(Get-DriveHistoryCandidates -Snapshots $Snapshots -Drive $currentDrive.drive -Current $Current)
        if ($profileMode) { Profile-Mark "history:selectCandidates:$($currentDrive.drive)" }
        $comparisons = New-Object 'Collections.Generic.List[object]'
        foreach ($candidate in $candidates) {
            $baselineDrive = @($candidate.drives | Where-Object { $_.drive -eq $currentDrive.drive }) | Select-Object -First 1
            $comparisons.Add((New-HistoryComparison -CurrentDrive $currentDrive -BaselineDrive $baselineDrive -BaselineSnapshot $candidate))
        }

        $timeline = @($candidates | Sort-Object { [datetime]$_.completedAt })
        if ($currentDrive.status -in @('baseline','complete')) { $timeline += $Current }
        $trendKeys = @{}
        if ($profileMode) { Profile-Mark "history:buildRecordIndexes:$($currentDrive.drive)" }

        # Pre-index: snapshot drive records by normalized key, and pairRows by key
        $snapDriveIndex = New-Object 'Collections.Generic.List[object]'
        foreach ($snapshotItem in $timeline) {
            $di = @{ snap = $snapshotItem; records = @{} }
            $driveItem = @($snapshotItem.drives | Where-Object { $_.drive -eq $currentDrive.drive }) | Select-Object -First 1
            if ($driveItem) {
                foreach ($record in @($driveItem.records)) {
                    $di.records[[string]$record.key] = $record
                    # Collect level-1 records as trend keys
                    if ($record.level -eq 1) {
                        $trendKeys[[string]$record.key] = [pscustomobject]@{ key=$record.key; displayPath=$record.displayPath; level=[int]$record.level }
                    }
                }
            }
            $snapDriveIndex.Add($di)
        }
        $pairRowsByKey = @{}
        for ($index = 1; $index -lt $timeline.Count; $index++) {
            $olderDrive = @($timeline[$index-1].drives | Where-Object { $_.drive -eq $currentDrive.drive }) | Select-Object -First 1
            $newerDrive = @($timeline[$index].drives | Where-Object { $_.drive -eq $currentDrive.drive }) | Select-Object -First 1
            $at = [string]$timeline[$index].completedAt
            foreach ($row in @(Compare-DriveRecords $newerDrive $olderDrive)) {
                $rk = [string]$row.key
                if (-not $pairRowsByKey.ContainsKey($rk)) { $pairRowsByKey[$rk] = New-Object 'Collections.Generic.List[object]' }
                $pairRowsByKey[$rk].Add([pscustomobject]@{ key=$row.key; state=$row.state; deltaBytes=[int64]$row.deltaBytes; at=$at })
                if ($row.level -eq 2 -and $row.state -in @('created','changed','removed') -and [int64]$row.deltaBytes -ne 0) {
                    $trendKeys[$rk] = [pscustomobject]@{ key=$row.key; displayPath=$row.displayPath; level=[int]$row.level }
                }
            }
        }
        if ($profileMode) { Profile-Mark "history:pairComparisons:$($currentDrive.drive)" }

        # Aggregate trends: single pass per trend key using pre-built indexes
        $trends = New-Object 'Collections.Generic.List[object]'
        foreach ($trendKey in $trendKeys.Values) {
            $rk = [string]$trendKey.key
            $samples = New-Object 'Collections.Generic.List[object]'
            foreach ($di in $snapDriveIndex) {
                $rec = $di.records[$rk]
                $samples.Add(@([string]$di.snap.completedAt, $(if ($rec) { [int64]$rec.sizeBytes } else { $null })))
            }
            $comps = if ($pairRowsByKey.ContainsKey($rk)) { [array]$pairRowsByKey[$rk] } else { @() }
            $classification = Get-DirectoryTrendClassification $comps
            $seenCount = 0; $firstSeen = $null; $lastSeen = $null
            foreach ($s in $samples) { if ($null -ne $s[1]) { if ($seenCount -eq 0) { $firstSeen = $s[0] }; $lastSeen = $s[0]; $seenCount++ } }
            $trends.Add([pscustomobject]@{
                key=$trendKey.key; displayPath=$trendKey.displayPath; level=$trendKey.level
                samples=[object[]]$samples; cumulativeBytes=$classification.cumulativeBytes
                growthCount=$classification.growthCount; releaseCount=$classification.releaseCount
                occurrenceCount=$classification.occurrenceCount; comparisonCount=$classification.comparisonCount
                label=$classification.label
                firstSeen=$firstSeen; lastSeen=$lastSeen
            })
        }
        if ($profileMode) { Profile-Mark "history:aggregateTrends:$($currentDrive.drive)" }

        $previous = Select-DriveHistoryBaseline $candidates previous $Current
        $day = Select-DriveHistoryBaseline $candidates day $Current
        $week = Select-DriveHistoryBaseline $candidates week $Current
        $earliest = Select-DriveHistoryBaseline $candidates earliest $Current
        $result.Add([pscustomobject]@{
            drive=$currentDrive.drive; status=$currentDrive.status
            selections=[pscustomobject]@{previous=if($previous){$previous.scanId}else{$null};day=if($day){$day.scanId}else{$null};week=if($week){$week.scanId}else{$null};earliest=if($earliest){$earliest.scanId}else{$null}}
            comparisons=[object[]]$comparisons; trends=[object[]]$trends
        })
    }
    if ($profileMode) { Profile-Mark "history:buildOutput" }
    [object[]]$result
}
