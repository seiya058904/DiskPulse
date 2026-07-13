<# :
@echo off
setlocal
chcp 65001 >nul
set "DISKPULSE_SCRIPT_PATH=%~f0"
set "DISKPULSE_ROOT=%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -Command "Get-Content -Raw -LiteralPath $env:DISKPULSE_SCRIPT_PATH -Encoding UTF8 | Invoke-Expression"
exit /b %ERRORLEVEL%
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-DiskPulsePaths {
    $root = [IO.Path]::GetFullPath([string]$env:DISKPULSE_ROOT)
    $runtime = Join-Path $root "runtime"
    [PSCustomObject]@{
        Root     = $root
        Runtime  = $runtime
        Legacy   = Join-Path $runtime "legacy"
        Snapshots = Join-Path $runtime "snapshots"
        Events   = Join-Path $runtime "scans.jsonl"
        Lock     = Join-Path $runtime "DiskPulse.lock"
    }
}

function Ensure-Directory {
    param([string] $Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        [IO.Directory]::CreateDirectory($Path) | Out-Null
    }
}

function ConvertTo-JsonArray {
    param($Value)
    ConvertTo-Json -InputObject @($Value) -Depth 12 -Compress
}

function New-ScanId {
    "{0}-{1}" -f (Get-Date -Format "yyyyMMdd-HHmmss-fff"), ([guid]::NewGuid().ToString("N").Substring(0, 6))
}

function Copy-LegacyHistory {
    param($Paths)
    $source = Join-Path $Paths.Root "DiskPulse.csv"
    $target = Join-Path $Paths.Legacy "DiskPulse-v1.csv"
    $marker = Join-Path $Paths.Runtime ".legacy-imported"
    if ((Test-Path -LiteralPath $source) -and -not (Test-Path -LiteralPath $marker)) {
        Copy-Item -LiteralPath $source -Destination $target -ErrorAction Stop
        Import-Csv -LiteralPath $target | Out-Null
        Set-Content -LiteralPath $marker -Value "ok" -Encoding UTF8
    }
    return $target
}

function Test-LockOwner {
    param($Lock)
    try {
        $process = Get-Process -Id ([int]$Lock.pid) -ErrorAction Stop
        $started = $process.StartTime.ToUniversalTime().ToString("o")
        return ($process.ProcessName -match "^(powershell|pwsh)$") -and
            ($started -eq [string]$Lock.processStartedAt)
    }
    catch {
        return $false
    }
}

function Acquire-DiskPulseLock {
    param($Paths, [string] $ScanId)
    $process = Get-Process -Id $PID
    $owner = [PSCustomObject]@{
        pid              = $PID
        processName      = $process.ProcessName
        processStartedAt = $process.StartTime.ToUniversalTime().ToString("o")
        scanId           = $ScanId
    }
    for ($attempt = 0; $attempt -lt 2; $attempt++) {
        try {
            $stream = [IO.File]::Open($Paths.Lock, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
            try {
                $bytes = [Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $owner -Depth 12 -Compress))
                $stream.Write($bytes, 0, $bytes.Length)
            }
            finally {
                $stream.Dispose()
            }
            return $owner
        }
        catch [IO.IOException] {
            try {
                $existing = Get-Content -Raw -LiteralPath $Paths.Lock -Encoding UTF8 | ConvertFrom-Json
            }
            catch {
                $existing = $null
            }
            if ($existing -and (Test-LockOwner $existing)) {
                throw "DiskPulse 正在运行，请勿重复启动。"
            }
            if (Test-Path -LiteralPath $Paths.Lock) {
                Remove-Item -LiteralPath $Paths.Lock -Force
            }
        }
    }
    throw "无法取得 DiskPulse 运行锁。"
}

function Release-DiskPulseLock {
    param($Paths, $Owner)
    if (-not (Test-Path -LiteralPath $Paths.Lock)) { return }
    try {
        $actual = Get-Content -Raw -LiteralPath $Paths.Lock -Encoding UTF8 | ConvertFrom-Json
        if ([int]$actual.pid -eq $PID -and [string]$actual.scanId -eq [string]$Owner.scanId) {
            Remove-Item -LiteralPath $Paths.Lock -Force
        }
    }
    catch {
        Write-Warning "无法验证或释放 DiskPulse 运行锁。"
    }
}

function Write-ScanEvent {
    param($Paths, $Event)
    Add-Content -LiteralPath $Paths.Events -Value (ConvertTo-Json -InputObject $Event -Depth 12 -Compress) -Encoding UTF8
}

function Write-AtomicJson {
    param([string] $FinalPath, $Value)
    $temporaryPath = [IO.Path]::ChangeExtension($FinalPath, ".tmp")
    if (Test-Path -LiteralPath $FinalPath) {
        throw "目标 JSON 已存在：$FinalPath"
    }
    $json = ConvertTo-Json -InputObject $Value -Depth 12 -Compress
    [IO.File]::WriteAllText($temporaryPath, $json, (New-Object Text.UTF8Encoding $false))
    Get-Content -Raw -LiteralPath $temporaryPath -Encoding UTF8 | ConvertFrom-Json | Out-Null
    [IO.File]::Move($temporaryPath, $FinalPath)
    return $FinalPath
}

function Normalize-PathKey {
    param([string] $Path)
    [IO.Path]::GetFullPath($Path).Replace('/', '\').TrimEnd('\').ToLowerInvariant()
}

function New-DirectoryRecord {
    param([string] $Path, [int] $Level)
    [PSCustomObject]@{
        key                         = Normalize-PathKey $Path
        kind                        = "directory"
        displayPath                 = [IO.Path]::GetFullPath($Path).TrimEnd('\')
        level                       = $Level
        sizeBytes                   = [int64]0
        fileCount                   = 0
        latestWriteTime             = $null
        enumerationComplete         = $true
        childrenEnumerationComplete = $true
    }
}

function New-RootFilesRecord {
    param([string] $Drive, [string] $RootPath)
    [PSCustomObject]@{
        key                         = $Drive.ToUpperInvariant() + "|root-files"
        kind                        = "rootFiles"
        displayPath                 = $Drive.ToUpperInvariant() + "\（根目录文件）"
        path                        = [IO.Path]::GetFullPath($RootPath)
        level                       = 1
        sizeBytes                   = [int64]0
        fileCount                   = 0
        latestWriteTime             = $null
        enumerationComplete         = $true
        childrenEnumerationComplete = $true
    }
}

function Add-FileAggregate {
    param($Record, [IO.FileInfo] $File)
    $Record.sizeBytes += [int64]$File.Length
    $Record.fileCount++
    $writeTime = $File.LastWriteTimeUtc.ToString("o")
    if (-not $Record.latestWriteTime -or [datetime]$writeTime -gt [datetime]$Record.latestWriteTime) {
        $Record.latestWriteTime = $writeTime
    }
}

function Invoke-DirectoryScan {
    param([string] $Drive, [string] $RootPath, [scriptblock] $BeforeEntry)

    $root = [IO.Path]::GetFullPath($RootPath).TrimEnd('\')
    $rootPrefix = $root + '\'
    $records = New-Object 'Collections.Generic.Dictionary[string,object]' ([StringComparer]::OrdinalIgnoreCase)
    $errors = New-Object 'Collections.Generic.List[object]'
    $unavailable = New-Object 'Collections.Generic.List[object]'
    $excluded = New-Object 'Collections.Generic.List[object]'
    $rootFiles = New-RootFilesRecord $Drive $root
    $records[$rootFiles.key] = $rootFiles
    $stack = New-Object 'Collections.Generic.Stack[string]'
    $stack.Push($root)
    $status = "complete"

    while ($stack.Count -gt 0) {
        $directory = $stack.Pop()
        try {
            $entries = [IO.DirectoryInfo]::new($directory).EnumerateFileSystemInfos()
            foreach ($entry in $entries) {
                try {
                    if ($BeforeEntry) { & $BeforeEntry $entry }
                    $entry.Refresh()
                    if (-not $entry.Exists) { throw "Entry disappeared during scan." }
                    if (($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                        $excluded.Add([PSCustomObject]@{ path = $entry.FullName; reason = "reparse-point" })
                        continue
                    }

                    $relative = $entry.FullName.Substring($rootPrefix.Length)
                    $parts = @($relative.Split([IO.Path]::DirectorySeparatorChar, [StringSplitOptions]::RemoveEmptyEntries))
                    if ($entry -is [IO.DirectoryInfo]) {
                        if ($entry.Name -in @("System Volume Information", '$RECYCLE.BIN')) {
                            $excluded.Add([PSCustomObject]@{ path = $entry.FullName; reason = "configured-exclusion" })
                            continue
                        }
                        for ($level = 1; $level -le [math]::Min(2, $parts.Count); $level++) {
                            $path = Join-Path $root ($parts[0..($level - 1)] -join '\')
                            $key = Normalize-PathKey $path
                            if (-not $records.ContainsKey($key)) {
                                $records[$key] = New-DirectoryRecord $path $level
                            }
                        }
                        $stack.Push($entry.FullName)
                        continue
                    }

                    if ($parts.Count -eq 1) {
                        Add-FileAggregate $rootFiles $entry
                    }
                    else {
                        for ($level = 1; $level -le [math]::Min(2, $parts.Count - 1); $level++) {
                            $path = Join-Path $root ($parts[0..($level - 1)] -join '\')
                            Add-FileAggregate $records[(Normalize-PathKey $path)] $entry
                        }
                    }
                }
                catch {
                    $status = "partial"
                    $errors.Add([PSCustomObject]@{ path = [string]$entry.FullName; reason = $_.Exception.Message; kind = "entry-disappeared" })
                    $unavailable.Add([PSCustomObject]@{ path = [string]$entry.FullName; reason = "entry-unavailable" })
                }
            }
        }
        catch {
            $errors.Add([PSCustomObject]@{ path = $directory; reason = $_.Exception.Message; kind = "enumeration-failed" })
            $unavailable.Add([PSCustomObject]@{ path = $directory; reason = "enumeration-failed" })
            if ($directory -eq $root) {
                $status = "failed"
                $rootFiles.enumerationComplete = $false
                $rootFiles.childrenEnumerationComplete = $false
                break
            }
            $status = "partial"
            foreach ($record in $records.Values) {
                if ($record.kind -eq "directory" -and $directory.StartsWith($record.displayPath, [StringComparison]::OrdinalIgnoreCase)) {
                    $record.childrenEnumerationComplete = $false
                }
            }
        }
    }

    $recordValues = [object[]]$records.Values
    $excludedValues = [object[]]$excluded
    $unavailableValues = [object[]]$unavailable
    $errorValues = [object[]]$errors
    [PSCustomObject]@{
        drive                       = $Drive.ToUpperInvariant()
        rootPath                    = $root
        status                      = $status
        enumerationComplete         = ($status -eq "complete")
        childrenEnumerationComplete = ($status -eq "complete")
        records                     = $recordValues
        excluded                    = $excludedValues
        unavailable                 = $unavailableValues
        errors                      = $errorValues
    }
}

function Read-Snapshots {
    param($Paths)
    $finalStatus = @{}
    if (Test-Path -LiteralPath $Paths.Events) {
        Get-Content -LiteralPath $Paths.Events -Encoding UTF8 | Where-Object { $_.Trim() } | ForEach-Object {
            try { $event = $_ | ConvertFrom-Json; $finalStatus[[string]$event.scanId] = [string]$event.status } catch {}
        }
    }
    @((Get-ChildItem -LiteralPath $Paths.Snapshots -Filter '*.json' -File -ErrorAction SilentlyContinue | ForEach-Object {
        try {
            $snapshot = Get-Content -Raw -LiteralPath $_.FullName -Encoding UTF8 | ConvertFrom-Json
            if ($finalStatus[[string]$snapshot.scanId] -in @('complete','partial')) { $snapshot }
        }
        catch { Write-Warning "无法读取快照 $($_.Name)" }
    }))
}

function Find-DriveBaseline {
    param([array]$Snapshots,[string]$Drive,$Current)
    if (-not $Snapshots -or $Snapshots.Count -eq 0) { return $null }
    $Snapshots | Where-Object {
        $_.scanId -ne $Current.scanId -and [datetime]$_.completedAt -lt [datetime]$Current.startedAt -and
        @($_.drives | Where-Object { $_.drive -eq $Drive -and $_.status -in @('baseline','complete') }).Count
    } | Sort-Object { [datetime]$_.completedAt } -Descending | Select-Object -First 1
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
    $top=@($Rows|Where-Object{$_.level-eq 1});[int64]$added=0;[int64]$released=0;[int64]$located=0
    foreach($r in $top){$located+=[int64]$r.deltaBytes;if($r.deltaBytes-gt 0){$added+=[int64]$r.deltaBytes}elseif($r.deltaBytes-lt 0){$released+=[math]::Abs([int64]$r.deltaBytes)}}
    $actual=if($Baseline){[int64]$Current.usedBytes-[int64]$Baseline.usedBytes}else{[int64]0}
    $rate=if([math]::Abs($actual)-lt 1){0}else{[math]::Max(0,[math]::Min(100,[math]::Round(([math]::Abs($located)/[math]::Abs($actual))*100,1)))}
    [pscustomobject]@{addedBytes=$added;releasedBytes=$released;locatedNetBytes=$located;actualNetBytes=$actual;unexplainedBytes=$actual-$located;rate=$rate;activityPreferred=([math]::Abs($actual)-lt 1-or[math]::Sign($actual)-ne[math]::Sign($located)-or($added-gt 0-and$released-gt 0))}
}

function Complete-InterruptedScans {
    param($Paths)
    if(-not(Test-Path -LiteralPath $Paths.Events)){return}
    $latest=@{};Get-Content -LiteralPath $Paths.Events -Encoding UTF8|Where-Object{$_.Trim()}|ForEach-Object{try{$e=$_|ConvertFrom-Json;$latest[[string]$e.scanId]=$e}catch{}}
    foreach($e in $latest.Values){if($e.status-eq'running'){Write-ScanEvent $Paths ([pscustomobject]@{scanId=$e.scanId;status='failed';reason='interrupted';completedAt=(Get-Date).ToUniversalTime().ToString('o')})}}
}

function Remove-StaleTemporaryFiles {
    param($Paths)
    $cutoff=(Get-Date).AddHours(-24);foreach($file in Get-ChildItem -LiteralPath $Paths.Snapshots -Filter '*.tmp' -File -ErrorAction SilentlyContinue){if($file.LastWriteTime-lt$cutoff){try{Remove-Item -LiteralPath $file.FullName -Force}catch{Write-Warning "无法清理临时文件 $($file.Name)"}}}
}

function Invoke-SnapshotRetention {
    param($Paths,[array]$Snapshots,[array]$CurrentDrives,[string]$CurrentScanId,[int]$Limit=30)
    $protected=@{$CurrentScanId=$true};foreach($drive in $CurrentDrives){$Snapshots|Where-Object{@($_.drives|Where-Object{$_.drive-eq$drive-and$_.status-in@('baseline','complete')}).Count}|Sort-Object{[datetime]$_.completedAt}-Descending|Select-Object -First 2|ForEach-Object{$protected[[string]$_.scanId]=$true}}
    $files=@(Get-ChildItem -LiteralPath $Paths.Snapshots -Filter '*.json' -File|ForEach-Object{$s=try{Get-Content -Raw $_.FullName -Encoding UTF8|ConvertFrom-Json}catch{$null};if($s){[pscustomobject]@{File=$_;Snapshot=$s;Partial=(@($s.drives|Where-Object{$_.status-eq'partial'}).Count-gt 0)}}})
    foreach($candidate in @($files|Where-Object{-not$protected.ContainsKey([string]$_.Snapshot.scanId)}|Sort-Object @{e='Partial';Descending=$true},@{e={$_.Snapshot.completedAt};Ascending=$true})){if($files.Count-le$Limit){break};try{Remove-Item -LiteralPath $candidate.File.FullName -Force;$files=@($files|Where-Object{$_.File.FullName-ne$candidate.File.FullName})}catch{Write-Warning "无法清理快照 $($candidate.File.Name)"}}
}

function Invoke-DiskPulse {
$paths = Get-DiskPulsePaths
Ensure-Directory $paths.Runtime
Ensure-Directory $paths.Legacy
Ensure-Directory $paths.Snapshots
Complete-InterruptedScans $paths
Remove-StaleTemporaryFiles $paths
$legacyFile = Copy-LegacyHistory $paths
$scanId = New-ScanId
$owner = Acquire-DiskPulseLock $paths $scanId
$startedAt = (Get-Date).ToUniversalTime().ToString("o")
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

$previousById = @{}
foreach ($row in ($historyRows | Sort-Object Timestamp)) {
    $previousById[$row.ID] = $row
}

$drives = @()
try {
    $drives = Get-CimInstance Win32_LogicalDisk |
        Where-Object { $_.DriveType -eq 3 } |
        Sort-Object DeviceID
}
catch {
    Write-Warning "CIM disk query failed, using DriveInfo fallback."
    $drives = [System.IO.DriveInfo]::GetDrives() |
        Where-Object { $_.DriveType -eq [System.IO.DriveType]::Fixed -and $_.IsReady } |
        ForEach-Object {
            [PSCustomObject]@{
                DeviceID  = $_.Name.TrimEnd('\')
                Size      = $_.TotalSize
                FreeSpace = $_.AvailableFreeSpace
            }
        } |
        Sort-Object DeviceID
}
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
$snapshotDrives = New-Object 'Collections.Generic.List[object]'
foreach ($d in $drives) {
    $capacity = $currentResults | Where-Object { $_.id -eq ($d.DeviceID -replace '\\','') } | Select-Object -First 1
    $scan = Invoke-DirectoryScan -Drive $d.DeviceID -RootPath ($d.DeviceID + '\')
    $priorComplete = $priorSnapshots | Where-Object { @($_.drives | Where-Object { $_.drive -eq $d.DeviceID -and $_.status -in @('baseline','complete') }).Count } | Select-Object -First 1
    if ($scan.status -eq 'complete' -and -not $priorComplete) { $scan.status = 'baseline' }
    $scan | Add-Member totalBytes ([int64]$d.Size)
    $scan | Add-Member freeBytes ([int64]$d.FreeSpace)
    $scan | Add-Member usedBytes ([int64]($d.Size - $d.FreeSpace))
    $snapshotDrives.Add($scan)
}
$completedAt = (Get-Date).ToUniversalTime().ToString('o')
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
$directoryResults = New-Object 'Collections.Generic.List[object]'
foreach ($driveSnapshot in $snapshot.drives) {
    $baselineSnapshot = Find-DriveBaseline -Snapshots @($priorSnapshots) -Drive $driveSnapshot.drive -Current $snapshot
    $baselineDrive = if ($baselineSnapshot) { $baselineSnapshot.drives | Where-Object drive -eq $driveSnapshot.drive | Select-Object -First 1 } else { $null }
    $changes = Compare-DriveRecords $driveSnapshot $baselineDrive
    $directoryResults.Add([PSCustomObject]@{ drive=$driveSnapshot.drive; status=$driveSnapshot.status; baselineScanId=if($baselineSnapshot){$baselineSnapshot.scanId}else{$null}; changes=$changes; coverage=Get-ChangeCoverage $driveSnapshot $baselineDrive $changes; errors=$driveSnapshot.errors; excluded=$driveSnapshot.excluded })
}
Invoke-SnapshotRetention $paths (@($priorSnapshots)+@($snapshot)) @($snapshot.drives.drive) $scanId

$historyRows = [System.Collections.Generic.List[PSObject]](($historyRows |
    Sort-Object Timestamp -Descending |
    Select-Object -First $maxHistoryRows |
    Sort-Object Timestamp))

$historyRows | Export-Csv $logFile -NoTypeInformation -Force -Encoding UTF8

$jsonArray = ConvertTo-JsonArray $currentResults
$historyJson = ConvertTo-JsonArray $historyRows
$directoryJson = ConvertTo-JsonArray ([object[]]$directoryResults)
if ([string]::IsNullOrWhiteSpace($jsonArray)) { $jsonArray = "[]" }
if ([string]::IsNullOrWhiteSpace($historyJson)) { $historyJson = "[]" }

$html = @'
<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>DiskPulse</title>
<style>
  *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }

  :root {
    --bg: #f4f6f8;
    --panel: #ffffff;
    --text: #202124;
    --muted: #70757a;
    --line: #dfe3e7;
    --track: #eef1f4;
    --blue: #2563eb;
    --green: #12805c;
    --orange: #b45309;
    --red: #c5221f;
  }

  [data-theme="dark"] {
    --bg: #1a1a2e;
    --panel: #16213e;
    --text: #e4e6eb;
    --muted: #8a8d91;
    --line: #3a3b3c;
    --track: #2d2d3d;
    --blue: #5b9cf5;
    --green: #4ade80;
    --orange: #f59e0b;
    --red: #ef4444;
    color-scheme: dark;
  }
  [data-theme="dark"] .badge { background: color-mix(in srgb, var(--accent) 20%, transparent); }
  [data-theme="dark"] .insight { background: var(--panel); }
  [data-theme="dark"] .mini { background: #1e2a3a; }
  [data-theme="dark"] .ring { background: conic-gradient(var(--blue) calc(var(--pct) * 1%), #2d2d3d 0); }
  [data-theme="dark"] .ring::after { background: var(--panel); }

  body {
    font-family: "Segoe UI", -apple-system, BlinkMacSystemFont, "Helvetica Neue", Arial, sans-serif;
    background: var(--bg);
    color: var(--text);
    min-height: 100vh;
    padding: 32px 20px 56px;
  }

  .shell {
    width: min(1120px, 100%);
    margin: 0 auto;
  }

  header {
    display: flex;
    justify-content: space-between;
    align-items: flex-end;
    gap: 24px;
    margin-bottom: 24px;
  }

  h1 {
    font-size: clamp(28px, 4vw, 44px);
    line-height: 1;
    letter-spacing: 0;
    font-weight: 800;
  }

  .eyebrow {
    color: var(--muted);
    font-size: 12px;
    font-weight: 700;
    letter-spacing: 1.4px;
    text-transform: uppercase;
    margin-bottom: 8px;
  }

  .timestamp {
    color: var(--muted);
    font-size: 13px;
    margin-top: 10px;
  }

  .actions {
    display: flex;
    align-items: center;
    justify-content: flex-end;
    gap: 10px;
    flex-wrap: wrap;
  }

  .search,
  .select,
  .button,
  .toggle {
    height: 38px;
    border: 1px solid var(--line);
    background: var(--panel);
    color: var(--text);
    border-radius: 8px;
    font: inherit;
    font-size: 13px;
  }

  .search {
    width: 190px;
    padding: 0 12px;
  }

  .select {
    padding: 0 34px 0 12px;
  }

  .button,
  .toggle {
    display: inline-flex;
    align-items: center;
    gap: 8px;
    padding: 0 12px;
    cursor: pointer;
    text-decoration: none;
  }

  .toggle input {
    accent-color: var(--blue);
  }

  .overview {
    display: grid;
    grid-template-columns: minmax(240px, 1.05fr) repeat(4, minmax(132px, .7fr));
    gap: 12px;
    margin-bottom: 16px;
  }

  .panel,
  .metric,
  .card {
    background: var(--panel);
    border: 1px solid rgba(32, 33, 36, .07);
    border-radius: 8px;
    box-shadow: 0 1px 2px rgba(32, 33, 36, .05);
  }

  .panel {
    padding: 18px;
    display: grid;
    grid-template-columns: 112px 1fr;
    gap: 18px;
    align-items: center;
  }

  .ring {
    width: 112px;
    aspect-ratio: 1;
    border-radius: 50%;
    display: grid;
    place-items: center;
    background: conic-gradient(var(--blue) calc(var(--pct) * 1%), #e6eaf0 0);
    position: relative;
  }

  .ring::after {
    content: "";
    position: absolute;
    inset: 11px;
    border-radius: 50%;
    background: var(--panel);
  }

  .ring span {
    position: relative;
    z-index: 1;
    font-size: 24px;
    font-weight: 800;
  }

  .overall-title {
    font-size: 17px;
    font-weight: 800;
    margin-bottom: 8px;
  }

  .overall-copy {
    color: var(--muted);
    font-size: 13px;
    line-height: 1.55;
  }

  .metric {
    padding: 16px;
    min-height: 116px;
  }

  .metric-label {
    color: var(--muted);
    font-size: 11px;
    font-weight: 800;
    letter-spacing: 1px;
    text-transform: uppercase;
  }

  .metric-value {
    font-size: 23px;
    font-weight: 800;
    margin: 11px 0 5px;
    line-height: 1.1;
  }

  .metric-note {
    color: var(--muted);
    font-size: 12px;
    line-height: 1.35;
  }

  .metric-prev {
    color: var(--orange);
    font-size: 13px;
    font-weight: 700;
    margin: 6px 0 4px;
  }

  .insights {
    display: grid;
    grid-template-columns: repeat(3, 1fr);
    gap: 12px;
    margin-bottom: 16px;
  }

  .insight {
    background: var(--panel);
    border-left: 4px solid var(--blue);
    border-radius: 8px;
    padding: 13px 14px;
    min-height: 76px;
  }

  .insight.warn { border-left-color: var(--orange); }
  .insight.critical { border-left-color: var(--red); }
  .insight.good { border-left-color: var(--green); }
  .insight-title {
    font-size: 12px;
    color: var(--muted);
    font-weight: 800;
    letter-spacing: .7px;
    text-transform: uppercase;
    margin-bottom: 7px;
  }
  .insight-body {
    font-size: 14px;
    line-height: 1.4;
    font-weight: 600;
  }

  .grid {
    display: grid;
    grid-template-columns: repeat(2, minmax(0, 1fr));
    gap: 14px;
  }

  .card {
    padding: 18px;
    --accent: var(--blue);
  }

  .card.critical { --accent: var(--red); }
  .card.warning { --accent: var(--orange); }
  .card.good { --accent: var(--green); }

  .card-top {
    display: flex;
    align-items: flex-start;
    justify-content: space-between;
    gap: 12px;
    margin-bottom: 14px;
  }

  .drive-name {
    font-size: 20px;
    font-weight: 800;
    letter-spacing: 0;
  }

  .drive-sub {
    color: var(--muted);
    font-size: 12px;
    margin-top: 3px;
  }

  .badge {
    border-radius: 999px;
    background: color-mix(in srgb, var(--accent) 12%, white);
    color: var(--accent);
    font-size: 12px;
    font-weight: 800;
    padding: 6px 10px;
    white-space: nowrap;
  }

  .bar-track {
    background: var(--track);
    height: 10px;
    border-radius: 999px;
    overflow: hidden;
    margin-bottom: 14px;
  }

  .bar-fill {
    height: 100%;
    border-radius: 999px;
    background: var(--accent);
    width: 0%;
    transition: width .7s cubic-bezier(.4, 0, .2, 1);
  }

  .meta {
    display: grid;
    grid-template-columns: repeat(3, 1fr);
    gap: 9px;
    margin-bottom: 14px;
  }

  .mini {
    background: var(--track);
    border-radius: 8px;
    padding: 9px 10px;
    min-width: 0;
  }

  .mini span {
    display: block;
    color: var(--muted);
    font-size: 11px;
    margin-bottom: 4px;
  }

  .mini b {
    font-size: 13px;
    font-weight: 800;
  }

  .mini small {
    display: block;
    color: var(--orange);
    font-size: 12px;
    font-weight: 700;
    margin-top: 6px;
    padding-top: 4px;
    border-top: 1px dashed var(--line);
  }

  .spark-row {
    display: grid;
    grid-template-columns: minmax(0, 1fr) auto;
    gap: 12px;
    align-items: center;
    color: var(--muted);
    font-size: 12px;
  }

  .spark {
    width: 100%;
    height: 38px;
    overflow: visible;
  }

  .spark path {
    fill: none;
    stroke: var(--accent);
    stroke-width: 2.5;
    stroke-linecap: round;
    stroke-linejoin: round;
  }

  .trend-up { color: var(--red); font-weight: 800; }
  .trend-dn { color: var(--green); font-weight: 800; }
  .trend-st { color: var(--muted); font-weight: 700; }

  .directory-overview { margin: 16px 0; }
  .change-summary { background: var(--panel); border-radius: 8px; padding: 20px; }
  .change-head { display: flex; justify-content: space-between; gap: 18px; align-items: flex-start; margin-bottom: 16px; }
  .change-head h2 { font-size: 20px; margin-bottom: 6px; }
  .change-head p { color: var(--muted); line-height: 1.5; }
  .change-metrics { display: grid; grid-template-columns: repeat(4, minmax(0, 1fr)); gap: 10px; }
  .change-metric { background: var(--track); border-radius: 8px; padding: 12px; }
  .change-metric span { color: var(--muted); display: block; font-size: 12px; margin-bottom: 5px; }
  .change-metric b { font-size: 17px; }
  .change-controls { display: flex; flex-wrap: wrap; gap: 8px; margin: 16px 0 10px; }
  .change-controls label { display: grid; gap: 4px; color: var(--muted); font-size: 12px; }
  .change-controls select { min-width: 140px; }
  .change-lists { display: grid; grid-template-columns: 1fr 1fr; gap: 14px; }
  .change-list { background: var(--panel); border-radius: 8px; padding: 16px; }
  .change-list h3 { font-size: 16px; margin-bottom: 8px; }
  .change-item { display: grid; grid-template-columns: minmax(0, 1fr) auto auto; gap: 10px; align-items: center; padding: 9px 0; border-top: 1px solid var(--line); }
  .change-path { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .copy-path { border: 0; background: transparent; color: var(--blue); cursor: pointer; padding: 4px; }
  .scan-details { margin-top: 12px; color: var(--muted); }
  .scan-details summary { cursor: pointer; color: var(--text); font-weight: 700; }
  .completeness-warning { color: var(--orange); font-weight: 700; }
  .baseline-guide { color: var(--muted); padding: 12px 0; }
  .directory-card-extra { border-top: 1px solid var(--line); margin-top: 14px; padding-top: 12px; font-size: 12px; color: var(--muted); }
  .directory-card-extra ul { margin: 7px 0 0 18px; }

  /* Apple-inspired system utility: quiet layers, explicit states, no decorative chrome. */
  :root {
    --bg: #f2f2f7;
    --panel: #ffffff;
    --text: #1c1c1e;
    --muted: #636366;
    --line: #d1d1d6;
    --track: #f2f2f7;
    --blue: #0a84ff;
    --green: #198754;
    --orange: #c65d07;
    --red: #c9362b;
  }
  [data-theme="dark"] {
    --bg: #000000;
    --panel: #1c1c1e;
    --text: #f5f5f7;
    --muted: #aeaeb2;
    --line: #38383a;
    --track: #2c2c2e;
    --blue: #409cff;
    --green: #48a868;
    --orange: #ff9f0a;
    --red: #ff6961;
  }
  body { font-family: -apple-system, BlinkMacSystemFont, "SF Pro Display", "Segoe UI", sans-serif; padding: 42px 24px 64px; letter-spacing: -.005em; }
  .shell { width: min(1180px, 100%); }
  header { align-items: center; margin-bottom: 34px; }
  h1 { font-size: 34px; letter-spacing: -.025em; font-weight: 720; }
  .eyebrow { color: var(--muted); letter-spacing: .04em; text-transform: none; font-size: 12px; margin-bottom: 5px; }
  .timestamp { margin-top: 7px; }
  .actions { gap: 8px; }
  .search, .select, .button, .toggle { height: 40px; border-color: transparent; background: var(--panel); border-radius: 10px; transition: background-color 180ms cubic-bezier(.22,1,.36,1), box-shadow 180ms cubic-bezier(.22,1,.36,1); }
  .search:hover, .select:hover, .button:hover, .toggle:hover { background: color-mix(in srgb, var(--panel) 86%, var(--blue)); }
  .search:focus-visible, .select:focus-visible, .button:focus-visible, .toggle:focus-within, .copy-path:focus-visible, summary:focus-visible { outline: 3px solid color-mix(in srgb, var(--blue) 35%, transparent); outline-offset: 2px; }
  .section-intro { display: flex; justify-content: space-between; align-items: end; gap: 16px; margin: 30px 2px 12px; }
  .section-intro h2 { font-size: 20px; letter-spacing: -.015em; }
  .section-intro p { color: var(--muted); font-size: 13px; }
  .panel, .metric, .card, .change-summary, .change-list { border: 0; border-radius: 16px; box-shadow: none; }
  .overview { gap: 10px; }
  .panel { padding: 22px; }
  .metric { padding: 20px; min-height: 124px; }
  .metric-label { text-transform: none; letter-spacing: 0; font-weight: 600; }
  .metric-value { letter-spacing: -.02em; }
  .insights { gap: 1px; overflow: hidden; border-radius: 16px; background: var(--line); }
  .insight, .insight.warn, .insight.critical, .insight.good { border-left: 0; border-radius: 0; min-height: 82px; padding: 16px 18px; }
  .insight-title { text-transform: none; letter-spacing: 0; font-weight: 600; }
  .directory-overview { margin-top: 0; }
  .change-summary { padding: 24px; }
  .change-head h2 { font-size: 22px; letter-spacing: -.02em; }
  .change-head p { max-width: 72ch; }
  .change-metrics { gap: 1px; overflow: hidden; border-radius: 12px; background: var(--line); }
  .change-metric { border-radius: 0; background: var(--track); padding: 14px 16px; }
  .change-controls { margin: 14px 0 10px; }
  .change-controls label { font-weight: 600; }
  .change-lists { gap: 10px; align-items: start; }
  .change-lists.single-sided { grid-template-columns: minmax(0, 1fr); }
  .change-lists.single-sided .change-list:has(> div > .baseline-guide) { display: none; }
  .change-list { padding: 18px 18px 8px; min-height: 0; }
  .change-item { min-height: 48px; }
  .growth-value { color: var(--orange); }
  .release-value { color: var(--green); }
  .copy-path { color: var(--blue); font-weight: 600; border-radius: 7px; }
  .copy-path:hover { background: color-mix(in srgb, var(--blue) 10%, transparent); }
  .scan-details { background: var(--panel); border-radius: 14px; padding: 14px 16px; }
  .scan-details[open] summary { margin-bottom: 10px; }
  .completeness-warning { display: inline-flex; align-items: center; background: color-mix(in srgb, var(--orange) 12%, transparent); border-radius: 999px; padding: 7px 10px; }
  .grid { gap: 10px; }
  .card { padding: 20px; }
  .badge { background: color-mix(in srgb, var(--accent) 12%, var(--panel)); }
  .mini { border-radius: 10px; }
  .directory-card-extra { display: grid; gap: 6px; }
  .directory-card-extra > span { display: block; }
  .directory-card-extra p { margin: 0; }
  footer { margin-top: 34px; }
  @media (prefers-reduced-motion: reduce) { *, *::before, *::after { scroll-behavior: auto !important; transition-duration: .01ms !important; animation-duration: .01ms !important; } }

  .empty {
    display: none;
    padding: 26px;
    text-align: center;
    color: var(--muted);
    background: var(--panel);
    border: 1px dashed var(--line);
    border-radius: 8px;
  }

  body.compact .card { padding: 14px; }
  body.compact .meta { grid-template-columns: repeat(4, 1fr); }
  body.compact .spark-row { display: none; }

  footer {
    color: var(--muted);
    font-size: 12px;
    margin-top: 24px;
    text-align: center;
  }

  @media (max-width: 900px) {
    header { align-items: stretch; flex-direction: column; }
    .actions { justify-content: flex-start; }
    .overview { grid-template-columns: repeat(2, minmax(0, 1fr)); }
    .panel { grid-column: 1 / -1; }
    .insights { grid-template-columns: 1fr; }
    .change-metrics, .change-lists { grid-template-columns: 1fr 1fr; }
    .grid { grid-template-columns: 1fr; }
  }

  @media (max-width: 560px) {
    body { padding: 24px 14px 40px; }
    .overview { grid-template-columns: 1fr; }
    .panel { grid-template-columns: 1fr; }
    .actions > * { width: 100%; justify-content: center; }
    .meta { grid-template-columns: 1fr; }
    .change-metrics, .change-lists { grid-template-columns: 1fr; }
    body.compact .meta { grid-template-columns: 1fr 1fr; }
    header { gap: 10px; }
    .actions { gap: 8px; }
    .search, .select, .button, .toggle { height: 44px; font-size: 15px; padding: 0 16px; }
    .toggle { padding: 0 14px; }
    .toggle input { width: 20px; height: 20px; }
  }
</style>
</head>
<body>
<main class="shell">
  <header>
    <div>
      <div class="eyebrow">System Storage</div>
      <h1>磁盘容量看板</h1>
      <div class="timestamp" id="ts"></div>
    </div>
    <div class="actions">
      <input class="search" id="search" type="search" placeholder="筛选盘符">
      <select class="select" id="sort">
        <option value="percent-desc">使用率高到低</option>
        <option value="percent-asc">使用率低到高</option>
        <option value="free-asc">剩余空间少到多</option>
        <option value="name-asc">盘符排序</option>
        <option value="change-desc">增长最多</option>
      </select>
      <label class="toggle"><input id="compact" type="checkbox">紧凑</label>
      <button class="button" id="themeBtn">主题</button>
      <button class="button" id="copy">复制摘要</button>
      <a class="button" href="DiskPulse.csv" download>下载历史</a>
    </div>
  </header>

  <div class="section-intro"><div><h2>存储概览</h2><p>容量、趋势与当前压力</p></div></div>
  <section class="overview" id="overview"></section>
  <section class="insights" id="insights"></section>
  <div class="section-intro"><div><h2>本次变化</h2><p>只展示有可靠基线支持的变化</p></div></div>
  <section class="directory-overview" id="directory-overview">
    <div class="change-summary" id="change-summary"></div>
    <div class="change-controls">
      <label>磁盘<select class="select" id="change-drive-filter" aria-label="筛选磁盘"></select></label>
      <label>目录层级<select class="select" id="change-level-filter" aria-label="筛选目录层级"><option value="1">一级目录</option><option value="2">二级目录</option></select></label>
      <label>变化方向<select class="select" id="change-direction-filter" aria-label="筛选变化方向"><option value="all">全部变化</option><option value="growth">仅增长</option><option value="release">仅释放</option></select></label>
    </div>
    <div class="change-lists">
      <div class="change-list"><h3>增长最多</h3><div id="growth-list"></div></div>
      <div class="change-list"><h3>释放最多</h3><div id="release-list"></div></div>
    </div>
    <details class="scan-details" id="scan-details"><summary>扫描详情与排除项</summary><div id="scan-detail-body"></div></details>
  </section>
  <div class="section-intro"><div><h2>磁盘详情</h2><p>容量趋势、比较可信度与目录来源</p></div></div>
  <section class="grid" id="grid"></section>
  <div class="empty" id="empty">没有匹配的磁盘</div>
  <footer id="footer"></footer>
</main>

<script>
const RAW_DATA = INJECT_DATA;
const RAW_HISTORY = INJECT_HISTORY;
const RAW_DIRECTORY = INJECT_DIRECTORY;
const DATA = Array.isArray(RAW_DATA) ? RAW_DATA : RAW_DATA ? [RAW_DATA] : [];
const HISTORY = Array.isArray(RAW_HISTORY) ? RAW_HISTORY : RAW_HISTORY ? [RAW_HISTORY] : [];
const DIRECTORY = Array.isArray(RAW_DIRECTORY) ? RAW_DIRECTORY : RAW_DIRECTORY ? [RAW_DIRECTORY] : [];
const TS = "INJECT_TS";

const historyMap = {};
HISTORY.forEach((row) => {
  const id = String(row.ID).replace(/\\/g, "");
  if (!historyMap[id]) historyMap[id] = [];
  historyMap[id].push(row);
});
Object.values(historyMap).forEach((arr) =>
  arr.sort((a, b) => String(a.Timestamp).localeCompare(String(b.Timestamp)))
);

const state = {
  query: "",
  sort: "percent-desc",
  compact: false
};

const $ = (id) => document.getElementById(id);

(function() {
  var saved = localStorage.getItem("diskpulse-theme");
  if (saved) {
    document.documentElement.setAttribute("data-theme", saved);
  } else if (window.matchMedia && window.matchMedia("(prefers-color-scheme: dark)").matches) {
    document.documentElement.setAttribute("data-theme", "dark");
  }
})();

$("ts").textContent = "更新于 " + TS;
$("footer").textContent = "历史记录保留最近 " + HISTORY.length + " 条采样";

function fmt(gb) {
  const value = Number(gb) || 0;
  if (value >= 1000) return (value / 1000).toFixed(2) + " TB";
  return value.toFixed(value >= 100 ? 0 : 1) + " GB";
}

function pct(value) {
  return (Number(value) || 0).toFixed(1).replace(".0", "") + "%";
}

function statusText(status) {
  return { good: "健康", warning: "注意", critical: "告警" }[status] || "未知";
}

function historyFor(id) {
  return historyMap[id] || [];
}

function sparkline(rows) {
  const samples = rows.slice(-20).map((row) => Number(row.Percent) || 0);
  if (samples.length < 2) return '<svg class="spark" viewBox="0 0 120 38" aria-hidden="true"><path d="M2 28 L118 28"></path></svg>';
  const min = Math.min(...samples);
  const max = Math.max(...samples);
  const span = Math.max(1, max - min);
  const points = samples.map((value, index) => {
    const x = 2 + (index / (samples.length - 1)) * 116;
    const y = 34 - ((value - min) / span) * 30;
    return `${x.toFixed(1)} ${y.toFixed(1)}`;
  });
  return `<svg class="spark" viewBox="0 0 120 38" preserveAspectRatio="none" aria-hidden="true"><path d="M${points.join(" L")}"></path></svg>`;
}

function estimateDays(drive, rows) {
  const samples = rows.slice(-20);
  if (samples.length < 3) return "样本不足";
  const points = samples.map((r, i) => ({ x: i, y: Number(r.Used) || 0 }));
  const n = points.length;
  const sumX = points.reduce((s, p) => s + p.x, 0);
  const sumY = points.reduce((s, p) => s + p.y, 0);
  const sumXY = points.reduce((s, p) => s + p.x * p.y, 0);
  const sumX2 = points.reduce((s, p) => s + p.x * p.x, 0);
  const denom = n * sumX2 - sumX * sumX;
  if (denom === 0) return "暂无增长压力";
  const slope = (n * sumXY - sumX * sumY) / denom;
  const firstTs = new Date(samples[0].Timestamp).getTime();
  const lastTs = new Date(samples[n - 1].Timestamp).getTime();
  const hoursPerSample = (lastTs - firstTs) / ((n - 1) * 36e5);
  const dailyGrowth = slope * (24 / Math.max(hoursPerSample, 1 / 24));
  if (dailyGrowth <= 0.01) return "暂无增长压力";
  const days = (Number(drive.free) || 0) / dailyGrowth;
  if (!Number.isFinite(days) || days > 3650) return "暂无增长压力";
  if (days < 1) return "不足 1 天";
  return Math.round(days) + " 天后可能满";
}

function trend(diff) {
  const value = Number(diff) || 0;
  if (value > 0) return `<span class="trend-up">增加 ${fmt(value)}</span>`;
  if (value < 0) return `<span class="trend-dn">减少 ${fmt(Math.abs(value))}</span>`;
  return `<span class="trend-st">无变化</span>`;
}

function totals() {
  return DATA.reduce((acc, d) => {
    acc.total += Number(d.total) || 0;
    acc.used += Number(d.used) || 0;
    acc.free += Number(d.free) || 0;
    acc.diff += Number(d.diff) || 0;
    return acc;
  }, { total: 0, used: 0, free: 0, diff: 0 });
}

function prevTotals() {
  var map = {};
  HISTORY.forEach(function(r) {
    var id = String(r.ID).replace(/\\/g, "");
    if (!map[id]) map[id] = [];
    map[id].push(r);
  });
  var acc = { total: 0, used: 0, free: 0 };
  var hasPrev = false;
  Object.values(map).forEach(function(rows) {
    rows.sort(function(a, b) { return String(a.Timestamp).localeCompare(String(b.Timestamp)); });
    if (rows.length >= 2) {
      var p = rows[rows.length - 2];
      acc.total += Number(p.Total) || 0;
      acc.used += Number(p.Used) || 0;
      acc.free += Number(p.Free) || 0;
      hasPrev = true;
    }
  });
  return hasPrev ? acc : null;
}

function renderOverview() {
  const t = totals();
  const pt = prevTotals();
  const overallPct = t.total > 0 ? (t.used / t.total) * 100 : 0;
  const mostFull = [...DATA].sort((a, b) => b.percent - a.percent)[0];
  const comparableCount = DIRECTORY.filter((item) => item.baselineScanId).length; // trust-summary
  $("overview").innerHTML = `
    <article class="panel">
      <div class="ring" style="--pct:${overallPct.toFixed(1)}"><span>${pct(overallPct)}</span></div>
      <div>
        <div class="overall-title">整体容量状态</div>
        <div class="overall-copy">共 ${DATA.length} 个磁盘，已用 ${fmt(t.used)}，剩余 ${fmt(t.free)}。本次采样较上次${t.diff >= 0 ? "增加" : "减少"} ${fmt(Math.abs(t.diff))}。</div>
      </div>
    </article>
    ${metric("总容量", fmt(t.total), "所有本地固定磁盘合计")}
    ${metric("已使用", fmt(t.used), "当前占用空间", pt ? fmt(pt.used) : "")}
    ${metric("剩余", fmt(t.free), "可继续写入空间", pt ? fmt(pt.free) : "")}
    ${metric("最高使用率", mostFull ? `${mostFull.id} ${pct(mostFull.percent)}` : "-", mostFull ? statusText(mostFull.status) : "-")}
  `;
  $("insights").innerHTML = [
    insight("容量最高", mostFull ? `${mostFull.id} 已使用 ${pct(mostFull.percent)}，剩余 ${fmt(mostFull.free)}` : "-", mostFull?.status),
    insight("比较可信度", `${comparableCount} 个磁盘可可靠比较，${Math.max(0, DIRECTORY.length - comparableCount)} 个等待完整基线`, comparableCount === DIRECTORY.length ? "good" : "warn"),
    insight("历史样本", `${HISTORY.length} 条记录，可用于趋势判断`, "good")
  ].join("");
}

function metric(label, value, note, prev) {
  var prevHtml = prev ? '<div class="metric-prev">上次 ' + prev + '</div>' : '';
  return `<article class="metric"><div class="metric-label">${label}</div><div class="metric-value">${value}</div>${prevHtml}<div class="metric-note">${note}</div></article>`;
}

function insight(title, body, status = "good") {
  const klass = status === "critical" ? "critical" : status === "warning" || status === "warn" ? "warn" : "good";
  return `<article class="insight ${klass}"><div class="insight-title">${title}</div><div class="insight-body">${body}</div></article>`;
}

function sortedDrives() {
  const query = state.query.trim().toLowerCase();
  const filtered = DATA.filter((d) => d.id.toLowerCase().includes(query));
  const sorters = {
    "percent-desc": (a, b) => b.percent - a.percent,
    "percent-asc": (a, b) => a.percent - b.percent,
    "free-asc": (a, b) => a.free - b.free,
    "name-asc": (a, b) => a.id.localeCompare(b.id),
    "change-desc": (a, b) => b.diff - a.diff
  };
  return filtered.sort(sorters[state.sort] || sorters["percent-desc"]);
}

function fmtBytes(value) {
  let size = Math.abs(Number(value) || 0);
  const units = ["B", "KB", "MB", "GB", "TB"];
  let index = 0;
  while (size >= 1024 && index < units.length - 1) { size /= 1024; index++; }
  return `${Number(value) < 0 ? "-" : ""}${size.toFixed(index ? 2 : 0)} ${units[index]}`;
}

function escapeHtml(value) {
  return String(value ?? "").replace(/[&<>"']/g, (char) => ({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[char]));
}

function directoryCoverage(id) {
  return DIRECTORY.find((item) => item.drive.replace(/\\/g, "") === id)?.coverage || null;
}

function isReliableChange(row) {
  return ["created", "changed", "removed"].includes(row.state);
}

function reliableChanges(item, level) {
  return item && item.baselineScanId ? item.changes.filter((row) => isReliableChange(row) && (!level || row.level === level)) : [];
}

function statusLabel(status, hasBaseline) {
  if (!hasBaseline) return "等待完整基线";
  if (status === "complete" || status === "baseline") return "扫描完整";
  if (status === "failed") return "扫描失败";
  return "扫描不完整";
}

function coverageLabel(item) {
  if (!item?.baselineScanId) return "等待完整基线";
  if (item.coverage?.activityPreferred || Math.abs(Number(item.coverage?.actualNetBytes || 0)) < 1) return "不适用";
  return `${Number(item.coverage?.rate || 0).toFixed(1)}%`;
}

function directoryTopThree(id) {
  const item = DIRECTORY.find((entry) => entry.drive.replace(/\\/g, "") === id);
  return reliableChanges(item, 1).sort((a,b) => Math.abs(b.deltaBytes) - Math.abs(a.deltaBytes)).slice(0,3);
}

function changeRow(row, index) {
  const valueClass = row.deltaBytes >= 0 ? "growth-value" : "release-value";
  return `<div class="change-item"><span class="change-path" title="${escapeHtml(row.displayPath)}">${escapeHtml(row.displayPath)}</span><b class="${valueClass}">${row.deltaBytes >= 0 ? "+" : ""}${fmtBytes(row.deltaBytes)}</b><button class="copy-path" type="button" data-path-index="${index}">复制路径</button></div>`;
}

function renderDirectoryChanges() {
  const driveFilter = $("change-drive-filter");
  if (!driveFilter.options.length) {
    driveFilter.add(new Option("全部磁盘", "all"));
    DIRECTORY.forEach((item) => driveFilter.add(new Option(item.drive, item.drive)));
  }
  const selectedDrive = driveFilter.value;
  const level = Number($("change-level-filter").value);
  const direction = $("change-direction-filter").value;
  const selected = DIRECTORY.filter((item) => selectedDrive === "all" || item.drive === selectedDrive);
  const rows = selected.flatMap((item) => reliableChanges(item, level).map((row) => ({...row, drive:item.drive})));
  const growth = rows.filter((row) => row.deltaBytes > 0).sort((a,b) => b.deltaBytes-a.deltaBytes).slice(0,10);
  const release = rows.filter((row) => row.deltaBytes < 0).sort((a,b) => a.deltaBytes-b.deltaBytes).slice(0,10);
  const visibleGrowth = direction === "release" ? [] : growth;
  const visibleRelease = direction === "growth" ? [] : release;
  $("directory-overview").querySelector(".change-lists").classList.toggle("single-sided", !visibleGrowth.length || !visibleRelease.length);
  window.directoryPaths = [...visibleGrowth, ...visibleRelease].map((row) => row.displayPath);
  $("growth-list").innerHTML = visibleGrowth.map((row,index) => changeRow(row,index)).join("") || '<div class="baseline-guide">暂无增长记录。</div>';
  $("release-list").innerHTML = visibleRelease.map((row,index) => changeRow(row,index+visibleGrowth.length)).join("") || '<div class="baseline-guide">暂无释放记录。</div>';

  const comparable = selected.filter((item) => item.baselineScanId);
  const coverages = comparable.map((item) => item.coverage).filter(Boolean);
  const actual = coverages.reduce((sum,item) => sum + Number(item.actualNetBytes || 0),0);
  const located = coverages.reduce((sum,item) => sum + Number(item.locatedNetBytes || 0),0);
  const added = coverages.reduce((sum,item) => sum + Number(item.addedBytes || 0),0);
  const released = coverages.reduce((sum,item) => sum + Number(item.releasedBytes || 0),0);
  const rateText = !coverages.length || Math.abs(actual) < 1 ? "不适用" : `${Math.min(100, Math.abs(located)/Math.abs(actual)*100).toFixed(1)}%`;
  const source = growth[0];
  const incomplete = selected.filter((item) => item.status === "partial" || item.status === "failed");
  const waiting = selected.filter((item) => !item.baselineScanId).map((item) => item.drive);
  const summary = !comparable.length ? "尚无可比较的完整基线。本次只记录当前目录规模，不计算增长来源。" : `可靠比较磁盘净变化 ${fmtBytes(actual)}，已定位 ${fmtBytes(located)}。${source ? `主要增长来自 ${escapeHtml(source.displayPath)}。` : "没有发现明确增长来源。"}${waiting.length ? ` ${waiting.join("、")} 正在等待完整基线。` : ""}`;
  $("change-summary").innerHTML = `<div class="change-head"><div><h2>本次发生了什么</h2><p>${summary}</p></div><span class="${incomplete.length ? "completeness-warning" : ""}">${incomplete.length ? `${incomplete.length} 个磁盘扫描不完整` : "全部扫描完整"}</span></div><div class="change-metrics"><div class="change-metric"><span>可靠新增</span><b class="growth-value">+${fmtBytes(added)}</b></div><div class="change-metric"><span>可靠释放</span><b class="release-value">${released ? "-" : ""}${fmtBytes(released)}</b></div><div class="change-metric"><span>已定位净变化</span><b>${fmtBytes(located)}</b></div><div class="change-metric"><span>解释率</span><b>${rateText}</b></div></div>`;
  const details = selected.flatMap((item) => [...(item.errors || []).map((e) => `${item.drive} 无法访问：${e.path} · ${e.reason}`), ...(item.excluded || []).map((e) => `${item.drive} 预期排除：${e.path} · ${e.reason}`)]);
  $("scan-detail-body").innerHTML = details.length ? `<ul>${details.map((line) => `<li>${escapeHtml(line)}</li>`).join("")}</ul>` : "没有排除项或访问错误。";
}

function renderCards() {
  const drives = sortedDrives();
  $("empty").style.display = drives.length ? "none" : "block";
  $("grid").innerHTML = drives.map((d) => {
    const rows = historyFor(d.id);
    const lastSeen = rows.length ? rows[rows.length - 1].Timestamp : TS;
    const prev = rows.length >= 2 ? rows[rows.length - 2] : null;
    const prevUsed = prev ? '<small>上次 ' + fmt(prev.Used) + '</small>' : '';
    const prevFree = prev ? '<small>上次 ' + fmt(prev.Free) + '</small>' : '';
    const prevTotal = prev ? '<small>上次 ' + fmt(prev.Total) + '</small>' : '';
    const directory = DIRECTORY.find((item) => item.drive.replace(/\\/g, "") === d.id);
    const coverage = directoryCoverage(d.id);
    const topThree = directoryTopThree(d.id);
    return `
      <article class="card ${d.status}">
        <div class="card-top">
          <div>
            <div class="drive-name">磁盘 ${d.id}</div>
            <div class="drive-sub">最近采样 ${lastSeen}</div>
          </div>
          <div class="badge">使用率 ${pct(d.percent)}</div><!-- badge-copy-v2 -->
        </div>
        <div class="bar-track"><div class="bar-fill" data-w="${d.percent}%"></div></div>
        <div class="meta">
          <div class="mini"><span>已用</span><b>${fmt(d.used)}</b>${prevUsed}</div>
          <div class="mini"><span>剩余</span><b>${fmt(d.free)}</b>${prevFree}</div>
          <div class="mini"><span>总量</span><b>${fmt(d.total)}</b>${prevTotal}</div>
        </div>
        <div class="spark-row">
          ${sparkline(rows)}
          <div>
            <div>${trend(d.diff)}</div>
            <div>${estimateDays(d, rows)}</div>
          </div>
        </div>
        <div class="directory-card-extra"><b>${directory?.baselineScanId ? `目录净变化 ${fmtBytes(coverage?.actualNetBytes)}` : "当前目录规模已记录"}</b><span>解释率 ${directory ? coverageLabel(directory) : "-"} · ${directory ? statusLabel(directory.status, directory.baselineScanId) : "未扫描"}</span>${topThree.length ? `<ul>${topThree.map((row) => `<li title="${escapeHtml(row.displayPath)}">${escapeHtml(row.displayPath)} <b class="${row.deltaBytes >= 0 ? "growth-value" : "release-value"}">${row.deltaBytes >= 0 ? "+" : ""}${fmtBytes(row.deltaBytes)}</b></li>`).join("")}</ul>` : `<p>${directory?.baselineScanId ? "本次没有可靠目录变化。" : "建立完整基线后显示目录变化 Top 3。"}</p>`}</div>
      </article>
    `;
  }).join("");
  requestAnimationFrame(() => {
    document.querySelectorAll(".bar-fill").forEach((bar) => {
      bar.style.width = bar.dataset.w;
    });
  });
}

function render() {
  document.body.classList.toggle("compact", state.compact);
  renderOverview();
  renderDirectoryChanges();
  renderCards();
}

["change-drive-filter","change-level-filter","change-direction-filter"].forEach((id) => $(id).addEventListener("change", renderDirectoryChanges));
$("directory-overview").addEventListener("click", async (event) => {
  const button = event.target.closest(".copy-path");
  if (!button) return;
  const path = window.directoryPaths[Number(button.dataset.pathIndex)];
  try { await navigator.clipboard.writeText(path); button.textContent = "已复制"; }
  catch { alert(path); }
});

$("search").addEventListener("input", (event) => {
  state.query = event.target.value;
  renderCards();
});

$("sort").addEventListener("change", (event) => {
  state.sort = event.target.value;
  renderCards();
});

$("compact").addEventListener("change", (event) => {
  state.compact = event.target.checked;
  render();
});

$("themeBtn").addEventListener("click", () => {
  var current = document.documentElement.getAttribute("data-theme");
  var next = current === "dark" ? "light" : "dark";
  document.documentElement.setAttribute("data-theme", next);
  localStorage.setItem("diskpulse-theme", next);
  $("themeBtn").textContent = next === "dark" ? " 浅色" : " 深色";
});

(function() {
  var t = document.documentElement.getAttribute("data-theme");
  $("themeBtn").textContent = t === "dark" ? " 浅色" : " 深色";
})();

$("copy").addEventListener("click", async () => {
  const t = totals();
  const lines = [
    `磁盘容量看板 ${TS}`,
    `总容量 ${fmt(t.total)} / 已用 ${fmt(t.used)} / 剩余 ${fmt(t.free)}`,
    ...DATA.map((d) => `${d.id} 使用率 ${pct(d.percent)}，剩余 ${fmt(d.free)}，本次${(Number(d.diff) || 0) >= 0 ? "增加" : "减少"} ${fmt(Math.abs(Number(d.diff) || 0))}`)
  ];
  try {
    await navigator.clipboard.writeText(lines.join("\\n"));
    $("copy").textContent = "已复制";
    setTimeout(() => $("copy").textContent = "复制摘要", 1400);
  } catch {
    alert(lines.join("\\n"));
  }
});

document.addEventListener("keydown", (e) => {
  if (e.target.tagName === "INPUT" || e.target.tagName === "SELECT") return;
  if (e.key === "c" || e.key === "C") {
    state.compact = !state.compact;
    $("compact").checked = state.compact;
    render();
  }
});

render();
</script>
</body>
</html>
'@

$html = $html.Replace('INJECT_DATA', $jsonArray)
$html = $html.Replace('INJECT_HISTORY', $historyJson)
$html = $html.Replace('INJECT_DIRECTORY', $directoryJson)
$html = $html.Replace('INJECT_TS', $timestamp)

$utf8NoBom = New-Object System.Text.UTF8Encoding $false
[System.IO.File]::WriteAllText($htmlFile, $html, $utf8NoBom)

if ($env:DISKPULSE_NO_OPEN -ne "1") {
    try {
        Start-Process $htmlFile
    }
    catch {
        Write-Warning "Generated $htmlFile. Open it manually if the browser did not launch."
    }
}

Write-ScanEvent $paths ([PSCustomObject]@{
    scanId = $scanId
    status = $snapshot.status
    startedAt = $startedAt
    completedAt = (Get-Date).ToUniversalTime().ToString("o")
})
}
catch {
    Write-ScanEvent $paths ([PSCustomObject]@{
        scanId = $scanId
        status = "failed"
        startedAt = $startedAt
        completedAt = (Get-Date).ToUniversalTime().ToString("o")
        reason = $_.Exception.Message
    })
    throw
}
finally {
    Release-DiskPulseLock $paths $owner
}
}

if ($env:DISKPULSE_TEST_MODE -ne "1") {
    Invoke-DiskPulse
}
