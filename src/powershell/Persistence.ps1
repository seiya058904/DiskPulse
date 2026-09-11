function Complete-InterruptedScans {
    param($Paths)
    if(-not(Test-Path -LiteralPath $Paths.Events)){return}
    $latest=@{}; Read-DiskPulseScanEvents $Paths.Events | ForEach-Object { $latest[[string]$_.scanId]=$_ }
    foreach($e in $latest.Values){if($e.status-eq'running'){Write-ScanEvent $Paths ([pscustomobject]@{scanId=$e.scanId;status='failed';reason='interrupted';completedAt=(Get-Date).ToUniversalTime().ToString('o')})}}
}

function Compact-ScanEvents {
    param($Paths, [int]$MaxLines = 1000, [int]$RecentFinalizedScans = 100)
    Invoke-DiskPulsePublication (Split-Path -Parent $Paths.Events) {
    if (-not (Test-Path -LiteralPath $Paths.Events -PathType Leaf)) { return }
    $lines = @(Read-DiskPulseScanEvents $Paths.Events | ForEach-Object { ConvertTo-Json -InputObject $_ -Depth 12 -Compress })
    if ($lines.Count -le $MaxLines) { return }

    $events = New-Object 'System.Collections.Generic.List[object]'
    $latest = @{}
    $order = New-Object 'System.Collections.Generic.List[string]'
    foreach ($line in $lines) {
        try {
            $event = $line | ConvertFrom-Json
            if ($null -eq $event -or [string]::IsNullOrWhiteSpace([string]$event.scanId)) { continue }
            $scanId = [string]$event.scanId
            if (-not $latest.ContainsKey($scanId)) { $order.Add($scanId) }
            $latest[$scanId] = $event
            $events.Add($event)
        } catch { }
    }

    $protected = @{}
    foreach ($snapshotFile in @(Get-ChildItem -LiteralPath $Paths.Snapshots -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
        $protected[[IO.Path]::GetFileNameWithoutExtension($snapshotFile.Name)] = $true
    }
    foreach ($scanId in $order) {
        if ([string]$latest[$scanId].status -eq 'running') { $protected[$scanId] = $true }
    }

    $recent = @($order | Where-Object {
        -not $protected.ContainsKey($_) -and [string]$latest[$_].status -in @('complete','partial','failed')
    } | Sort-Object {
        $event = $latest[$_]
        $time = if ($event.completedAt) { $event.completedAt } else { $event.startedAt }
        if ($time) { try { [datetime]$time } catch { [datetime]::MinValue } } else { [datetime]::MinValue }
    } -Descending | Select-Object -First $RecentFinalizedScans)
    foreach ($scanId in $recent) { $protected[$scanId] = $true }

    $kept = @($events | Where-Object { $protected.ContainsKey([string]$_.scanId) })
    if ($kept.Count -ge $lines.Count) { return }

    $temporaryPath = New-DiskPulseTempPath $Paths.Events
    try {
        $contentLines = @($kept | ForEach-Object { ConvertTo-Json -InputObject $_ -Depth 12 -Compress })
        $content = ($contentLines -join [Environment]::NewLine)
        if ($content) { $content += [Environment]::NewLine }
        [IO.File]::WriteAllText($temporaryPath, $content, (New-Object Text.UTF8Encoding $true))
        Get-Content -LiteralPath $temporaryPath -Encoding UTF8 | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object {
            $_ | ConvertFrom-Json | Out-Null
        }
        Publish-DiskPulseAtomicFile -FinalPath $Paths.Events -TemporaryPath $temporaryPath
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath) { Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue }
    }
    }
}

function Remove-StaleTemporaryFiles {
    param($Paths)
    $cutoff=(Get-Date).AddHours(-24)
    $candidates = @()
    if ($Paths.PSObject.Properties.Name -contains 'Runtime' -and (Test-Path -LiteralPath $Paths.Runtime)) {
        $candidates += @(Get-ChildItem -LiteralPath $Paths.Runtime -Filter '.diskpulse-*.tmp' -File -ErrorAction SilentlyContinue)
        $candidates += @(Get-ChildItem -LiteralPath $Paths.Runtime -Filter '.diskpulse-backup-*.bak' -File -ErrorAction SilentlyContinue)
    }
    if ($Paths.PSObject.Properties.Name -contains 'Snapshots' -and (Test-Path -LiteralPath $Paths.Snapshots)) {
        $candidates += @(Get-ChildItem -LiteralPath $Paths.Snapshots -Filter '*.tmp' -File -ErrorAction SilentlyContinue)
        $candidates += @(Get-ChildItem -LiteralPath $Paths.Snapshots -Filter '.diskpulse-backup-*.bak' -File -ErrorAction SilentlyContinue)
    }
    foreach($file in $candidates) {
        if($file.LastWriteTime -lt $cutoff){
            try{Remove-Item -LiteralPath $file.FullName -Force}catch{Write-Warning "无法清理临时文件 $($file.Name)"}
        }
    }
}

function Invoke-SnapshotRetention {
    param($Paths,[array]$Snapshots,[array]$CurrentDrives,[string]$CurrentScanId,[int]$Limit=30)
    $protected=@{$CurrentScanId=$true};foreach($drive in $CurrentDrives){$Snapshots|Where-Object{@($_.drives|Where-Object{$_.drive-eq$drive-and$_.status-in@('baseline','complete')}).Count}|Sort-Object{[datetime]$_.completedAt}-Descending|Select-Object -First 2|ForEach-Object{$protected[[string]$_.scanId]=$true}}
    $files=@(Get-ChildItem -LiteralPath $Paths.Snapshots -Filter '*.json' -File|ForEach-Object{$s=try{Get-Content -Raw $_.FullName -Encoding UTF8|ConvertFrom-Json}catch{$null};if($s){[pscustomobject]@{File=$_;Snapshot=$s;Partial=(@($s.drives|Where-Object{$_.status-eq'partial'}).Count-gt 0)}}})
    foreach($candidate in @($files|Where-Object{-not$protected.ContainsKey([string]$_.Snapshot.scanId)}|Sort-Object @{e='Partial';Descending=$true},@{e={$_.Snapshot.completedAt};Ascending=$true})){if($files.Count-le$Limit){break};try{Remove-Item -LiteralPath $candidate.File.FullName -Force;$files=@($files|Where-Object{$_.File.FullName-ne$candidate.File.FullName})}catch{Write-Warning "无法清理快照 $($candidate.File.Name)"}}
}
