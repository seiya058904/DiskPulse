function Invoke-DiskPulse {
$paths = Get-DiskPulsePaths
Ensure-Directory $paths.Runtime
Ensure-Directory $paths.Legacy
Ensure-Directory $paths.Snapshots
$scanId = New-ScanId
$owner = Acquire-DiskPulseLock $paths $scanId
try {
Invoke-DiskPulsePublication $paths.Runtime {
Complete-InterruptedScans $paths
Compact-ScanEvents $paths
Remove-StaleTemporaryFiles $paths
Remove-StaleDiskPulseAIInputs $paths.Runtime
}
$legacyFile = Invoke-DiskPulsePublication $paths.Runtime { Copy-LegacyHistory $paths }
Profile-Mark "init"
$startedAt = (Get-Date).ToUniversalTime().ToString("o")
$runStopwatch = [Diagnostics.Stopwatch]::StartNew()
$scanStage = "初始化"
$progressState = New-DiskPulseProgressState
$progressStage = "init"
$progressDrive = ""
# Pre-initialized so the failure path can always publish progress, even when the
# pipeline aborts before the drive loop assigns the real drive counters.
$completedDrives = 0
$totalDrives = 0
$publishProgress = {
    param([string]$Status, [string]$Stage, [string]$Drive, $Progress, [bool]$ForcePublish)
    Write-DiskPulseScanProgress -Paths $paths -ScanId $scanId -Status $Status -Stage $Stage -Drive $Drive `
        -Progress $Progress -CompletedDrives $completedDrives -TotalDrives $totalDrives `
        -ElapsedMilliseconds $runStopwatch.ElapsedMilliseconds -State $progressState -Force:$ForcePublish
}
$consoleProgressState = @{ LastLength = 0; Active = $false; LastRenderedMilliseconds = -1 }
$clearConsoleProgress = {
    if ($silent) { return }
    if ($consoleProgressState.Active) {
        Write-Host ("`r" + (' ' * $consoleProgressState.LastLength) + "`r") -NoNewline
        $consoleProgressState.Active = $false
        $consoleProgressState.LastLength = 0
    }
}
Write-ScanEvent $paths ([PSCustomObject]@{ scanId = $scanId; status = "running"; startedAt = $startedAt })

try {
$logFile  = Join-Path $paths.Runtime "DiskPulse.csv"
$htmlFile = Join-Path $paths.Runtime "DiskPulse.html"
$timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
$maxHistoryRows = 3650

function Read-Number {
    param(
        [Parameter(Mandatory = $false)] $Value,
        [double] $Fallback = 0
    )
    $parsed = 0.0
    if ([double]::TryParse([string]$Value, [Globalization.NumberStyles]::Any, [Globalization.CultureInfo]::InvariantCulture, [ref]$parsed)) {
        return $parsed
    }
    return $Fallback
}

function New-HistoryRow {
    param(
        [string] $Timestamp,
        [string] $ID,
        [double] $Total,
        [double] $Free,
        [double] $Used,
        [double] $Percent
    )
    [PSCustomObject]@{
        Timestamp = $Timestamp
        ID        = $ID
        Total     = [math]::Round($Total, 2)
        Free      = [math]::Round($Free, 2)
        Used      = [math]::Round($Used, 2)
        Percent   = [math]::Round($Percent, 1)
    }
}

$historyRows = [System.Collections.Generic.List[PSObject]]::new()
$historySource = if (Test-Path -LiteralPath $logFile) { $logFile } elseif (Test-Path -LiteralPath $legacyFile) { $legacyFile } else { $null }
if ($historySource) {
    try {
        $imported = Import-Csv -LiteralPath $historySource
        foreach ($row in $imported) {
            $props = $row.PSObject.Properties.Name
            $rowId = if ($props -contains "ID") { [string]$row.ID } else { "" }
            if ([string]::IsNullOrWhiteSpace($rowId)) { continue }

            $rowTs = if (($props -contains "Timestamp") -and -not [string]::IsNullOrWhiteSpace([string]$row.Timestamp)) {
                [string]$row.Timestamp
            } else {
                (Get-Date).AddDays(-1).ToString("yyyy-MM-dd HH:mm:ss")
            }

            $used = if ($props -contains "Used") { Read-Number $row.Used } else { 0 }
            $total = if ($props -contains "Total") { Read-Number $row.Total } else { 0 }
            $free = if ($props -contains "Free") { Read-Number $row.Free } else { [math]::Max(0, $total - $used) }
            $percent = if ($props -contains "Percent") {
                Read-Number $row.Percent
            } elseif ($total -gt 0) {
                [math]::Round(($used / $total) * 100, 1)
            } else {
                0
            }

            $historyRows.Add((New-HistoryRow -Timestamp $rowTs -ID $rowId -Total $total -Free $free -Used $used -Percent $percent))
        }
    }
    catch {
        Write-Warning "History unreadable, starting fresh."
    }
}
Profile-Mark "readHistory"

$previousById = @{}
foreach ($row in ($historyRows | Sort-Object Timestamp)) {
    $previousById[$row.ID] = $row
}

$drives = @()
try {
    $drives = Get-CimInstance Win32_LogicalDisk |
        Where-Object { $_.DriveType -eq 3 } |
        ForEach-Object {
            $deviceId = [string]$_.DeviceID
            [PSCustomObject]@{
                DeviceID           = $deviceId
                Size               = $_.Size
                FreeSpace          = $_.FreeSpace
                VolumeSerialNumber = $_.VolumeSerialNumber
                VolumeGuid         = Get-DiskPulseDriveVolumeGuid ($deviceId + '\')
                DosDeviceTarget     = Get-DiskPulseDosDeviceTarget $deviceId
            }
        } |
        Sort-Object DeviceID
}
catch {
    Write-Warning "CIM disk query failed, using DriveInfo fallback."
    $drives = [System.IO.DriveInfo]::GetDrives() |
        Where-Object { $_.DriveType -eq [System.IO.DriveType]::Fixed -and $_.IsReady } |
        ForEach-Object {
            [PSCustomObject]@{
                DeviceID           = $_.Name.TrimEnd('\')
                Size               = $_.TotalSize
                FreeSpace          = $_.AvailableFreeSpace
                VolumeSerialNumber = Get-DiskPulseDriveVolumeSerial $_.Name
                VolumeGuid         = Get-DiskPulseDriveVolumeGuid $_.Name
                DosDeviceTarget     = Get-DiskPulseDosDeviceTarget $_.Name
            }
        } |
        Sort-Object DeviceID
}
# A drive letter created with SUBST (or another mount alias) can be reported as a fixed drive.
# De-duplicate only when Windows resolved two letters to the same Volume GUID. If identity lookup
# fails, keep the drive: avoiding a false omission is more important than guessing an alias.
$driveSelection = Select-DiskPulseScannableDrives -Drives $drives
$drives = @($driveSelection.Drives)
$skippedDriveAliases = @($driveSelection.Aliases)
foreach ($alias in $skippedDriveAliases) {
    Write-Warning "Drive $($alias.id) resolves to the same volume as $($alias.aliasOf); skipping it so its capacity is not counted twice."
}
Profile-Mark "diskQuery"
$currentResults = [System.Collections.Generic.List[PSObject]]::new()
$notifiedIds = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)

foreach ($d in $drives) {
    $id      = $d.DeviceID -replace '\\',''
    $total   = [math]::Round($d.Size      / 1GB, 2)
    $free    = [math]::Round($d.FreeSpace / 1GB, 2)
    $used    = [math]::Round($total - $free, 2)
    $percent = if ($total -gt 0) { [math]::Round(($used / $total) * 100, 1) } else { 0 }
    $lastUsed = if ($previousById.ContainsKey($d.DeviceID)) { [double]$previousById[$d.DeviceID].Used } else { $used }
    $diff    = [math]::Round($used - $lastUsed, 2)
    $status  = if ($percent -ge 90) { "critical" } elseif ($percent -ge 75) { "warning" } else { "good" }

    if ($status -eq "critical" -and $notifiedIds.Add($d.DeviceID)) {
        try {
            Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
            Add-Type -AssemblyName System.Drawing -ErrorAction SilentlyContinue
            $balloon = New-Object System.Windows.Forms.NotifyIcon
            $balloon.Icon = [System.Drawing.SystemIcons]::Warning
            $balloon.Visible = $true
            $balloon.ShowBalloonTip(10000, "DiskPulse", "$($id) 使用率 $percent%，仅剩 $free GB", [System.Windows.Forms.ToolTipIcon]::Warning)
            Start-Sleep -Milliseconds 500
            $balloon.Dispose()
        } catch {}
    }

    $currentResults.Add([PSCustomObject]@{
        id      = $id
        total   = $total
        free    = $free
        used    = $used
        percent = $percent
        diff    = $diff
        status  = $status
    })

    $prev = if ($previousById.ContainsKey($d.DeviceID)) { $previousById[$d.DeviceID] } else { $null }
    $isDup = $prev -and
        ([math]::Abs([double]$prev.Total - $total) -lt 0.01) -and
        ([math]::Abs([double]$prev.Free - $free) -lt 0.01) -and
        ([math]::Abs([double]$prev.Percent - $percent) -lt 0.1)
    if (-not $isDup) {
        $historyRows.Add((New-HistoryRow -Timestamp $timestamp -ID $d.DeviceID -Total $total -Free $free -Used $used -Percent $percent))
    }
}

$priorSnapshots = Read-Snapshots $paths
Profile-Mark "readSnapshots"
$snapshotDrives = New-Object 'Collections.Generic.List[object]'
$completedDrives = 0
$totalDrives = @($drives).Count
& $publishProgress 'running' 'init' '' $null $true
foreach ($d in $drives) {
    $scanStage = "扫描磁盘 $($d.DeviceID)"
    $progressStage = "scan"
    $progressDrive = $d.DeviceID
    $capacity = $currentResults | Where-Object { $_.id -eq ($d.DeviceID -replace '\\','') } | Select-Object -First 1
    $consoleProgress = {
        param($progress)
        & $publishProgress 'running' 'scan' ([string]$progress.drive) $progress $false
        if ($silent) { return }
        if (-not (Should-RenderConsoleProgress -Progress $progress -State $consoleProgressState)) { return }
        $line = Format-ScanProgressLine -Progress $progress -CompletedDrives $completedDrives -TotalDrives $totalDrives
        $width = [math]::Max($line.Length, $consoleProgressState.LastLength)
        Write-Host ("`r" + $line.PadRight($width)) -NoNewline
        $consoleProgressState.LastLength = $line.Length
        $consoleProgressState.Active = $true
    }
    Profile-Mark "scan:$($d.DeviceID)"
    $scan = Invoke-DirectoryScan -Drive $d.DeviceID -RootPath ($d.DeviceID + '\') -ProgressCallback $consoleProgress
    Profile-Mark "scanDone:$($d.DeviceID)"
    $completedDrives++
    & $publishProgress 'running' 'scan' $d.DeviceID $null $true
    $consoleProgressState.LastRenderedMilliseconds = -1
    $priorComplete = $priorSnapshots | Where-Object { @($_.drives | Where-Object { $_.drive -eq $d.DeviceID -and $_.status -in @('baseline','complete') }).Count } | Select-Object -First 1
    if ($scan.status -eq 'complete' -and -not $priorComplete) { $scan.status = 'baseline' }
    $scan | Add-Member totalBytes ([int64]$d.Size)
    $scan | Add-Member freeBytes ([int64]$d.FreeSpace)
    $scan | Add-Member usedBytes ([int64]($d.Size - $d.FreeSpace))
    $snapshotDrives.Add($scan)
}
$completedAt = (Get-Date).ToUniversalTime().ToString('o')
$progressStage = "report"
& $publishProgress 'running' 'report' $progressDrive $null $true
$snapshot = [PSCustomObject]@{
    scanId = $scanId
    startedAt = $startedAt
    completedAt = $completedAt
    status = if (@($snapshotDrives | Where-Object { $_.status -eq 'failed' }).Count -eq $snapshotDrives.Count) { 'failed' } elseif (@($snapshotDrives | Where-Object { $_.status -in @('partial','failed') }).Count) { 'partial' } else { 'complete' }
    drives = [object[]]$snapshotDrives
}
$snapshotPath = Join-Path $paths.Snapshots ($scanId + '.json')
if (@($snapshotDrives | Where-Object { $_.status -ne 'failed' }).Count) {
    Write-AtomicJson $snapshotPath $snapshot | Out-Null
}
$reportStopwatch = [Diagnostics.Stopwatch]::StartNew()
Profile-Mark "reportStart"
$directoryResults = New-Object 'Collections.Generic.List[object]'
foreach ($driveSnapshot in $snapshot.drives) {
    $baselineSnapshot = Find-DriveBaseline -Snapshots @($priorSnapshots) -Drive $driveSnapshot.drive -Current $snapshot
    $baselineDrive = if ($baselineSnapshot) { $baselineSnapshot.drives | Where-Object drive -eq $driveSnapshot.drive | Select-Object -First 1 } else { $null }
    $changes = Compare-DriveRecords $driveSnapshot $baselineDrive
    $directoryResults.Add([PSCustomObject]@{ drive=$driveSnapshot.drive; status=$driveSnapshot.status; baselineScanId=if($baselineSnapshot){$baselineSnapshot.scanId}else{$null}; baselineCompletedAt=if($baselineSnapshot){$baselineSnapshot.completedAt}else{$null}; changes=$changes; coverage=Get-ChangeCoverage $driveSnapshot $baselineDrive $changes; errors=$driveSnapshot.errors; unavailable=$driveSnapshot.unavailable; excluded=$driveSnapshot.excluded })
}
Profile-Mark "compareRecords"
$historyCenter = New-HistoryComparisonCenter -Snapshots @($priorSnapshots) -Current $snapshot
Profile-Mark "historyCenter"
Invoke-SnapshotRetention $paths (@($priorSnapshots)+@($snapshot)) @($snapshot.drives.drive) $scanId
Profile-Mark "snapshotRetention"

$aiPlan = Get-DiskPulseAIAnalysisState -DirectoryResults $directoryResults -HistoryCenter $historyCenter -Snapshot $snapshot
# AI input construction is decoupled from whether an API is configured: the same canonical
# redacted payload powers both the manual "copy to AI" fallback and the automatic API worker.
$aiInputEligible = Test-DiskPulseAIInputEligible -DirectoryResults $directoryResults
$copyInput = if ($aiPlan.ready -and $null -ne $aiPlan.input) { $aiPlan.input } elseif ($aiInputEligible) { New-DiskPulseAIInput -DirectoryResults $directoryResults -HistoryCenter $historyCenter -Snapshot $snapshot } else { $null }
$copyText = if ($copyInput) { New-DiskPulseAICopyText -AIInput $copyInput } else { '' }
$analysisId = [guid]::NewGuid().ToString('N')
$aiWorkerInputPath = Join-Path $paths.Runtime ("ai-input-{0}-{1}.json" -f $scanId,$analysisId)
$aiOutputPath = Join-Path $paths.Runtime 'last-ai-analysis.json'
$aiAnalysisResult = if ($aiPlan.ready) {
    [PSCustomObject]@{ status = 'analyzing'; format = 'none'; analysis = $null; rawText = $null; model = [string]$aiPlan.model; scanId = $scanId; analysisId = $analysisId; generatedAt = ''; error = $null }
} else {
    [PSCustomObject]@{ status = [string]$aiPlan.status; format = 'none'; analysis = $null; rawText = $null; model = [string]$aiPlan.model; scanId = $scanId; analysisId = $analysisId; generatedAt = ''; error = $null }
}

$historyRows = [System.Collections.Generic.List[PSObject]](($historyRows |
    Sort-Object Timestamp -Descending |
    Select-Object -First $maxHistoryRows |
    Sort-Object Timestamp))
Profile-Mark "historySort"

Invoke-DiskPulsePublication $paths.Runtime { Write-DiskPulseAtomicCsv -FinalPath $logFile -Rows $historyRows }
Profile-Mark "csvExport"

$jsonArray = ConvertTo-JsonArray $currentResults
Profile-Mark "json:DATA"
$historyJson = ConvertTo-JsonArray $historyRows
Profile-Mark "json:HISTORY"
$directoryJson = ConvertTo-JsonArray ([object[]]$directoryResults)
Profile-Mark "json:DIRECTORY"
$historyCenterJson = ConvertTo-JsonArray ([object[]]$historyCenter)
Profile-Mark "json:HISTORY_CENTER"
$scanMetaJson = New-DiskPulseScanMetaJson -Snapshot $snapshot -DriveAliases $skippedDriveAliases
$timestampJson = ConvertTo-Json -InputObject ([string]$timestamp) -Compress
$systemDriveJson = ConvertTo-Json -InputObject ([string]$env:SystemDrive) -Compress
$aiAnalysisJson = if ($aiAnalysisResult) { ConvertTo-DiskPulseSafeJSON $aiAnalysisResult } else { '{}' }
$brandAssetPath = Join-Path $paths.Root 'assets\DiskPulse-dashboard.png'
if (-not (Test-Path -LiteralPath $brandAssetPath)) { throw "图标文件不存在：$brandAssetPath" }
$brandDataUri = 'data:image/png;base64,' + [Convert]::ToBase64String([IO.File]::ReadAllBytes($brandAssetPath))
Profile-Mark "json:META"
if ([string]::IsNullOrWhiteSpace($jsonArray)) { $jsonArray = "[]" }
if ([string]::IsNullOrWhiteSpace($historyJson)) { $historyJson = "[]" }

$html = @'
__DISKPULSE_DASHBOARD__
'@
Profile-Mark "htmlTemplate"

$replacementMap = @{
    INJECT_DATA = $jsonArray
    INJECT_HISTORY = $historyJson
    INJECT_DIRECTORY = $directoryJson
    INJECT_HISTORY_CENTER = $historyCenterJson
    INJECT_SCAN_META = $scanMetaJson
    INJECT_TS_JSON = $timestampJson
    INJECT_SYSTEM_DRIVE = $systemDriveJson
    INJECT_AI_ANALYSIS = $aiAnalysisJson
    INJECT_AI_COPY_TEXT = if ($copyText) { ConvertTo-DiskPulseSafeJSON $copyText } else { '""' }
    INJECT_BRAND_DATA_URI = $brandDataUri
}
$placeholderPattern = 'INJECT_(?:AI_ANALYSIS|AI_COPY_TEXT|HISTORY_CENTER|BRAND_DATA_URI|SYSTEM_DRIVE|SCAN_META|TS_JSON|DIRECTORY|HISTORY|DATA)'
$html = [regex]::Replace($html, $placeholderPattern, { param($match) [string]$replacementMap[$match.Value] })
Profile-Mark "htmlReplace"

$utf8NoBom = New-Object System.Text.UTF8Encoding $false
Invoke-DiskPulsePublication $paths.Runtime {
    Write-DiskPulseAtomicText -FinalPath (Join-Path $paths.Runtime 'ai-current.json') -Content (ConvertTo-Json @{scanId=$scanId;analysisId=$analysisId})
    Write-DiskPulseAtomicText -FinalPath $htmlFile -Content $html
    Write-DiskPulseAtomicText -FinalPath $aiOutputPath -Content (ConvertTo-Json -InputObject $aiAnalysisResult -Depth 12)
    $liveProbePath = Join-Path $paths.Runtime ("ai-live-{0}-{1}.js" -f $scanId,$analysisId)
    if ($aiPlan.ready) { Write-DiskPulseAILiveProbe -ScanId $scanId -LivePath $liveProbePath -Result $aiAnalysisResult }
    Write-ScanEvent $paths ([PSCustomObject]@{
        scanId=$scanId; status=$snapshot.status; startedAt=$startedAt
        completedAt=(Get-Date).ToUniversalTime().ToString('o')
    })
    Compact-ScanEvents $paths
}
Profile-Mark "htmlWrite"
$progressStage = "report"
& $publishProgress 'complete' 'report' $progressDrive $null $true
$reportStopwatch.Stop()
$scanStage = "生成报告"
if ($env:DISKPULSE_NO_OPEN -ne "1") {
    try { Start-Process $htmlFile } catch { Write-Warning "Generated $htmlFile. Open it manually." }
}
Profile-Mark "browserOpen"
Profile-Mark "aiAnalysis"
Release-DiskPulseLock $paths $owner
$owner = $null

if ($aiPlan.ready) {
    try {
        $aiInputPayload = [PSCustomObject]@{
            scanId       = $scanId
            analysisId   = $analysisId
            outputPath   = $aiOutputPath
            tempOutputPath = ($aiOutputPath + '.' + $scanId + '.' + $analysisId + '.tmp')
            model        = [string]$aiPlan.model
            aiInput      = $aiPlan.input
        }
        Write-DiskPulseAtomicText -FinalPath $aiWorkerInputPath -Content (ConvertTo-Json -InputObject $aiInputPayload -Depth 12)
        $workerScriptPath = if ([string]::IsNullOrWhiteSpace($env:DISKPULSE_SCRIPT_PATH)) { Join-Path $paths.Root 'check.bat' } else { $env:DISKPULSE_SCRIPT_PATH }
        Start-DiskPulseAIWorker -ScriptPath $workerScriptPath -RootPath $paths.Root -ScanId $scanId -InputPath $aiWorkerInputPath -OutputPath $aiOutputPath -HtmlPath $htmlFile
    }
    catch {
        $aiAnalysisResult = [PSCustomObject]@{ status = 'unknown-error'; format = 'none'; analysis = $null; rawText = $null; model = [string]$aiPlan.model; scanId = $scanId; analysisId = $analysisId; generatedAt = (Get-Date).ToUniversalTime().ToString('o'); error = $null }
        Submit-DiskPulseAIResult -Paths $paths -HtmlPath $htmlFile -Result $aiAnalysisResult | Out-Null
        if (Test-Path -LiteralPath $aiWorkerInputPath) { Remove-Item -LiteralPath $aiWorkerInputPath -Force }
    }
}
$runStopwatch.Stop()
& $clearConsoleProgress
if (-not $silent) {
    Write-Host ("扫描完成：{0:N1} 秒" -f $runStopwatch.Elapsed.TotalSeconds)
    Write-Host ("报告生成：{0:N3} 秒，{1:N0} 字节" -f $reportStopwatch.Elapsed.TotalSeconds, ([Text.Encoding]::UTF8.GetByteCount($html)))
    Write-Host "报告位置：$htmlFile"
    foreach ($driveResult in $snapshot.drives) {
        Write-Host ("{0} 无法访问 {1} 个路径，主动排除 {2} 个路径" -f $driveResult.drive, @($driveResult.unavailable).Count, @($driveResult.excluded).Count)
    }
}
if ($profileMode) {
    Profile-Mark "total"
    $profileResult = [ordered]@{ totalMs = $runStopwatch.ElapsedMilliseconds }
    $prevMs = 0
    foreach ($mark in $script:profileMarks) {
        $elapsed = $mark.ms - $prevMs
        $profileResult[$mark.key] = $elapsed
        $prevMs = $mark.ms
    }
    Ensure-Directory $paths.Runtime
    $profilePath = Join-Path $paths.Runtime 'last-profile.json'
    $profileResult | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $profilePath -Encoding UTF8 -Force
}
}
catch {
$runStopwatch.Stop()
& $clearConsoleProgress
& $publishProgress 'failed' $progressStage $progressDrive $null $true
if ($profileMode) {
    Profile-Mark "failed:$scanStage"
    try {
        $logRoot = if ($paths -and $paths.PSObject.Properties.Name -contains 'Runtime') {
            $paths.Runtime
        } else {
            Join-Path ([string]$env:DISKPULSE_ROOT) 'runtime'
        }
        [IO.Directory]::CreateDirectory($logRoot) | Out-Null
        $profilePath = Join-Path $logRoot 'last-profile.json'
        $profileResult = [ordered]@{ totalMs = $runStopwatch.ElapsedMilliseconds }
        $prevMs = 0
        foreach ($mark in $script:profileMarks) {
            $profileResult[$mark.key] = $mark.ms - $prevMs
            $prevMs = $mark.ms
        }
        $profileResult | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $profilePath -Encoding UTF8 -Force
    } catch {}
}
$errorMessage = "扫描失败：$scanStage`n已用时间：{0:N1} 秒`n错误：{1}" -f $runStopwatch.Elapsed.TotalSeconds, $_.Exception.Message
if ($silent) {
    try {
        $logRoot = if ($paths -and $paths.PSObject.Properties.Name -contains 'Runtime') {
            $paths.Runtime
        } else {
            Join-Path ([string]$env:DISKPULSE_ROOT) 'runtime'
        }
        [IO.Directory]::CreateDirectory($logRoot) | Out-Null
        $logPath = Join-Path $logRoot 'last-run.log'
        "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $errorMessage" |
            Add-Content -LiteralPath $logPath -Encoding UTF8
    } catch {}
} else {
    Write-Host "扫描失败：$scanStage" -ForegroundColor Red
    Write-Host ("已用时间：{0:N1} 秒" -f $runStopwatch.Elapsed.TotalSeconds)
    Write-Host "错误：$($_.Exception.Message)" -ForegroundColor Red
}
    if ($owner) { try {
        Write-ScanEvent $paths ([PSCustomObject]@{
            scanId = $scanId
            status = "failed"
            startedAt = $startedAt
            completedAt = (Get-Date).ToUniversalTime().ToString("o")
            reason = $_.Exception.Message
        })
        Compact-ScanEvents $paths
    } catch {} }
    throw
}
finally {
    & $clearConsoleProgress
}
} finally { if ($owner) { Release-DiskPulseLock $paths $owner } }
}

if ($env:DISKPULSE_MIGRATE -eq '1') {
    $migrationPaths = Get-DiskPulsePaths
    Invoke-DiskPulseMigration -Paths $migrationPaths -Sources @($env:DISKPULSE_MIGRATION_SOURCES -split "`n") -MarkerPath (Join-Path (Split-Path -Parent $migrationPaths.Runtime) 'migration-sources.txt')
    return
}

if ($env:DISKPULSE_AI_WORKER -eq "1") {
    Invoke-DiskPulseAIWorker
    return
}

if ($env:DISKPULSE_TEST_MODE -ne "1") {
    if ($env:DISKPULSE_AI_CONFIGURE -eq "1") {
        try { Invoke-DiskPulseAIConfigure }
        catch { Write-Host "AI configuration failed: $($_.Exception.Message)" -ForegroundColor Red }
    }
    else {
        Invoke-DiskPulse
    }
}
