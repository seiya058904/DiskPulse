Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$silent = $env:DISKPULSE_SILENT -eq "1"
$profileMode = $env:DISKPULSE_PROFILE -eq "1"
if ($profileMode) {
    $script:profileMarks = [System.Collections.Generic.List[PSObject]]::new()
    $script:profileStopwatch = [Diagnostics.Stopwatch]::StartNew()
}
function Profile-Mark([string]$Key) {
    if (-not $profileMode) { return }
    $script:profileMarks.Add([PSCustomObject]@{ key = $Key; ms = $script:profileStopwatch.ElapsedMilliseconds })
}
function Write-DiskPulseAIProfile {
    param([string]$Path, $Data)
    if (-not $profileMode -or [string]::IsNullOrWhiteSpace($Path)) { return }
    $allowed = @(
        'scanId','status','format','workerOutcome','provider','model','inputChars','inputBytes','systemChars','userChars','requestBytes',
        'launchToWorkerEntryMs','contractReadMs','promptBuildMs','configLoadMs','httpRequestMs',
        'responseDecodeParseMs','htmlUpdateMs','resultWriteMs','workerTotalMs',
        'inputTokens','outputTokens','completionTokens','reasoningTokens','cachedTokens','totalTokens'
    )
    $safe = [ordered]@{}
    foreach ($name in $allowed) {
        if ($Data -and $Data.PSObject.Properties.Name -contains $name) { $safe[$name] = $Data.$name }
    }
    $directory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $directory)) { [IO.Directory]::CreateDirectory($directory) | Out-Null }
    $tempPath = Join-Path $directory ('.profile-' + [guid]::NewGuid().ToString('N') + '.tmp')
    $backupPath = $tempPath + '.bak'
    try {
        [IO.File]::WriteAllText($tempPath, (ConvertTo-Json -InputObject ([PSCustomObject]$safe) -Depth 4), (New-Object Text.UTF8Encoding $false))
        if (Test-Path -LiteralPath $Path) { [IO.File]::Replace([string]$tempPath, [string]$Path, [string]$backupPath) } else { [IO.File]::Move([string]$tempPath, [string]$Path) }
    } finally {
        if (Test-Path -LiteralPath $tempPath) { Remove-Item -LiteralPath $tempPath -Force }
        if (Test-Path -LiteralPath $backupPath) { Remove-Item -LiteralPath $backupPath -Force }
    }
}
function Test-DiskPulseAIScanId {
    param([string]$ScanId)
    return (-not [string]::IsNullOrWhiteSpace($ScanId) -and $ScanId -match '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$')
}
function Acquire-DiskPulseAIProfileLock {
    param([string]$RuntimePath)
    $lockPath = Join-Path $RuntimePath 'ai-profile.lock'
    if (-not (Test-Path -LiteralPath $RuntimePath)) { [IO.Directory]::CreateDirectory($RuntimePath) | Out-Null }
    for ($attempt = 0; $attempt -lt 240; $attempt++) {
        try {
            $stream = [IO.File]::Open($lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
            return $stream
        } catch [IO.IOException] { Start-Sleep -Milliseconds 25 }
    }
    throw '无法取得 AI profile 发布锁。'
}
function Release-DiskPulseAIProfileLock {
    param($Lock)
    if ($Lock) { $Lock.Dispose() }
}
function Publish-DiskPulseAIProfile {
    param([string]$RuntimePath, [string]$ScanId, $Data, [string]$EventsPath)
    if (-not (Test-DiskPulseAIScanId $ScanId)) { return 'skipped' }
    $profileLock = Acquire-DiskPulseAIProfileLock $RuntimePath
    try {
        $profileDir = Join-Path $RuntimePath 'ai-profiles'
        if (-not (Test-Path -LiteralPath $profileDir)) { [IO.Directory]::CreateDirectory($profileDir) | Out-Null }
        Write-DiskPulseAIProfile -Path (Join-Path $profileDir ($ScanId + '.json')) -Data $Data
        $latest = Get-DiskPulseAILatestScanEvent $EventsPath
        $sameScan = $latest -and [string]$latest.scanId -eq $ScanId
        $isCurrent = $sameScan -and [string]$latest.status -in @('complete','partial')
        if ($isCurrent) {
            $publishOutcome = if ($Data.PSObject.Properties.Name -contains 'workerOutcome') { [string]$Data.workerOutcome } else { 'skipped' }
            Write-DiskPulseAIProfile -Path (Join-Path $RuntimePath 'last-ai-profile.json') -Data $Data
        } else {
            $publishOutcome = if ($sameScan -and $Data.PSObject.Properties.Name -contains 'workerOutcome') { [string]$Data.workerOutcome } else { 'stale-discarded' }
            if ($Data.PSObject.Properties.Name -contains 'workerOutcome') { $Data.workerOutcome = $publishOutcome } else { $Data | Add-Member -NotePropertyName workerOutcome -NotePropertyValue $publishOutcome }
            Write-DiskPulseAIProfile -Path (Join-Path $profileDir ($ScanId + '.json')) -Data $Data
        }
        $profiles = @(Get-ChildItem -LiteralPath $profileDir -Filter '*.json' -File | Sort-Object LastWriteTimeUtc -Descending)
        foreach ($old in @($profiles | Select-Object -Skip 20)) { Remove-Item -LiteralPath $old.FullName -Force }
        return $publishOutcome
    } finally { Release-DiskPulseAIProfileLock $profileLock }
}

function Get-DiskPulsePaths {
    $root = [IO.Path]::GetFullPath([string]$env:DISKPULSE_ROOT)
    $dataRoot = if ([string]::IsNullOrWhiteSpace($env:DISKPULSE_DATA_ROOT)) { $root } else { [IO.Path]::GetFullPath([string]$env:DISKPULSE_DATA_ROOT) }
    $runtime = Join-Path $dataRoot "runtime"
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
    try {
        $stream = [IO.File]::Open($Paths.Lock, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    } catch [IO.IOException] { throw "DiskPulse is already running." }
    return [pscustomobject]@{ scanId=$ScanId; Stream=$stream }
}

function Release-DiskPulseLock {
    param($Paths, $Owner)
    if ($Owner -and $Owner.Stream) { $Owner.Stream.Dispose() }
}

# Reentrant within this runspace; the handle provides cross-process exclusion.
$script:diskPulsePublishLocks = @{}
function Invoke-DiskPulsePublication {
    param([string]$Runtime, [scriptblock]$Action)
    $key = [IO.Path]::GetFullPath($Runtime).ToLowerInvariant()
    if ($script:diskPulsePublishLocks.ContainsKey($key)) { return (& $Action) }
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $stream = $null
    while (-not $stream) {
        try { $stream = [IO.File]::Open((Join-Path $Runtime 'publish.lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) }
        catch [IO.IOException] {
            if ($watch.ElapsedMilliseconds -ge 30000) { throw 'Timed out acquiring DiskPulse publication lock.' }
            Start-Sleep -Milliseconds 25
        }
    }
    $script:diskPulsePublishLocks[$key] = $stream
    try { & $Action }
    finally { $script:diskPulsePublishLocks.Remove($key); $stream.Dispose() }
}

function Read-DiskPulseScanEvents {
    param([string]$Path)
    if (-not [IO.File]::Exists($Path)) { return }
    $lines = @([IO.File]::ReadAllLines($Path, [Text.Encoding]::UTF8))
    $last = $lines.Count - 1
    while ($last -ge 0 -and -not $lines[$last].Trim()) { $last-- }
    for ($i=0; $i -le $last; $i++) {
        if (-not $lines[$i].Trim()) { continue }
        try {
            $event = $lines[$i] | ConvertFrom-Json -ErrorAction Stop
            if (-not $event -or -not $event.scanId -or -not $event.status) { throw 'Invalid event.' }
            $event
        } catch {
            if ($i -eq $last) { Write-Warning 'Ignoring incomplete journal tail.' }
            else { throw "Invalid journal record at line $($i+1)." }
        }
    }
}

function Write-ScanEvent {
    param($Paths, $Event)
    Invoke-DiskPulsePublication (Split-Path -Parent $Paths.Events) {
        $events = @(Read-DiskPulseScanEvents $Paths.Events)
        $lines = @($events | ForEach-Object { ConvertTo-Json -InputObject $_ -Depth 12 -Compress })
        $lines += ConvertTo-Json -InputObject $Event -Depth 12 -Compress
        Write-DiskPulseAtomicText -FinalPath $Paths.Events -Content (($lines -join [Environment]::NewLine) + [Environment]::NewLine)
    }
}

function New-DiskPulseTempPath {
    param([string] $FinalPath)
    $directory = Split-Path -Parent $FinalPath
    if (-not (Test-Path -LiteralPath $directory)) {
        [IO.Directory]::CreateDirectory($directory) | Out-Null
    }
    $name = [IO.Path]::GetFileName($FinalPath)
    return Join-Path $directory ('.diskpulse-' + $name + '-' + [guid]::NewGuid().ToString('N') + '.tmp')
}

function Publish-DiskPulseAtomicFile {
    param([string] $FinalPath, [string] $TemporaryPath)
    if ([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($FinalPath)) -ne [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($TemporaryPath))) { throw 'Atomic publication requires the same directory.' }
    if (-not (Test-Path -LiteralPath $TemporaryPath -PathType Leaf)) {
        throw "Temporary file not found: $TemporaryPath"
    }
    $flushStream = [IO.File]::Open($TemporaryPath, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try { $flushStream.Flush($true) } finally { $flushStream.Dispose() }
    $directory = Split-Path -Parent $FinalPath
    if (-not (Test-Path -LiteralPath $directory)) {
        [IO.Directory]::CreateDirectory($directory) | Out-Null
    }
    if (Test-Path -LiteralPath $FinalPath -PathType Leaf) {
        $backupPath = Join-Path $directory ('.diskpulse-backup-' + [IO.Path]::GetFileName($FinalPath) + '-' + [guid]::NewGuid().ToString('N') + '.bak')
        try {
            [IO.File]::Replace($TemporaryPath, $FinalPath, $backupPath, $true)
        }
        finally {
            if (Test-Path -LiteralPath $TemporaryPath) { Remove-Item -LiteralPath $TemporaryPath -Force -ErrorAction SilentlyContinue }
            if (Test-Path -LiteralPath $backupPath) { Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue }
        }
    }
    else {
        try {
            [IO.File]::Move($TemporaryPath, $FinalPath)
        }
        finally {
            if (Test-Path -LiteralPath $TemporaryPath) { Remove-Item -LiteralPath $TemporaryPath -Force -ErrorAction SilentlyContinue }
        }
    }
}

function Write-DiskPulseAtomicText {
    param([string] $FinalPath, [string] $Content, [scriptblock] $Validate = $null)
    $temporaryPath = New-DiskPulseTempPath $FinalPath
    try {
        [IO.File]::WriteAllText($temporaryPath, $Content, (New-Object Text.UTF8Encoding $false))
        if ($Validate) {
            $valid = & $Validate $temporaryPath
            if ($valid -ne $true) {
                throw "Atomic write validation failed: $FinalPath"
            }
        }
        Publish-DiskPulseAtomicFile -FinalPath $FinalPath -TemporaryPath $temporaryPath
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath) { Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue }
    }
}

function Write-DiskPulseAtomicCsv {
    param([string] $FinalPath, $Rows)
    $temporaryPath = New-DiskPulseTempPath $FinalPath
    try {
        $Rows | Export-Csv -LiteralPath $temporaryPath -NoTypeInformation -Encoding UTF8
        Import-Csv -LiteralPath $temporaryPath | Out-Null
        Publish-DiskPulseAtomicFile -FinalPath $FinalPath -TemporaryPath $temporaryPath
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath) { Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue }
    }
}

function Write-AtomicJson {
    param([string] $FinalPath, $Value)
    if (Test-Path -LiteralPath $FinalPath) {
        throw "目标 JSON 已存在：$FinalPath"
    }
    $json = ConvertTo-Json -InputObject $Value -Depth 12 -Compress
    Write-DiskPulseAtomicText -FinalPath $FinalPath -Content $json -Validate {
        param($Path)
        try {
            Get-Content -Raw -LiteralPath $Path -Encoding UTF8 | ConvertFrom-Json | Out-Null
            return $true
        }
        catch {
            return $false
        }
    }
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
