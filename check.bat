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

if (-not ('DiskPulseFastScanner' -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Collections.Generic;

public sealed class DiskPulseFastRecord {
    public string key, kind, displayPath, path, latestWriteTime;
    public int level, fileCount;
    public long sizeBytes;
    public bool enumerationComplete = true, childrenEnumerationComplete = true;
}
public sealed class DiskPulseFastEvidence { public string path, reason, kind; }
public sealed class DiskPulseFastProgress {
    public string phase, drive, currentPath;
    public long filesProcessed, directoriesProcessed, elapsedMilliseconds;
    public int completedTopLevel, totalTopLevel;
    public double percentComplete;
}
public sealed class DiskPulseFastResult {
    public string drive, rootPath, status;
    public bool enumerationComplete, childrenEnumerationComplete;
    public List<DiskPulseFastRecord> records = new List<DiskPulseFastRecord>();
    public List<DiskPulseFastEvidence> excluded = new List<DiskPulseFastEvidence>();
    public List<DiskPulseFastEvidence> unavailable = new List<DiskPulseFastEvidence>();
    public List<DiskPulseFastEvidence> errors = new List<DiskPulseFastEvidence>();
}
public static class DiskPulseFastScanner {
    sealed class Work { public string Path, Top; public Work(string p, string t) { Path=p; Top=t; } }
    static string Key(string p) { return Path.GetFullPath(p).Replace('/', '\\').TrimEnd('\\').ToLowerInvariant(); }
    public static string NormalizeRoot(string rootPath) {
        string full=Path.GetFullPath(rootPath);
        return full.Equals(Path.GetPathRoot(full),StringComparison.OrdinalIgnoreCase) ? full : full.TrimEnd('\\');
    }
    static void AddEvidence(List<DiskPulseFastEvidence> list, string path, string reason, string kind=null) {
        list.Add(new DiskPulseFastEvidence { path=path, reason=reason, kind=kind });
    }
    static DiskPulseFastRecord DirectoryRecord(string path, int level) {
        string full=Path.GetFullPath(path).TrimEnd('\\');
        return new DiskPulseFastRecord { key=Key(full), kind="directory", displayPath=full, level=level };
    }
    static void AddFile(DiskPulseFastRecord record, long length, string write) {
        record.sizeBytes += length; record.fileCount++;
        if (record.latestWriteTime==null || String.CompareOrdinal(write, record.latestWriteTime)>0) record.latestWriteTime=write;
    }
    public static DiskPulseFastResult Scan(string drive, string rootPath, Action<DiskPulseFastProgress> progress) {
        string root=NormalizeRoot(rootPath);
        string prefix=root.EndsWith("\\",StringComparison.Ordinal) ? root : root+"\\", current=root;
        var result=new DiskPulseFastResult { drive=drive.ToUpperInvariant(), rootPath=root, status="complete" };
        var records=new Dictionary<string,DiskPulseFastRecord>(StringComparer.OrdinalIgnoreCase);
        var rootFiles=new DiskPulseFastRecord { key=drive.ToUpperInvariant()+"|root-files", kind="rootFiles", displayPath=drive.ToUpperInvariant()+"\\（根目录文件）", path=Path.GetFullPath(rootPath), level=1 };
        records[rootFiles.key]=rootFiles;
        var stack=new Stack<Work>(); stack.Push(new Work(root,null));
        var pending=new Dictionary<string,int>(StringComparer.OrdinalIgnoreCase);
        long files=0, dirs=0, entries=0; int completed=0,total=0; bool rootEnumerated=false;
        var watch=System.Diagnostics.Stopwatch.StartNew(); long last=-1000;
        Action<string,string,bool> emit=(phase,path,force)=>{
            if(progress==null) return; long elapsed=watch.ElapsedMilliseconds;
            if(!force && elapsed-last<1000) return;
            double percent=!rootEnumerated ? -1 : (total==0 ? 100 : Math.Min(100,Math.Round((double)completed/total*100,1)));
            last=elapsed;
            try { progress(new DiskPulseFastProgress { phase=phase,drive=drive.ToUpperInvariant(),filesProcessed=files,directoriesProcessed=dirs,currentPath=path,elapsedMilliseconds=elapsed,completedTopLevel=completed,totalTopLevel=total,percentComplete=percent }); } catch {}
        };
        emit("starting",root,true);
        while(stack.Count>0) {
            var work=stack.Pop(); string directory=work.Path, top=work.Top; current=directory; dirs++; emit("scanning",current,false);
            try {
                foreach(FileSystemInfo info in new DirectoryInfo(directory).EnumerateFileSystemInfos()) {
                    string entry=info.FullName;
                    current=entry; entries++;
                    try {
                        var attrs=info.Attributes; bool isDir=info is DirectoryInfo;
                        if(!isDir) files++;
                        if((entries & 4095)==0) emit("scanning",current,false);
                        if((attrs & FileAttributes.ReparsePoint)!=0) { AddEvidence(result.excluded,entry,"reparse-point"); continue; }
                        string relative=entry.Substring(prefix.Length); string[] parts=relative.Split(new[]{'\\'},StringSplitOptions.RemoveEmptyEntries);
                        if(isDir) {
                            string name=Path.GetFileName(entry);
                            if(name.Equals("System Volume Information",StringComparison.OrdinalIgnoreCase) || name.Equals("$RECYCLE.BIN",StringComparison.OrdinalIgnoreCase)) { AddEvidence(result.excluded,entry,"configured-exclusion"); continue; }
                            for(int level=1;level<=Math.Min(2,parts.Length);level++) {
                                string p=root+"\\"+String.Join("\\",parts,0,level), key=Key(p);
                                if(!records.ContainsKey(key)) records[key]=DirectoryRecord(p,level);
                            }
                            string childTop=top;
                            if(parts.Length==1) { childTop=Key(entry); if(!pending.ContainsKey(childTop)) { pending[childTop]=0; total++; } }
                            if(childTop!=null) pending[childTop]++;
                            stack.Push(new Work(entry,childTop)); continue;
                        }
                        var file=(FileInfo)info; long length=file.Length; string write=file.LastWriteTimeUtc.ToString("o");
                        if(parts.Length==1) AddFile(rootFiles,length,write);
                        else for(int level=1;level<=Math.Min(2,parts.Length-1);level++) AddFile(records[Key(root+"\\"+String.Join("\\",parts,0,level))],length,write);
                    } catch(UnauthorizedAccessException) { AddEvidence(result.excluded,entry,"access-denied"); }
                    catch(Exception ex) { result.status="partial"; AddEvidence(result.errors,entry,ex.Message,"entry-disappeared"); AddEvidence(result.unavailable,entry,"entry-unavailable"); }
                }
                if(directory.Equals(root,StringComparison.OrdinalIgnoreCase)) { rootEnumerated=true; emit("scanning",current,true); }
            } catch(Exception ex) {
                if(directory.Equals(root,StringComparison.OrdinalIgnoreCase)) { AddEvidence(result.errors,directory,ex.Message,"enumeration-failed"); AddEvidence(result.unavailable,directory,"enumeration-failed"); result.status="failed"; rootFiles.enumerationComplete=false; rootFiles.childrenEnumerationComplete=false; break; }
                if(ex is UnauthorizedAccessException) AddEvidence(result.excluded,directory,"access-denied");
                else { AddEvidence(result.errors,directory,ex.Message,"enumeration-failed"); AddEvidence(result.unavailable,directory,"enumeration-failed"); result.status="partial"; }
                foreach(var record in records.Values) if(record.kind=="directory" && directory.StartsWith(record.displayPath,StringComparison.OrdinalIgnoreCase)) record.childrenEnumerationComplete=false;
            }
            if(top!=null && pending.ContainsKey(top) && --pending[top]==0) { completed++; emit("scanning",directory,false); }
        }
        watch.Stop(); emit(result.status=="failed"?"failed":"complete",current,true);
        result.records.AddRange(records.Values); result.enumerationComplete=result.status=="complete"; result.childrenEnumerationComplete=result.status=="complete";
        return result;
    }
}
'@
}

function Invoke-DirectoryScan {
    param(
        [string] $Drive,
        [string] $RootPath,
        [scriptblock] $BeforeEntry,
        [scriptblock] $ProgressCallback
    )

    if (-not $BeforeEntry) {
        $nativeCallback = if ($ProgressCallback) {
            [Action[DiskPulseFastProgress]]{
                param($progress)
                try { & $ProgressCallback $progress } catch { Write-Debug "DiskPulse progress callback failed: $($_.Exception.Message)" }
            }
        } else { $null }
        $native = [DiskPulseFastScanner]::Scan($Drive, $RootPath, $nativeCallback)
        return [PSCustomObject]@{
            drive                       = $native.drive
            rootPath                    = $native.rootPath
            status                      = $native.status
            enumerationComplete         = $native.enumerationComplete
            childrenEnumerationComplete = $native.childrenEnumerationComplete
            records                     = [object[]]$native.records
            excluded                    = [object[]]$native.excluded
            unavailable                 = [object[]]$native.unavailable
            errors                      = [object[]]$native.errors
        }
    }

    $root = [DiskPulseFastScanner]::NormalizeRoot($RootPath)
    $rootPrefix = if ($root.EndsWith('\')) { $root } else { $root + '\' }
    $records = New-Object 'Collections.Generic.Dictionary[string,object]' ([StringComparer]::OrdinalIgnoreCase)
    $errors = New-Object 'Collections.Generic.List[object]'
    $unavailable = New-Object 'Collections.Generic.List[object]'
    $excluded = New-Object 'Collections.Generic.List[object]'
    $rootFiles = New-RootFilesRecord $Drive $root
    $records[$rootFiles.key] = $rootFiles
    $stack = New-Object 'Collections.Generic.Stack[object]'
    $stack.Push([PSCustomObject]@{ Path = $root; TopLevelKey = $null })
    $pendingTopLevel = New-Object 'Collections.Generic.Dictionary[string,int]' ([StringComparer]::OrdinalIgnoreCase)
    $status = "complete"
    $filesProcessed = 0
    $directoriesProcessed = 0
    $entriesProcessed = 0
    $completedTopLevel = 0
    $totalTopLevel = 0
    $rootEnumerated = $false
    $currentPath = $root
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    $progressState = @{ LastUpdateMilliseconds = -1000 }
    $emitProgress = {
        param([string] $Phase, [string] $Path, [bool] $Force)
        if (-not $ProgressCallback) { return }
        $elapsed = $stopwatch.ElapsedMilliseconds
        if (-not $Force -and ($elapsed - $progressState.LastUpdateMilliseconds) -lt 1000) { return }
        $percent = if (-not $rootEnumerated) {
            -1
        }
        elseif ($totalTopLevel -eq 0) {
            100
        }
        else {
            [math]::Min(100, [math]::Round(($completedTopLevel / $totalTopLevel) * 100, 1))
        }
        $progressState.LastUpdateMilliseconds = $elapsed
        try {
            & $ProgressCallback ([PSCustomObject]@{
                phase                = $Phase
                drive                = $Drive.ToUpperInvariant()
                filesProcessed       = $filesProcessed
                directoriesProcessed = $directoriesProcessed
                currentPath          = $Path
                elapsedMilliseconds  = $elapsed
                completedTopLevel     = $completedTopLevel
                totalTopLevel         = $totalTopLevel
                percentComplete       = $percent
            })
        }
        catch {
            Write-Debug "DiskPulse progress callback failed: $($_.Exception.Message)"
        }
    }

    & $emitProgress "starting" $root $true

    while ($stack.Count -gt 0) {
        $work = $stack.Pop()
        $directory = [string]$work.Path
        $topLevelKey = [string]$work.TopLevelKey
        $directoriesProcessed++
        $currentPath = $directory
        & $emitProgress "scanning" $currentPath $false
        try {
            $entries = [IO.DirectoryInfo]::new($directory).EnumerateFileSystemInfos()
            foreach ($entry in $entries) {
                $currentPath = [string]$entry.FullName
                if ($entry -isnot [IO.DirectoryInfo]) { $filesProcessed++ }
                $entriesProcessed++
                if (($entriesProcessed -band 255) -eq 0) {
                    & $emitProgress "scanning" $currentPath $false
                }
                try {
                    if ($BeforeEntry) {
                        & $BeforeEntry $entry
                        $entry.Refresh()
                        if (-not $entry.Exists) { throw "Entry disappeared during scan." }
                    }
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
                        $childTopLevelKey = if ($parts.Count -eq 1) {
                            $key = Normalize-PathKey $entry.FullName
                            if (-not $pendingTopLevel.ContainsKey($key)) {
                                $pendingTopLevel[$key] = 0
                                $totalTopLevel++
                            }
                            $key
                        }
                        else {
                            $topLevelKey
                        }
                        if ($childTopLevelKey) {
                            $pendingTopLevel[$childTopLevelKey]++
                        }
                        $stack.Push([PSCustomObject]@{ Path = $entry.FullName; TopLevelKey = $childTopLevelKey })
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
                    if ($_.Exception -is [UnauthorizedAccessException]) {
                        $excluded.Add([PSCustomObject]@{ path = [string]$entry.FullName; reason = "access-denied" })
                    }
                    else {
                        $status = "partial"
                        $errors.Add([PSCustomObject]@{ path = [string]$entry.FullName; reason = $_.Exception.Message; kind = "entry-disappeared" })
                        $unavailable.Add([PSCustomObject]@{ path = [string]$entry.FullName; reason = "entry-unavailable" })
                    }
                }
            }
            if ($directory -eq $root) {
                $rootEnumerated = $true
                & $emitProgress "scanning" $currentPath $true
            }
        }
        catch {
            if ($directory -eq $root) {
                $errors.Add([PSCustomObject]@{ path = $directory; reason = $_.Exception.Message; kind = "enumeration-failed" })
                $unavailable.Add([PSCustomObject]@{ path = $directory; reason = "enumeration-failed" })
                $status = "failed"
                $rootFiles.enumerationComplete = $false
                $rootFiles.childrenEnumerationComplete = $false
                break
            }
            if ($_.Exception -is [UnauthorizedAccessException]) {
                $excluded.Add([PSCustomObject]@{ path = $directory; reason = "access-denied" })
            }
            else {
                $errors.Add([PSCustomObject]@{ path = $directory; reason = $_.Exception.Message; kind = "enumeration-failed" })
                $unavailable.Add([PSCustomObject]@{ path = $directory; reason = "enumeration-failed" })
                $status = "partial"
            }
            foreach ($record in $records.Values) {
                if ($record.kind -eq "directory" -and $directory.StartsWith($record.displayPath, [StringComparison]::OrdinalIgnoreCase)) {
                    $record.childrenEnumerationComplete = $false
                }
            }
        }
        if ($topLevelKey -and $pendingTopLevel.ContainsKey($topLevelKey)) {
            $pendingTopLevel[$topLevelKey]--
            if ($pendingTopLevel[$topLevelKey] -eq 0) {
                $completedTopLevel++
                & $emitProgress "scanning" $directory $true
            }
        }
    }

    $stopwatch.Stop()
    & $emitProgress $(if ($status -eq "failed") { "failed" } else { "complete" }) $currentPath $true

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
    $result = New-Object 'Collections.Generic.List[object]'
    foreach ($currentDrive in @($Current.drives)) {
        $candidates = @(Get-DriveHistoryCandidates -Snapshots $Snapshots -Drive $currentDrive.drive -Current $Current)
        $comparisons = New-Object 'Collections.Generic.List[object]'
        foreach ($candidate in $candidates) {
            $baselineDrive = @($candidate.drives | Where-Object { $_.drive -eq $currentDrive.drive }) | Select-Object -First 1
            $comparisons.Add((New-HistoryComparison -CurrentDrive $currentDrive -BaselineDrive $baselineDrive -BaselineSnapshot $candidate))
        }

        $timeline = @($candidates | Sort-Object { [datetime]$_.completedAt })
        if ($currentDrive.status -in @('baseline','complete')) { $timeline += $Current }
        $pairRows = New-Object 'Collections.Generic.List[object]'
        $trendKeys = @{}
        foreach ($snapshotItem in $timeline) {
            $driveItem = @($snapshotItem.drives | Where-Object { $_.drive -eq $currentDrive.drive }) | Select-Object -First 1
            foreach ($record in @($driveItem.records | Where-Object { $_.level -eq 1 })) {
                $trendKeys[[string]$record.key] = [pscustomobject]@{ key=$record.key; displayPath=$record.displayPath; level=[int]$record.level }
            }
        }
        for ($index = 1; $index -lt $timeline.Count; $index++) {
            $olderDrive = @($timeline[$index-1].drives | Where-Object { $_.drive -eq $currentDrive.drive }) | Select-Object -First 1
            $newerDrive = @($timeline[$index].drives | Where-Object { $_.drive -eq $currentDrive.drive }) | Select-Object -First 1
            foreach ($row in @(Compare-DriveRecords $newerDrive $olderDrive)) {
                $pairRows.Add([pscustomobject]@{ key=$row.key; state=$row.state; deltaBytes=[int64]$row.deltaBytes; at=[string]$timeline[$index].completedAt })
                if ($row.level -eq 2 -and $row.state -in @('created','changed','removed') -and [int64]$row.deltaBytes -ne 0) {
                    $trendKeys[[string]$row.key] = [pscustomobject]@{ key=$row.key; displayPath=$row.displayPath; level=[int]$row.level }
                }
            }
        }

        $trends = New-Object 'Collections.Generic.List[object]'
        foreach ($trendKey in $trendKeys.Values) {
            $samples = New-Object 'Collections.Generic.List[object]'
            foreach ($snapshotItem in $timeline) {
                $driveItem = @($snapshotItem.drives | Where-Object { $_.drive -eq $currentDrive.drive }) | Select-Object -First 1
                $record = @($driveItem.records | Where-Object { $_.key -eq $trendKey.key }) | Select-Object -First 1
                $samples.Add(@([string]$snapshotItem.completedAt,$(if($record){[int64]$record.sizeBytes}else{$null})))
            }
            $directoryComparisons = @($pairRows | Where-Object { $_.key -eq $trendKey.key })
            $classification = Get-DirectoryTrendClassification $directoryComparisons
            $seen = @($samples | Where-Object { $null -ne $_[1] })
            $trends.Add([pscustomobject]@{
                key=$trendKey.key; displayPath=$trendKey.displayPath; level=$trendKey.level
                samples=[object[]]$samples; cumulativeBytes=$classification.cumulativeBytes
                growthCount=$classification.growthCount; releaseCount=$classification.releaseCount
                occurrenceCount=$classification.occurrenceCount; comparisonCount=$classification.comparisonCount
                label=$classification.label
                firstSeen=if($seen.Count){$seen[0][0]}else{$null}; lastSeen=if($seen.Count){$seen[-1][0]}else{$null}
            })
        }

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
    [object[]]$result
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

function Should-RenderConsoleProgress {
    param(
        [Parameter(Mandatory=$true)] $Progress,
        [Parameter(Mandatory=$true)] $State
    )
    $isFirst = [int64]$State.LastRenderedMilliseconds -lt 0 -or [int64]$Progress.filesProcessed -eq 0
    $isFinal = [int]$Progress.totalTopLevel -ge 0 -and [int]$Progress.completedTopLevel -eq [int]$Progress.totalTopLevel
    $intervalElapsed = ([int64]$Progress.elapsedMilliseconds - [int64]$State.LastRenderedMilliseconds) -ge 1000
    if (-not ($isFirst -or $isFinal -or $intervalElapsed)) { return $false }
    $State.LastRenderedMilliseconds = [int64]$Progress.elapsedMilliseconds
    return $true
}

function Format-ScanProgressLine {
    param(
        [Parameter(Mandatory=$true)] $Progress,
        [int] $CompletedDrives = 0,
        [int] $TotalDrives = 1
    )
    $barWidth = 16
    $knownPercent = $Progress.percentComplete -ge 0 -and $TotalDrives -gt 0
    if ($knownPercent) {
        $driveFraction = [double]$Progress.percentComplete / 100
        $overallPercent = [math]::Max(0, [math]::Min(100, (($CompletedDrives + $driveFraction) / $TotalDrives) * 100))
        $filled = [math]::Min($barWidth, [math]::Floor($overallPercent * $barWidth / 100))
        $bar = (([string][char]0x2588) * $filled) + (([string][char]0x2591) * ($barWidth - $filled))
        $percentText = ('{0,3:N0}%' -f $overallPercent)
    }
    else {
        $bar = (([string][char]0x2591) * $barWidth)
        $percentText = '扫描中'
    }

    $prefix = '[{0}] {1} {2} | 文件 {3} | 目录 {4} | {5:N1} 秒 | ' -f $bar, $percentText, $Progress.drive,
        [int64]$Progress.filesProcessed, [int64]$Progress.directoriesProcessed, ([double]$Progress.elapsedMilliseconds / 1000)
    $path = [string]$Progress.currentPath
    $available = [math]::Max(0, 130 - $prefix.Length)
    if ($path.Length -gt $available) {
        if ($available -gt 1) { $path = ([string][char]0x2026) + $path.Substring($path.Length - ($available - 1)) }
        else { $path = '' }
    }
    return $prefix + $path
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
$runStopwatch = [Diagnostics.Stopwatch]::StartNew()
$scanStage = "初始化"
$consoleProgressState = @{ LastLength = 0; Active = $false; LastRenderedMilliseconds = -1 }
$clearConsoleProgress = {
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
$completedDrives = 0
$totalDrives = @($drives).Count
foreach ($d in $drives) {
    $scanStage = "扫描磁盘 $($d.DeviceID)"
    $capacity = $currentResults | Where-Object { $_.id -eq ($d.DeviceID -replace '\\','') } | Select-Object -First 1
    $consoleProgress = {
        param($progress)
        if (-not (Should-RenderConsoleProgress -Progress $progress -State $consoleProgressState)) { return }
        $line = Format-ScanProgressLine -Progress $progress -CompletedDrives $completedDrives -TotalDrives $totalDrives
        $width = [math]::Max($line.Length, $consoleProgressState.LastLength)
        Write-Host ("`r" + $line.PadRight($width)) -NoNewline
        $consoleProgressState.LastLength = $line.Length
        $consoleProgressState.Active = $true
    }
    $scan = Invoke-DirectoryScan -Drive $d.DeviceID -RootPath ($d.DeviceID + '\') -ProgressCallback $consoleProgress
    $completedDrives++
    $consoleProgressState.LastRenderedMilliseconds = -1
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
$reportStopwatch = [Diagnostics.Stopwatch]::StartNew()
$directoryResults = New-Object 'Collections.Generic.List[object]'
foreach ($driveSnapshot in $snapshot.drives) {
    $baselineSnapshot = Find-DriveBaseline -Snapshots @($priorSnapshots) -Drive $driveSnapshot.drive -Current $snapshot
    $baselineDrive = if ($baselineSnapshot) { $baselineSnapshot.drives | Where-Object drive -eq $driveSnapshot.drive | Select-Object -First 1 } else { $null }
    $changes = Compare-DriveRecords $driveSnapshot $baselineDrive
    $directoryResults.Add([PSCustomObject]@{ drive=$driveSnapshot.drive; status=$driveSnapshot.status; baselineScanId=if($baselineSnapshot){$baselineSnapshot.scanId}else{$null}; baselineCompletedAt=if($baselineSnapshot){$baselineSnapshot.completedAt}else{$null}; changes=$changes; coverage=Get-ChangeCoverage $driveSnapshot $baselineDrive $changes; errors=$driveSnapshot.errors; unavailable=$driveSnapshot.unavailable; excluded=$driveSnapshot.excluded })
}
$historyCenter = New-HistoryComparisonCenter -Snapshots @($priorSnapshots) -Current $snapshot
Invoke-SnapshotRetention $paths (@($priorSnapshots)+@($snapshot)) @($snapshot.drives.drive) $scanId

$historyRows = [System.Collections.Generic.List[PSObject]](($historyRows |
    Sort-Object Timestamp -Descending |
    Select-Object -First $maxHistoryRows |
    Sort-Object Timestamp))

$historyRows | Export-Csv $logFile -NoTypeInformation -Force -Encoding UTF8

$jsonArray = ConvertTo-JsonArray $currentResults
$historyJson = ConvertTo-JsonArray $historyRows
$directoryJson = ConvertTo-JsonArray ([object[]]$directoryResults)
$historyCenterJson = ConvertTo-JsonArray ([object[]]$historyCenter)
$scanMetaJson = $snapshot | Select-Object scanId,startedAt,completedAt,status,@{n='driveCount';e={@($_.drives).Count}} | ConvertTo-Json -Compress
$timestampJson = ConvertTo-Json -InputObject ([string]$timestamp) -Compress
$systemDriveJson = ConvertTo-Json -InputObject ([string]$env:SystemDrive) -Compress
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
    --bg: #f5f7fb;
    --panel: #ffffff;
    --text: #111827;
    --muted: #667085;
    --subtle: #98a2b3;
    --line: #e4e9f1;
    --track: #f1f4f8;
    --blue: #3370ff;
    --green: #079669;
    --orange: #f07818;
    --red: #dc2626;
    --unknown: #64748b;
    --shadow: 0 8px 28px rgba(31,51,84,.06);
    --radius: 16px;
    color-scheme: light;
  }

  [data-theme="dark"] {
    --bg: #0b1220;
    --panel: #111a2b;
    --text: #f3f6fa;
    --muted: #94a3b8;
    --line: #26344a;
    --track: #18243a;
    --blue: #6b96ff;
    --green: #059669;
    --orange: #d97706;
    --red: #dc2626;
    --unknown: #64748b;
    color-scheme: dark;
  }
  [data-theme="dark"] .badge { background: color-mix(in srgb, var(--accent) 20%, transparent); }
  [data-theme="dark"] .mini { background: var(--track); }
  [data-theme="dark"] .ring { background: conic-gradient(var(--blue) calc(var(--pct) * 1%), var(--track) 0); }
  [data-theme="dark"] .ring::after { background: var(--panel); }

  body {
    font-family: "Segoe UI", -apple-system, BlinkMacSystemFont, "Helvetica Neue", Arial, sans-serif;
    background: var(--bg);
    color: var(--text);
    min-height: 100vh;
    padding: 32px 20px 56px;
    overflow-x: hidden;
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

  .action-group { display: flex; align-items: center; gap: 8px; flex-wrap: wrap; }
  .action-group + .action-group { padding-left: 8px; }

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
    display: block;
    margin: 0;
  }

  .card {
    background: var(--panel);
    border: 0;
    border-radius: 16px;
    box-shadow: none;
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
    color: var(--muted);
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

  /* Product dashboard: one authoritative component layer. */
  body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI Variable", "Segoe UI", "Microsoft YaHei UI", "Microsoft YaHei", sans-serif; padding: 22px 24px 48px; letter-spacing: -.005em; }
  .shell { width: min(1540px, calc(100% - 20px)); }
  .dashboard-shell { background:var(--panel); border:1px solid var(--line); border-radius:16px; box-shadow:0 10px 34px rgba(31,51,84,.07); overflow:hidden; }
  body { padding:6px 10px 28px; }
  .product-header { display:flex; align-items:center; justify-content:space-between; gap:24px; margin:0; padding:18px 22px 14px; }
  .header-brand { display:flex; align-items:center; gap:13px; min-width:260px; }
  .brand-mark { width:48px; height:48px; flex:0 0 auto; filter:drop-shadow(0 6px 10px rgba(51,112,255,.2)); }
  h1 { font-size: 27px; line-height:1.12; letter-spacing: -.025em; font-weight: 780; }
  .product-subtitle { color:var(--muted); font-size:14px; margin-top:4px; }
  .eyebrow { color: var(--muted); letter-spacing: .04em; text-transform: none; font-size: 12px; margin-bottom: 5px; }
  .timestamp { margin-top: 7px; }
  .actions { gap: 14px; }
  .action-group { gap:7px; }
  .search, .select, .button, .toggle { height: 42px; border-color: var(--line); background: var(--panel); border-radius: 10px; font-size:13px; transition: background-color 170ms ease, border-color 170ms ease, box-shadow 170ms ease; }
  .action-search .search { width:220px; } .action-search .select { min-width:142px; }
  .search:hover, .select:hover, .button:hover, .toggle:hover { background: color-mix(in srgb, var(--panel) 86%, var(--blue)); }
  .search:focus-visible, .select:focus-visible, .button:focus-visible, .toggle:focus-within, .copy-path:focus-visible, summary:focus-visible { outline: 3px solid color-mix(in srgb, var(--blue) 35%, transparent); outline-offset: 2px; }
  .section-intro { display: flex; justify-content: space-between; align-items: end; gap: 16px; margin: 22px 20px 10px; }
  .section-intro h2 { font-size: 18px; letter-spacing: -.015em; }
  .section-intro p { color: var(--muted); font-size: 13px; }
  .change-list { border: 1px solid var(--line); border-radius: var(--radius); box-shadow: var(--shadow); }
  .directory-overview { margin-top: 0; }
  .change-metrics { gap: 1px; overflow: hidden; border-radius: 12px; background: var(--line); }
  .change-metric { border-radius: 0; background: var(--track); padding: 14px 16px; }
  .change-controls { margin: 14px 0 10px; }
  .change-controls label { font-weight: 600; }
  .change-lists { gap: 10px; align-items: start; }
  .change-list { padding: 18px 18px 8px; min-height: 0; }
  .change-list-heading { display: flex; align-items: center; justify-content: space-between; gap: 12px; }
  .list-empty-note { color: var(--muted); font-size: 12px; font-weight: 600; }
  .state-change-list { margin-top: 10px; }
  .change-item { min-height: 48px; }
  .growth-value { color: var(--orange); }
  .release-value { color: var(--green); }
  .copy-path { color: var(--blue); font-weight: 600; border-radius: 7px; }
  .copy-path:hover { background: color-mix(in srgb, var(--blue) 10%, transparent); }
  .scan-details { background: var(--panel); border-radius: var(--radius); padding: 16px 18px; }
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
  @media (prefers-reduced-motion: reduce) {
    *, *::before, *::after { scroll-behavior: auto !important; transition-duration: 0s !important; animation-duration: 0s !important; }
    .summary-card:hover, .attention-item:hover { transform: none !important; }
    .bar-fill, .intensity-fill, .capacity-ratio-fill { transition: none !important; }
  }

  /* Dashboard hierarchy: semantic color, quiet surfaces, no decorative motion. */
  .summary-grid { display: grid; grid-template-columns: 31fr 37fr 32fr; grid-template-areas: "capacity change confidence"; gap: 16px; margin: 6px 20px 14px; }
  .summary-card, .scan-metadata { background: var(--panel); border: 1px solid var(--line); border-radius: var(--radius); padding: 22px; min-width: 0; box-shadow:var(--shadow); }
  .summary-card { transition: transform 160ms ease, border-color 160ms ease; }
  .summary-card:hover { transform: translateY(-2px); }
  .capacity-summary { grid-area: capacity; }
  .latest-change { grid-area: change; background:linear-gradient(135deg,#fff 0%,#f2f6ff 100%); border-color:#8db0ff; box-shadow:0 12px 32px rgba(51,112,255,.12); }
  [data-theme="dark"] .latest-change { background: linear-gradient(145deg,#16213a,#111a2b); border-color:#385b9b; }
  .comparison-confidence { grid-area: confidence; }
  .summary-label { color: var(--muted); font-size: 12px; font-weight: 700; margin-bottom: 14px; }
  .latest-change .summary-label, .latest-change .summary-note { color: var(--muted); }
  .summary-title { font-size: 20px; letter-spacing: -.02em; margin-bottom: 8px; }
  .summary-note { color: var(--muted); font-size: 12px; line-height: 1.55; }
  .capacity-layout { display: grid; grid-template-columns: 132px 1fr; gap: 18px; align-items: center; }
  .capacity-layout .ring { width: 132px; } .capacity-layout .ring::after { inset:14px; }
  .capacity-layout .ring span { font-size: 28px; }
  .capacity-layout .summary-title { font-size: 18px; }
  .summary-facts { display: grid; grid-template-columns: repeat(3,minmax(0,1fr)); gap: 8px; margin-top: 18px; }
  .summary-fact { min-width: 0; }
  .summary-fact span { color: var(--muted); display: block; font-size: 11px; margin-bottom: 3px; }
  .summary-fact b { font-size: 17px; }
  .change-hero { display: flex; align-items: baseline; gap: 10px; flex-wrap: wrap; margin: 3px 0 12px; }
  .change-hero { margin:12px 0 18px; justify-content:space-between; }
  .change-hero b { font-size: clamp(42px,3.8vw,56px); color:var(--blue); letter-spacing: -.045em; white-space:nowrap; }
  .latest-change .change-metrics { background: var(--line); }
  .latest-change .change-metric { background: color-mix(in srgb,var(--panel) 82%,var(--blue)); }
  .latest-change .change-metric span { color: var(--muted); }
  .reliability-badge, .status-badge { display: inline-flex; align-items: center; width: fit-content; border-radius: 999px; padding: 6px 9px; font-size: 11px; font-weight: 700; }
  .reliability-badge { color: var(--green); background: transparent; padding:10px 0 0; }
  .confidence-count { font-size: 34px; font-weight: 800; letter-spacing: -.04em; margin: 4px 0; }
  .summary-card-link { display:flex; justify-content:space-between; align-items:center; } .summary-link { color:var(--blue); font-size:12px; font-weight:700; text-decoration:none; }
  .confidence-body { display:grid; grid-template-columns:1fr 118px; align-items:center; min-height:190px; } .confidence-list { display:grid; gap:9px; margin-top:14px; font-size:12px; color:var(--muted); } .confidence-illustration { width:108px; height:108px; border-radius:50%; background:#f5f8ff; border:1px solid #e3eafe; display:grid; place-items:center; position:relative; color:var(--blue); } .confidence-stack { font-size:50px; transform:rotate(90deg); } .confidence-check { position:absolute; right:9px; bottom:13px; width:26px; height:26px; display:grid; place-items:center; border-radius:50%; color:#fff; background:var(--green); font-size:16px; }
  .confidence-state.complete { color: var(--green); } .confidence-state.waiting { color: var(--unknown); }
  .confidence-state.partial { color: var(--orange); } .confidence-state.failed { color: var(--red); }
  .directory-overview { margin:0 20px; }
  .change-controls { display:grid; grid-template-columns:repeat(5,minmax(0,1fr)); padding:8px 12px; background:var(--track); border:1px solid var(--line); border-radius:12px; margin:8px 0 10px; }
  .change-controls .select, .change-controls .search { width: 100%; min-width: 0; background: var(--track); }
  .change-item { grid-template-columns: minmax(0,1fr) auto; gap: 8px 12px; }
  .change-main { min-width: 0; }
  .change-path { display: block; font-weight: 650; }
  .change-context { color: var(--muted); font-size: 11px; margin-top: 4px; }
  .change-side { display: flex; gap: 9px; align-items: center; }
  .change-lists.only-growth, .change-lists.only-release, .change-lists.both-empty { grid-template-columns: minmax(0,1fr); }
  .change-lists.only-growth .release-panel, .change-lists.only-release .growth-panel, .change-lists.both-empty .release-panel { display: none; }
  .intensity-track { grid-column: 1/-1; height: 3px; border-radius: 99px; background: var(--track); overflow: hidden; }
  .intensity-fill { display: block; height: 100%; width: var(--intensity); background: currentColor; transition: width 160ms ease; }
  .contribution { color: var(--muted); font-size: 11px; white-space: nowrap; }
  .disk-scan-layout { margin:22px 20px 0; display:grid; grid-template-columns:minmax(0,7fr) minmax(280px,3fr); gap:16px; align-items:start; }
  .disk-detail-panel, .scan-summary-panel { min-width:0; border:1px solid var(--line); border-radius:var(--radius); background:var(--panel); box-shadow:var(--shadow); }
  .disk-detail-panel .section-intro, .scan-summary-panel .section-intro { margin:16px 18px 12px; }
  .grid { grid-template-columns: repeat(3,minmax(0,1fr)); }
  .disk-card-grid { padding:0 14px 14px; gap:10px; }
  .card { min-width:0; padding:16px; border:1px solid var(--line); box-shadow:none; }
  .card-top-actions { display: flex; gap: 8px; align-items: center; }
  .status-badge.complete { color: var(--green); background: color-mix(in srgb,var(--green) 11%,transparent); }
  .status-badge.waiting { color: var(--unknown); background: color-mix(in srgb,var(--unknown) 13%,transparent); }
  .status-badge.partial { color: var(--orange); background: color-mix(in srgb,var(--orange) 11%,transparent); }
  .status-badge.failed { color: var(--red); background: color-mix(in srgb,var(--red) 11%,transparent); }
  .directory-card-extra .top-paths { display:none; }
  .top-paths { display: grid; gap: 8px; margin-top: 10px; }
  .top-path-row { display: grid; grid-template-columns: minmax(0,1fr) auto auto; gap: 8px; align-items: center; min-width: 0; }
  .top-path-name { overflow: hidden; white-space: nowrap; text-overflow: ellipsis; min-width: 0; }
  .drive-details { border-top: 1px solid var(--line); margin-top: 14px; padding-top: 12px; }
  .drive-details summary { cursor: pointer; font-size: 12px; font-weight: 700; }
  .drive-details-body { display: grid; gap: 12px; margin-top: 12px; color: var(--muted); font-size: 12px; }
  .detail-groups { display: grid; grid-template-columns: 1fr 1fr; gap: 12px; }
  .detail-group { background: var(--track); border-radius: 10px; padding: 12px; min-width: 0; }
  .detail-group ul { margin: 7px 0 0 17px; }
  .scan-summary-card { display:grid; grid-template-columns:1fr; gap:0; margin:0; border:0; box-shadow:none; padding:0 18px 12px; }
  .scan-summary-card .metadata-item { display:flex; align-items:center; justify-content:space-between; padding:10px 0; border-top:1px solid var(--line); } .scan-summary-card .metadata-item span { margin:0; } .scan-summary-card .metadata-item b { font-size:12px; text-align:right; }
  .scan-details { margin:0; border:0; border-top:1px solid var(--line); border-radius:0; padding:12px 18px 16px; }
  .scan-completeness-grid { display: grid; grid-template-columns: 1fr 1fr; gap: 12px; }
  .scan-metadata { display: grid; grid-template-columns: repeat(5,minmax(0,1fr)); gap: 12px; margin-top: 12px; }
  .metadata-item span { display: block; color: var(--muted); font-size: 11px; margin-bottom: 4px; }
  .metadata-item b { display: block; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; font-size: 12px; }
  .snapshot-value { display: flex; align-items: center; gap: 6px; min-width: 0; }

  @media (max-width: 1500px) {
    .grid { grid-template-columns: repeat(2,minmax(0,1fr)); }
  }

  @media (max-width: 980px) {
    .summary-grid { grid-template-columns: 1.05fr .9fr; grid-template-areas: "capacity confidence" "change change"; }
    .change-controls { grid-template-columns: repeat(3,minmax(0,1fr)); }
  }

  .empty {
    display: none;
    padding: 26px;
    text-align: center;
    color: var(--muted);
    background: var(--panel);
    border: 1px dashed var(--line);
    border-radius: 8px;
  }

  .history-intro { display:none; }
  .history-details { margin:0 20px 22px; border:1px solid var(--line); border-radius:var(--radius); background:var(--panel); box-shadow:var(--shadow); }
  .history-summary-overview { margin:22px 20px 12px; padding:8px 14px; border:1px solid var(--line); border-radius:var(--radius); background:var(--panel); box-shadow:var(--shadow); }
  .history-summary-overview .history-summary { margin:8px 0; }
  .history-details > summary { min-height:54px; display:flex; align-items:center; padding:0 20px; cursor:pointer; color:var(--blue); font-size:13px; font-weight:700; }
  .history-details[open] > summary { border-bottom:1px solid var(--line); }
  .history-center { padding: 18px; }
  .history-head { display: flex; align-items: flex-end; justify-content: space-between; gap: 16px; margin-bottom: 14px; }
  .history-head p, .history-range-note, .history-empty { color: var(--muted); font-size: 13px; line-height: 1.6; }
  .history-controls { display: flex; align-items: flex-end; gap: 10px; flex-wrap: wrap; }
  .history-controls label { color: var(--muted); display: grid; font-size: 12px; gap: 5px; }
  .history-custom { display: flex; gap: 8px; flex-wrap: wrap; }
  .history-summary { display: grid; grid-template-columns: repeat(4,minmax(0,1fr)); gap: 10px; margin: 14px 0; }
  .history-rail { grid-template-columns:repeat(6,minmax(0,1fr)); gap:0; margin:0; align-items:center; }
  .history-metric { background: var(--bg); border: 1px solid var(--line); border-radius: 9px; padding: 11px; min-width: 0; }
  .history-rail .history-metric { background:transparent; border:0; border-left:1px solid var(--line); border-radius:0; padding:4px 16px; min-height:44px; } .history-rail .history-metric:first-child { border-left:0; padding-left:10px; }
  .history-metric span { color: var(--muted); display: block; font-size: 11px; margin-bottom: 5px; }
  .history-metric b { display: block; font-size: 15px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .history-tabs { border-bottom: 1px solid var(--line); display: flex; gap: 4px; margin-top: 4px; }
  .history-tab { background: transparent; border: 0; border-bottom: 2px solid transparent; color: var(--muted); cursor: pointer; font: inherit; font-size: 13px; font-weight: 700; min-height: 44px; padding: 0 14px; }
  .history-tab:hover { color: var(--text); }
  .history-tab:focus-visible { outline: 2px solid var(--blue); outline-offset: -2px; }
  .history-tab.is-active { border-bottom-color: var(--blue); color: var(--text); }
  .history-panels { padding-top: 12px; }
  .history-column { border: 1px solid var(--line); border-radius: 10px; padding: 12px; min-width: 0; }
  .history-column h3 { font-size: 14px; margin-bottom: 8px; }
  .history-row { border-top: 1px solid var(--line); display: grid; gap: 6px; padding: 12px 0; }
  .history-row:first-child { border-top: 0; }
  .history-row-main { display: flex; align-items: baseline; justify-content: space-between; gap: 10px; min-width: 0; }
  .history-row-main span { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .history-row-meta { color: var(--muted); display: flex; font-size: 12px; gap: 8px; line-height: 1.55; flex-wrap: wrap; }
  .history-spark { height: 26px; width: 100%; }
  .history-spark path { fill: none; stroke: var(--blue); stroke-width: 2; vector-effect: non-scaling-stroke; }
  .history-expand { background: transparent; border: 0; color: var(--blue); cursor: pointer; display: block; font: inherit; font-size: 12px; font-weight: 700; margin: 8px auto 0; min-height: 44px; padding: 0 16px; }
  .history-expand:hover { text-decoration: underline; }
  .history-expand:focus-visible { outline: 2px solid var(--blue); outline-offset: 2px; }
  .history-expand[hidden] { display: none; }
  .directory-trends { border-top: 1px solid var(--line); margin-top: 12px; padding-top: 10px; }
  .directory-trends > b { display: block; margin-bottom: 6px; }

  #overview-section, #attention-center, #change-details, #capacity-visuals, #history-center, #drive-details-section, #scan-completeness { scroll-margin-top: 76px; }
  .section-nav { position: sticky; top: 0; z-index: 20; display: flex; gap: 6px; overflow-x: auto; margin: 0 0 22px; padding: 0 4px; min-height:48px; border-top: 1px solid var(--line); border-bottom:1px solid var(--line); background: color-mix(in srgb,var(--bg) 92%,transparent); backdrop-filter:blur(14px); scrollbar-width: none; }
  .section-nav::-webkit-scrollbar { display: none; }
  .section-nav a { flex: 0 0 auto; min-height: 47px; display: inline-flex; align-items: center; padding: 0 16px; border-bottom:2px solid transparent; color: var(--muted); font-size: 13px; font-weight: 650; text-decoration: none; }
  .section-nav a:first-child { color:var(--blue); border-bottom-color:var(--blue); }
  .section-nav a:hover { color: var(--blue); }
  .section-nav a:focus-visible, .capacity-drive-row:focus-visible, .range-buttons button:focus-visible, .attention-item:focus-visible { outline: 3px solid color-mix(in srgb,var(--blue) 38%,transparent); outline-offset: 2px; }
  .overview-scan-state { display: inline-flex; align-items: center; width: fit-content; margin-top: 12px; padding: 6px 9px; border-radius: 999px; color: var(--text); background: var(--track); font-size: 11px; font-weight: 700; text-decoration: none; }
  .overview-scan-state.complete { color: var(--green); }
  .overview-scan-state.partial { color: var(--orange); }
  .overview-scan-state.failed { color: var(--red); }
  .overview-scan-state.waiting, .overview-scan-state.unknown { color: var(--unknown); }
  .attention-strip { margin:0 20px; padding:0; border:1px solid color-mix(in srgb,var(--orange) 42%,var(--line)); border-radius:var(--radius); background:color-mix(in srgb,var(--orange) 5%,var(--panel)); }
  .attention-strip .section-intro { display:none; }
  .attention-list { display: grid; grid-template-columns: repeat(3,minmax(0,1fr)); gap: 10px; }
  .attention-list[data-count="1"] { grid-template-columns: minmax(0,1fr); }
  .attention-list[data-count="2"] { grid-template-columns: repeat(2,minmax(0,1fr)); }
  .attention-item { display:grid; grid-template-columns:auto auto auto minmax(0,1fr) auto; gap:14px; align-items:center; min-height:68px; padding:12px 18px; border:0; border-radius:var(--radius); background:transparent; color:var(--text); text-decoration:none; transition:background 160ms ease; }
  .attention-heading { font-weight:750; padding-right:14px; border-right:1px solid color-mix(in srgb,var(--orange) 36%,var(--line)); } .attention-severity { color:var(--orange); background:color-mix(in srgb,var(--orange) 10%,transparent); border:1px solid color-mix(in srgb,var(--orange) 23%,transparent); border-radius:999px; padding:4px 9px; font-size:11px; font-weight:700; }
  .attention-item:hover { transform: translateY(-1px); border-color: color-mix(in srgb,var(--text) 22%,var(--line)); }
  .attention-marker { display: inline-flex; align-items: center; justify-content: center; min-width: 42px; height: 28px; padding: 0 8px; border-radius: 999px; background: var(--track); font-size: 11px; font-weight: 800; }
  .attention-item.critical .attention-marker { color: var(--red); background: color-mix(in srgb,var(--red) 11%,transparent); }
  .attention-item.warning .attention-marker { color: var(--orange); background: color-mix(in srgb,var(--orange) 11%,transparent); }
  .attention-item.info .attention-marker { color: var(--blue); background: color-mix(in srgb,var(--blue) 11%,transparent); }
  .attention-item.good .attention-marker { color: var(--green); background: color-mix(in srgb,var(--green) 11%,transparent); }
  .attention-copy { min-width: 0; }
  .attention-copy b, .attention-copy small { display: block; }
  .attention-copy b { font-size: 14px; }
  .attention-copy small { margin-top: 4px; color: var(--muted); font-size: 12px; line-height: 1.45; overflow-wrap: anywhere; }
  .attention-arrow { color: var(--blue); font-size: 12px; font-weight: 700; }
  .capacity-visuals { margin:0 20px; } .capacity-visuals .section-intro { margin-left:0; margin-right:0; }
  .capacity-visual-grid { display: grid; grid-template-columns: minmax(280px,25fr) minmax(0,75fr); gap: 16px; }
  .capacity-panel { min-width: 0; padding: 20px; border: 1px solid var(--line); border-radius: var(--radius); background: var(--panel); box-shadow:var(--shadow); }
  .panel-heading { display: flex; align-items: flex-start; justify-content: space-between; gap: 12px; margin-bottom: 14px; }
  .panel-heading h3 { font-size: 16px; }
  .panel-heading p { margin-top: 4px; color: var(--muted); font-size: 12px; }
  .trend-heading { align-items: flex-end; }
  .capacity-drive-list { display: grid; gap: 8px; }
  .capacity-drive-row { width: 100%; min-height: 92px; display: grid; gap: 8px; padding: 13px; border: 1px solid transparent; border-radius: 11px; background: var(--track); color: var(--text); font: inherit; text-align: left; cursor: pointer; }
  .capacity-drive-row:hover { border-color: color-mix(in srgb,var(--blue) 45%,var(--line)); background: color-mix(in srgb,var(--blue) 7%,var(--panel)); }
  .capacity-drive-row.is-selected { border-color: var(--blue); background: color-mix(in srgb,var(--blue) 12%,var(--panel)); }
  .capacity-drive-head { display: grid; grid-template-columns: auto auto auto 1fr; align-items: center; gap: 8px; }
  .capacity-drive-head strong { justify-self: end; }
  .capacity-current { padding: 3px 7px; border-radius: 999px; color: #fff; background: var(--blue); font-size: 10px; font-weight: 800; }
  .capacity-current.is-placeholder { visibility: hidden; }
  .capacity-drive-state { padding: 3px 6px; border-radius: 999px; font-size: 10px; font-weight: 800; }
  .capacity-drive-state.critical { color: var(--red); background: color-mix(in srgb,var(--red) 11%,transparent); }
  .capacity-drive-state.warning { color: var(--orange); background: color-mix(in srgb,var(--orange) 11%,transparent); }
  .capacity-drive-state.good { color: var(--green); background: color-mix(in srgb,var(--green) 11%,transparent); }
  .capacity-ratio-track { display: block; height: 8px; overflow: hidden; border-radius: 999px; background: var(--panel); }
  .capacity-ratio-fill { display: block; height: 100%; border-radius: inherit; background: var(--blue); transition: width 160ms cubic-bezier(.22,1,.36,1); }
  .capacity-drive-row.warning .capacity-ratio-fill { background: var(--orange); }
  .capacity-drive-row.critical .capacity-ratio-fill { background: var(--red); }
  .capacity-drive-facts { color: var(--muted); font-size: 11px; line-height: 1.4; }
  .range-buttons { display: inline-flex; gap: 3px; padding: 3px; border-radius: 9px; background: var(--track); }
  .range-buttons button { min-height: 36px; padding: 0 10px; border: 0; border-radius: 7px; background: transparent; color: var(--muted); font: inherit; font-size: 11px; font-weight: 700; cursor: pointer; }
  .range-buttons button[aria-pressed="true"] { background: var(--panel); color: var(--text); box-shadow: 0 1px 4px rgba(15,23,42,.08); }
  .capacity-trend-stats { float:right; width:174px; display:grid; grid-template-columns:1fr; gap:0; margin:4px 0 0 20px; border:1px solid var(--line); border-radius:12px; overflow:hidden; }
  .capacity-stat { min-width: 0; padding: 10px 14px; border-top:1px solid var(--line); background: var(--panel); }
  .capacity-stat:first-child { border-top:0; }
  .capacity-stat span, .capacity-stat b { display: block; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .capacity-stat span { color: var(--muted); font-size: 10px; }
  .capacity-stat b { margin-top: 4px; font-size: 18px; }
  .capacity-trend-chart { min-height: 350px; display: grid; place-items: center; }
  .capacity-svg { width: 100%; height: auto; min-height: 250px; overflow: visible; }
  .capacity-grid-line { stroke: var(--line); stroke-width: 1; }
  .capacity-axis-label { fill: var(--muted); font-size: 10px; }
  .capacity-area { fill:url(#capacity-area-gradient); }
  .capacity-line { fill: none; stroke: var(--blue); stroke-width: 2.5; stroke-linecap: round; stroke-linejoin: round; vector-effect: non-scaling-stroke; }
  .capacity-point { fill: var(--panel); stroke: var(--blue); stroke-width: 1.7; vector-effect: non-scaling-stroke; }
  .capacity-empty { color: var(--muted); font-size: 13px; line-height: 1.5; text-align: center; }
  .print-meta { display: none; }
  .sr-only { position: absolute; width: 1px; height: 1px; padding: 0; margin: -1px; overflow: hidden; clip: rect(0,0,0,0); white-space: nowrap; border: 0; }

  body.compact .card { padding: 14px; }
  body.compact .meta { grid-template-columns: repeat(4, 1fr); }
  body.compact .spark-row { display: none; }

  .disk-scan-layout { display:grid; grid-template-columns:minmax(0,2.1fr) minmax(260px,.9fr); gap:16px; align-items:start; }
  .dashboard-footer {
    color: var(--muted);
    font-size: 12px;
    margin-top: 24px;
    padding:16px 4px 0;
    border-top:1px solid var(--line);
    text-align: left;
  }

  @media (max-width: 1100px) {
    header { align-items: stretch; flex-direction: column; }
    .actions { justify-content: flex-start; }
    .action-group + .action-group { padding-left: 0; }
  }

  @media (max-width: 900px) {
    header { align-items: stretch; flex-direction: column; }
    .actions { justify-content: flex-start; }
    .overview { grid-template-columns: repeat(2, minmax(0, 1fr)); }
    .summary-grid { grid-template-columns:1fr 1fr; grid-template-areas: "change change" "capacity confidence"; }
    .change-metrics, .change-lists { grid-template-columns: 1fr 1fr; }
    .grid { grid-template-columns: 1fr; }
    .history-summary { grid-template-columns: repeat(2,minmax(0,1fr)); }
    .attention-list, .capacity-visual-grid, .disk-scan-layout { grid-template-columns: 1fr; }
    .attention-list[data-count] { grid-template-columns: 1fr; }
  }

  @media (max-width: 560px) {
    body { padding: 24px 14px 40px; }
    .overview { grid-template-columns: 1fr; }
    .actions { display:grid; grid-template-columns:1fr; }
    .actions > * { width: 100%; }
    .action-group { display:grid; }
    .action-search { grid-template-columns: 1fr 1fr; }
    .action-display { grid-template-columns: 1fr 1fr; }
    .action-report { grid-template-columns: repeat(3,1fr); }
    .action-group > * { width: 100%; min-width:0; justify-content: center; }
    .meta { grid-template-columns: 1fr; }
    .change-metrics, .change-lists { grid-template-columns: 1fr; }
    body.compact .meta { grid-template-columns: 1fr 1fr; }
    header { gap: 10px; }
    .actions { gap: 8px; }
    .search, .select, .button, .toggle { height: 44px; font-size: 15px; padding: 0 16px; }
    .toggle { padding: 0 14px; }
    .toggle input { width: 20px; height: 20px; }
    .summary-grid { display: flex; flex-direction: column; }
    .latest-change { order: 1; } .capacity-summary { order: 2; } .comparison-confidence { order: 3; }
    .capacity-layout { grid-template-columns: 78px 1fr; } .capacity-layout .ring { width: 78px; }
    .summary-facts, .change-metrics, .change-controls, .scan-metadata, .scan-completeness-grid, .detail-groups { grid-template-columns: 1fr; }
    .change-side { align-items: flex-end; flex-direction: column; }
    .change-path.is-expanded, .top-path-name.is-expanded { white-space: normal; overflow-wrap: anywhere; }
    .top-path-row { grid-template-columns: minmax(0,1fr) auto; }
    .history-head { align-items: stretch; flex-direction: column; }
    .history-summary { grid-template-columns: 1fr; }
    .history-tabs { overflow-x: auto; }
    .history-tab { flex: 1 0 auto; }
    .section-nav { top: 6px; margin-top: -4px; }
    .attention-list { gap: 8px; }
    .attention-item { grid-template-columns: auto minmax(0,1fr); }
    .attention-arrow { display: none; }
    .trend-heading { align-items: stretch; flex-direction: column; }
    .range-buttons { width: 100%; }
    .range-buttons button { flex: 1; min-height: 44px; }
    .capacity-trend-stats { grid-template-columns: 1fr 1fr; }
    .capacity-trend-stats { float:none; width:100%; margin:0 0 12px; }
    .copy-path, .overview-scan-state { min-height:44px; }
  }

  @media print {
    :root, [data-theme="dark"] { --bg:#fff; --panel:#fff; --track:#f3f4f6; --line:#d1d5db; --text:#111827; --muted:#4b5563; --blue:#1d4ed8; --green:#047857; --orange:#b45309; --red:#b91c1c; color-scheme:light; }
    body { padding: 0; background: #fff; color: #111827; }
    .shell { width: 100%; }
    .actions, .section-nav, .change-controls, .copy-path, .range-buttons, .history-intro, #history-center, #scan-completeness, .drive-details, .history-expand { display: none !important; }
    header { margin-bottom: 18px; }
    .summary-card, .attention-item, .change-list, .capacity-panel, .card, .scan-metadata, .capacity-svg { break-inside: avoid; box-shadow: none !important; }
    .summary-card:hover, .attention-item:hover { transform: none; }
    .summary-grid, .attention-list, .capacity-visual-grid, .grid { grid-template-columns: 1fr 1fr; }
    .latest-change, [data-theme="dark"] .latest-change { background: #fff; color: #111827; border-color: #d1d5db; }
    .latest-change .summary-label, .latest-change .summary-note, .latest-change .change-metric span { color: #4b5563; }
    .latest-change .change-metrics, .latest-change .change-metric { background: #f3f4f6; }
    .print-meta { display: block; margin: 18px 0 0; color: #4b5563; font-size: 11px; }
    footer { margin-top: 12px; }
  }
</style>
</head>
<body>
<main class="shell dashboard-shell">
  <header class="product-header">
    <div class="header-brand">
      <svg class="brand-mark" viewBox="0 0 48 48" role="img" aria-labelledby="brand-title brand-desc"><title id="brand-title">DiskPulse</title><desc id="brand-desc">蓝色磁盘堆叠图标</desc><defs><linearGradient id="brand-gradient" x1="0" y1="0" x2="1" y2="1"><stop stop-color="#73a7ff"/><stop offset="1" stop-color="#3370ff"/></linearGradient></defs><ellipse cx="21" cy="12" rx="12" ry="5.5" fill="url(#brand-gradient)"/><path d="M9 12v8c0 3 5.4 5.5 12 5.5S33 23 33 20v-8c0 3-5.4 5.5-12 5.5S9 15 9 12Z" fill="#4b83f5"/><path d="M9 20v8c0 3 5.4 5.5 12 5.5S33 31 33 28v-8c0 3-5.4 5.5-12 5.5S9 23 9 20Z" fill="#3b73ef"/><path d="M9 28v8c0 3 5.4 5.5 12 5.5S33 39 33 36v-8c0 3-5.4 5.5-12 5.5S9 31 9 28Z" fill="#2f66db"/><circle cx="36" cy="34" r="8" fill="#fff"/><path d="m32.5 34 2.2 2.2 4.6-5" fill="none" stroke="#20b982" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"/></svg>
      <div><h1>磁盘容量看板</h1><p class="product-subtitle">系统存储监控与分析报告</p><div class="timestamp" id="ts"></div></div>
    </div>
    <div class="actions">
      <div class="action-group action-search" aria-label="搜索与排序">
        <input class="search" id="search" type="search" placeholder="筛选盘符" aria-label="筛选磁盘盘符">
        <select class="select" id="sort" aria-label="磁盘排序方式">
          <option value="percent-desc">使用率高到低</option>
          <option value="percent-asc">使用率低到高</option>
          <option value="free-asc">剩余空间少到多</option>
          <option value="name-asc">盘符排序</option>
          <option value="change-desc">增长最多</option>
        </select>
      </div>
      <div class="action-group action-display" aria-label="显示设置">
        <label class="toggle"><input id="compact" type="checkbox">紧凑模式</label>
        <button class="button" id="themeBtn" type="button" aria-label="切换主题">主题</button>
      </div>
      <div class="action-group action-report" aria-label="报告操作">
        <button class="button" id="copy" type="button">复制摘要</button>
        <button class="button" id="print-report" type="button">打印报告</button>
        <a class="button" href="DiskPulse.csv" download>下载历史</a>
      </div>
    </div>
  </header>

  <nav class="section-nav" id="section-nav" aria-label="看板分区导航">
    <a href="#overview-section">总览</a>
    <a href="#attention-center">关注</a>
    <a href="#change-details">本次变化</a>
    <a href="#capacity-visuals">容量趋势</a>
    <a href="#history-center">历史对比</a>
    <a href="#drive-details-section">磁盘详情</a>
    <a href="#scan-completeness">扫描信息</a>
  </nav>

  <section class="overview" id="overview-section" aria-label="磁盘摘要">
    <div class="summary-grid hero-grid" id="summary-grid">
      <article class="summary-card hero-card capacity-summary" id="capacity-summary"></article>
      <article class="summary-card hero-card hero-card-primary latest-change" id="latest-change"></article>
      <article class="summary-card hero-card comparison-confidence" id="comparison-confidence"></article>
    </div>
  </section>
  <section class="attention-section attention-strip" id="attention-center" aria-labelledby="attention-title">
    <div class="section-intro"><div><h2 id="attention-title">关注中心</h2><p>容量压力、可靠变化与扫描完整性</p></div></div>
    <div class="attention-list" id="attention-list"></div>
  </section>

  <section class="capacity-visuals" id="capacity-visuals" aria-labelledby="capacity-visuals-title">
    <div class="section-intro"><div><h2 id="capacity-visuals-title">容量趋势</h2><p>选择磁盘并查看真实历史样本</p></div></div>
    <div class="capacity-visual-grid">
      <article class="capacity-panel" aria-labelledby="capacity-drive-list-title">
        <div class="panel-heading"><div><h3 id="capacity-drive-list-title">磁盘选择与使用率</h3><p>按容量状态与使用率排列</p></div></div>
        <div class="capacity-drive-list" id="capacity-drive-select"></div>
      </article>
      <article class="capacity-panel trend-panel" aria-labelledby="capacity-trend-title">
        <div class="panel-heading trend-heading">
          <div><h3 id="capacity-trend-title">容量趋势</h3><p id="capacity-trend-caption">选择磁盘查看趋势</p></div>
          <div class="range-buttons" id="capacity-range" role="group" aria-label="容量趋势时间范围">
            <button type="button" data-capacity-range="7" aria-pressed="false">7 天</button>
            <button type="button" data-capacity-range="30" aria-pressed="true">30 天</button>
            <button type="button" data-capacity-range="90" aria-pressed="false">90 天</button>
            <button type="button" data-capacity-range="all" aria-pressed="false">全部</button>
          </div>
        </div>
        <div class="capacity-trend-stats" id="capacity-trend-stats"></div>
        <div class="capacity-trend-chart" id="capacity-trend-chart"></div>
      </article>
    </div>
  </section>

  <div class="section-intro"><div><h2>本次变化</h2><p>按可靠变化大小排序</p></div></div>
  <section class="directory-overview" id="change-details">
    <div class="change-controls">
      <label>磁盘<select class="select" id="change-drive-filter" aria-label="筛选磁盘"></select></label>
      <label>目录层级<select class="select" id="change-level-filter" aria-label="筛选目录层级"><option value="1">一级目录</option><option value="2">二级目录</option><option value="all">全部层级</option></select></label>
      <label>变化方向<select class="select" id="change-direction-filter" aria-label="筛选变化方向"><option value="all">全部变化</option><option value="growth">仅增长</option><option value="release">仅释放</option></select></label>
      <label>数据状态<select class="select" id="change-state-filter" aria-label="筛选数据状态"><option value="reliable">可靠变化</option><option value="unknown">未知</option><option value="unavailable">不可用</option></select></label>
      <label>路径搜索<input class="search" id="change-path-filter" type="search" placeholder="筛选目录路径" aria-label="筛选目录路径"></label>
    </div>
    <div class="change-lists">
      <div class="change-list change-ranking growth-panel"><div class="change-list-heading"><h3>Top 增长</h3><span class="list-empty-note" id="release-empty-note" hidden>本次没有明显释放</span></div><div id="growth-list"></div></div>
      <div class="change-list change-ranking release-panel"><div class="change-list-heading"><h3>Top 释放</h3><span class="list-empty-note" id="growth-empty-note" hidden>本次没有明显增长</span></div><div id="release-list"></div></div>
    </div>
    <div class="change-list state-change-list" id="state-change-list" hidden><h3 id="state-change-title">数据状态</h3><div id="state-change-body"></div></div>
  </section>

  <div class="section-intro history-intro"><div><h2>历史对比</h2><p>从既有完整快照比较累计变化</p></div></div>
  <section class="history-summary-overview history-summary-strip" id="history-summary-overview" aria-label="历史对比摘要">
    <div class="history-summary" id="history-summary"></div>
  </section>
  <details class="history-details" id="history-details">
    <summary>查看完整历史对比</summary>
  <section class="history-center history-summary-strip" id="history-center" aria-label="历史对比中心">
    <div class="history-head">
      <div><h3>比较范围</h3><p class="history-range-note" id="history-range-note"></p></div>
      <div class="history-controls"><label>时间范围<select class="select" id="history-range"><option value="previous">上一次完整扫描</option><option value="day">约 24 小时前</option><option value="week">约 7 天前</option><option value="earliest">最早可用快照</option><option value="custom">自选历史快照</option></select></label><div class="history-custom" id="history-custom"></div></div>
    </div>
    <div class="history-tabs" id="history-tabs" role="tablist" aria-label="历史榜单">
      <button class="history-tab is-active" id="history-growth-tab" type="button" role="tab" aria-selected="true" aria-controls="history-growth-panel" data-history-tab="growth">持续增长</button>
      <button class="history-tab" id="history-release-tab" type="button" role="tab" aria-selected="false" aria-controls="history-release-panel" data-history-tab="release">持续释放</button>
      <button class="history-tab" id="history-trend-tab" type="button" role="tab" aria-selected="false" aria-controls="history-trend-panel" data-history-tab="trend">历史变化</button>
    </div>
    <div class="history-panels">
      <div class="history-column" id="history-growth-panel" role="tabpanel" aria-labelledby="history-growth-tab"><h3>持续增长榜</h3><div id="sustained-growth-list"></div><button class="history-expand" type="button" data-history-list="growth">展开全部</button></div>
      <div class="history-column" id="history-release-panel" role="tabpanel" aria-labelledby="history-release-tab" hidden><h3>持续释放榜</h3><div id="sustained-release-list"></div><button class="history-expand" type="button" data-history-list="release">展开全部</button></div>
      <div class="history-column" id="history-trend-panel" role="tabpanel" aria-labelledby="history-trend-tab" hidden><h3>历史变化趋势</h3><div id="history-trend-list"></div><button class="history-expand" type="button" data-history-list="trend">展开全部</button></div>
    </div>
  </section>
  </details>

  <div class="disk-scan-layout" id="drive-details-section">
    <section class="disk-detail-panel"><div class="section-intro"><div><h2>磁盘详情</h2><p>容量摘要与近期变化</p></div><a class="summary-link" href="#grid">查看全部磁盘</a></div><section class="disk-card-grid"><section class="grid" id="grid"></section></section><div class="empty" id="empty">没有匹配的磁盘</div></section>
    <section class="scan-summary-panel" aria-label="扫描信息"><div class="section-intro"><div><h2>扫描信息</h2><p>本次扫描状态与范围</p></div></div><section class="scan-metadata" id="scan-metadata" aria-label="扫描元数据"></section><details class="scan-details" id="scan-completeness"><summary>查看扫描详情</summary><div id="scan-detail-body"></div></details></section>
  </div>
  <div class="print-meta" id="print-meta" aria-hidden="true"></div>
  <div class="sr-only" id="live-status" aria-live="polite"></div>
  <footer class="dashboard-footer" id="footer"></footer>
</main>

<script>
const RAW_DATA = INJECT_DATA;
const RAW_HISTORY = INJECT_HISTORY;
const RAW_DIRECTORY = INJECT_DIRECTORY;
const RAW_HISTORY_CENTER = INJECT_HISTORY_CENTER;
const RAW_SCAN_META = INJECT_SCAN_META;
const DATA = Array.isArray(RAW_DATA) ? RAW_DATA : RAW_DATA ? [RAW_DATA] : [];
const HISTORY = Array.isArray(RAW_HISTORY) ? RAW_HISTORY : RAW_HISTORY ? [RAW_HISTORY] : [];
const DIRECTORY = Array.isArray(RAW_DIRECTORY) ? RAW_DIRECTORY : RAW_DIRECTORY ? [RAW_DIRECTORY] : [];
const HISTORY_CENTER = Array.isArray(RAW_HISTORY_CENTER) ? RAW_HISTORY_CENTER : RAW_HISTORY_CENTER ? [RAW_HISTORY_CENTER] : [];
const SCAN_META = RAW_SCAN_META || {};
const TS = INJECT_TS_JSON;
const SYSTEM_DRIVE = INJECT_SYSTEM_DRIVE;

// TESTABLE_HISTORY_HELPERS_START
function selectHistoryComparison(disk, range, customScanId) {
  const scanId = range === "custom" ? customScanId : disk?.selections?.[range];
  return (disk?.comparisons || []).find((item) => item.scanId === scanId) || null;
}

function reliableHistoryRows(rows) {
  return (rows || []).filter((row) => ["created","changed","removed"].includes(row.state));
}

function defaultHistoryCustomScanId(disk) {
  return disk?.comparisons?.[0]?.scanId || null;
}

const historyListLimits = { growth: 5, release: 5, trend: 6 };
function visibleHistoryRows(rows, list, expanded) {
  return expanded?.[list] ? rows : rows.slice(0,historyListLimits[list]);
}
// TESTABLE_HISTORY_HELPERS_END

// TESTABLE_CAPACITY_HELPERS_START
function normalizeDriveId(value) {
  return String(value ?? "").replace(/\\/g, "").trim().toUpperCase();
}

function compareDriveId(a, b) {
  const left = normalizeDriveId(a), right = normalizeDriveId(b);
  return left < right ? -1 : left > right ? 1 : 0;
}

function capacityDriveOrder(drives) {
  const statusRank = { critical: 0, warning: 1, good: 2 };
  return [...drives].sort((a,b) =>
    (statusRank[a.status] ?? 3) - (statusRank[b.status] ?? 3) ||
    Number(b.percent || 0) - Number(a.percent || 0) ||
    compareDriveId(a.id,b.id)
  );
}

function defaultCapacityDrive(drives, systemDrive) {
  const critical = drives.filter((drive) => drive.status === "critical").sort((a,b) =>
    Number(b.percent || 0) - Number(a.percent || 0) ||
    Number(a.free || 0) - Number(b.free || 0) ||
    compareDriveId(a.id,b.id)
  );
  if (critical.length) return normalizeDriveId(critical[0].id);
  const wanted = normalizeDriveId(systemDrive);
  const system = drives.find((drive) => normalizeDriveId(drive.id) === wanted);
  if (system) return normalizeDriveId(system.id);
  return drives.length ? normalizeDriveId([...drives].sort((a,b) => compareDriveId(a.id,b.id))[0].id) : "";
}

function cleanCapacitySamples(history, current, driveId, reportTimestamp) {
  const wanted = normalizeDriveId(driveId);
  const rows = history.filter((row) => normalizeDriveId(row.ID) === wanted);
  if (current && normalizeDriveId(current.id) === wanted) {
    rows.push({ Timestamp: reportTimestamp, ID: current.id, Total: current.total, Used: current.used });
  }
  const byTime = new Map();
  rows.forEach((row) => {
    const time = Date.parse(row.Timestamp);
    const total = Number(row.Total), used = Number(row.Used);
    if (!Number.isFinite(time) || !Number.isFinite(total) || !Number.isFinite(used) || total <= 0 || used < 0 || used > total) return;
    byTime.set(time, { time, timestamp: String(row.Timestamp), total, used, percent: used / total * 100 });
  });
  return [...byTime.values()].sort((a,b) => a.time-b.time);
}

function filterCapacitySamples(samples, range, reportTimestamp) {
  if (range === "all") return [...samples];
  const days = Number(range);
  if (!Number.isFinite(days) || days <= 0 || !samples.length) return [];
  const reportTime = Date.parse(reportTimestamp);
  const end = Number.isFinite(reportTime) ? reportTime : samples[samples.length-1].time;
  const start = end - days * 86400000;
  return samples.filter((sample) => sample.time >= start && sample.time <= end);
}

function capacityTrendStats(samples) {
  if (!samples.length) return null;
  const used = samples.map((sample) => sample.used);
  return {
    first: samples[0], last: samples[samples.length-1], count: samples.length,
    min: Math.min(...used), max: Math.max(...used),
    change: samples.length > 1 ? samples[samples.length-1].used - samples[0].used : null
  };
}

function buildAttentionItems(drives, directoryItems, reliableRows) {
  const items = [];
  const critical = drives.filter((drive) => drive.status === "critical").sort((a,b) =>
    Number(a.free || 0) - Number(b.free || 0) || Number(b.percent || 0) - Number(a.percent || 0) || compareDriveId(a.id,b.id));
  const incomplete = directoryItems.filter((item) => item.status === "partial" || item.status === "failed");
  const warnings = drives.filter((drive) => drive.status === "warning").sort((a,b) =>
    Number(b.percent || 0) - Number(a.percent || 0) || compareDriveId(a.id,b.id));
  if (critical.length) items.push({ kind:"critical", tone:"critical", href:"#drive-details-section", title:`${critical.length} 个磁盘空间严重不足`, detail:`${normalizeDriveId(critical[0].id)} 仅剩 ${fmt(critical[0].free)}` });
  if (incomplete.length) items.push({ kind:"incomplete", tone:"warning", href:"#scan-completeness", title:`${incomplete.length} 个磁盘扫描不完整`, detail:"报告中的目录变化可能不完整，请查看详细原因" });
  if (warnings.length && items.length < 3) items.push({ kind:"warning", tone:"warning", href:"#drive-details-section", title:`${warnings.length} 个磁盘需要关注`, detail:`${normalizeDriveId(warnings[0].id)} 使用率 ${pct(warnings[0].percent)}` });
  const main = reliableRows.find((row) => isReliableChange(row) && Number(row.deltaBytes));
  if (main && items.length < 3) items.push({ kind:"change", tone:"info", href:"#change-details", title:main.deltaBytes > 0 ? "主要可靠增长" : "主要可靠释放", detail:`${main.displayPath} · ${main.deltaBytes > 0 ? "+" : ""}${fmtBytes(main.deltaBytes)}` });
  return items.length ? items.slice(0,3) : [{ kind:"clear", tone:"good", href:"#overview-section", title:"当前没有需要立即处理的问题", detail:"容量状态与扫描结果均未发现明显风险" }];
}
// TESTABLE_CAPACITY_HELPERS_END

const historyMap = {};
HISTORY.forEach((row) => {
  const id = normalizeDriveId(row.ID);
  if (!historyMap[id]) historyMap[id] = [];
  historyMap[id].push(row);
});
Object.values(historyMap).forEach((arr) =>
  arr.sort((a, b) => String(a.Timestamp).localeCompare(String(b.Timestamp)))
);

const state = {
  query: "",
  sort: "percent-desc",
  compact: false,
  driveLevels: {},
  historyRange: "previous",
  historyCustom: {},
  historyTab: "growth",
  historyExpanded: {},
  capacityDrive: defaultCapacityDrive(DATA,SYSTEM_DRIVE),
  capacityRange: "30"
};

const $ = (id) => document.getElementById(id);
const svgNs = "http://www.w3.org/2000/svg";

function element(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = String(text);
  return node;
}

function announce(message) {
  $("live-status").textContent = "";
  requestAnimationFrame(() => { $("live-status").textContent = message; });
}

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

function historyFor(id) {
  return historyMap[normalizeDriveId(id)] || [];
}

function sparkline(rows) {
  const samples = rows.slice(-20).map((row) => Number(row.Percent) || 0);
  const svg=document.createElementNS(svgNs,"svg"); svg.classList.add("spark"); svg.setAttribute("viewBox","0 0 120 38"); svg.setAttribute("preserveAspectRatio","none"); svg.setAttribute("aria-hidden","true");
  const path=document.createElementNS(svgNs,"path");
  if (samples.length < 2) { path.setAttribute("d","M2 28 L118 28"); svg.append(path); return svg; }
  const min = Math.min(...samples);
  const max = Math.max(...samples);
  const span = Math.max(1, max - min);
  const points = samples.map((value, index) => {
    const x = 2 + (index / (samples.length - 1)) * 116;
    const y = 34 - ((value - min) / span) * 30;
    return `${x.toFixed(1)} ${y.toFixed(1)}`;
  });
  path.setAttribute("d",`M${points.join(" L")}`); svg.append(path); return svg;
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
  const text = formatCapacityDelta(value);
  return element("span",text === "容量基本不变" ? "trend-st" : value > 0 ? "trend-up" : "trend-dn",text);
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

function directoryCoverage(id) {
  return DIRECTORY.find((item) => normalizeDriveId(item.drive) === normalizeDriveId(id))?.coverage || null;
}

// TESTABLE_CHANGE_HELPERS_START
const defaultChangeFilters = { drive: "all", level: "1", direction: "all", state: "reliable", query: "" };

function isReliableChange(row) {
  return ["created", "changed", "removed"].includes(row.state);
}

function reliableChanges(item, level) {
  return item && item.baselineScanId ? (item.changes || []).filter((row) => isReliableChange(row) && (!level || row.level === level)) : [];
}

function filterChangeRows(items, filters) {
  const level = filters.level === "all" ? null : Number(filters.level);
  const query = String(filters.query || "").trim().toLowerCase();
  return items.filter((item) => filters.drive === "all" || item.drive === filters.drive).flatMap((item) =>
    (item.changes || []).filter((row) => {
      const stateMatches = filters.state === "reliable" ? Boolean(item.baselineScanId) && isReliableChange(row) : row.state === filters.state;
      const levelMatches = !level || Number(row.level) === level;
      const directionMatches = filters.direction === "all" || (filters.direction === "growth" ? Number(row.deltaBytes) > 0 : Number(row.deltaBytes) < 0);
      return stateMatches && levelMatches && directionMatches && (!query || String(row.displayPath || row.path || "").toLowerCase().includes(query));
    }).map((row) => ({...row, drive:item.drive}))
  );
}

function rankChanges(rows) {
  return {
    growth: rows.filter((row) => isReliableChange(row) && Number(row.deltaBytes) > 0).sort((a,b) => Number(b.deltaBytes)-Number(a.deltaBytes)),
    release: rows.filter((row) => isReliableChange(row) && Number(row.deltaBytes) < 0).sort((a,b) => Number(a.deltaBytes)-Number(b.deltaBytes))
  };
}

function emptyChangeCopy(context) {
  if (context.waiting) return "当前磁盘正在建立首次完整基线";
  if (context.comparable && context.kind === "release") return "本次没有明显释放";
  return "当前没有可可靠归因的目录变化";
}

function classifyScanEvidence(items) {
  const expected = [], unexpected = [];
  items.forEach((item) => {
    (item.excluded || []).forEach((entry) => (entry.reason === "access-denied" ? unexpected : expected).push({...entry,drive:item.drive}));
    [...(item.unavailable || []),...(item.errors || [])].forEach((entry) => unexpected.push({...entry,drive:item.drive}));
  });
  return { expected, unexpected };
}

function formatCapacityDelta(gb) {
  const value = Number(gb) || 0;
  const bytes = Math.abs(value) * 1024 * 1024 * 1024;
  if (bytes < 1024) return "容量基本不变";
  const units = bytes >= 1024 ** 3 ? [1024 ** 3,"GB"] : bytes >= 1024 ** 2 ? [1024 ** 2,"MB"] : [1024,"KB"];
  return `${value > 0 ? "增加" : "减少"} ${(bytes / units[0]).toFixed(1)} ${units[1]}`;
}

function formatLocalDate(value) {
  const date = new Date(value);
  if (!Number.isFinite(date.getTime())) return "-";
  const pad = (part) => String(part).padStart(2,"0");
  return `${date.getFullYear()}-${pad(date.getMonth()+1)}-${pad(date.getDate())} ${pad(date.getHours())}:${pad(date.getMinutes())}:${pad(date.getSeconds())}`;
}

function shortSnapshotId(value) {
  const text = String(value || "-");
  return text.length > 9 ? `${text.slice(0,8)}…` : text;
}

function currentSizeBytes(row) {
  return Number(row?.sizeBytes || 0);
}

function summarizeChanges(items, rows) {
  const comparable = items.filter((item) => item.baselineScanId);
  const added = rows.filter((row) => isReliableChange(row) && row.deltaBytes > 0).reduce((sum,row) => sum + Number(row.deltaBytes),0);
  const released = rows.filter((row) => isReliableChange(row) && row.deltaBytes < 0).reduce((sum,row) => sum + Math.abs(Number(row.deltaBytes)),0);
  const located = added - released;
  const actual = comparable.reduce((sum,item) => sum + Number(item.coverage?.actualNetBytes || 0),0);
  const activityPreferred = comparable.some((item) => item.coverage?.activityPreferred) || (actual && located && Math.sign(actual) !== Math.sign(located));
  const rate = !activityPreferred && Math.abs(actual) >= 1 ? Math.min(100, Math.abs(located) / Math.abs(actual) * 100) : null;
  return { comparable, added, released, located, actual, activityPreferred, rate };
}

function confidenceFor(items) {
  const comparable = items.filter((item) => item.baselineScanId && item.status !== "failed");
  const waiting = items.filter((item) => !item.baselineScanId && item.status !== "failed");
  const incomplete = items.filter((item) => item.status === "partial");
  const failed = items.filter((item) => item.status === "failed");
  const state = items.length && failed.length === items.length ? "failed" : incomplete.length || failed.length ? "partial" : waiting.length ? "waiting" : "complete";
  const inspect = failed[0] || incomplete[0] || waiting[0] || items[0];
  return { comparable, waiting, incomplete, failed, state, inspect };
}

function statusLabel(status, hasBaseline) {
  if (status === "failed") return "扫描失败";
  if (!hasBaseline) return "等待完整基线";
  if (status === "complete" || status === "baseline") return "扫描完整";
  return "扫描不完整";
}
// TESTABLE_CHANGE_HELPERS_END

function coverageLabel(item) {
  if (!item?.baselineScanId) return "等待完整基线";
  if (item.coverage?.activityPreferred || Math.abs(Number(item.coverage?.actualNetBytes || 0)) < 1) return "不适用";
  return `${Number(item.coverage?.rate || 0).toFixed(1)}%`;
}

function selectedHistoryState() {
  const selections = HISTORY_CENTER.map((disk) => ({disk,comparison:selectHistoryComparison(disk,state.historyRange,state.historyCustom[disk.drive])}));
  const items = selections.map(({disk,comparison}) => ({
    drive:disk.drive,status:disk.status,baselineScanId:comparison?.scanId || null,
    baselineCompletedAt:comparison?.completedAt || null,coverage:comparison?.coverage || {},
    changes:(comparison?.changes || []).map((row) => ({...row,drive:disk.drive}))
  }));
  return {selections,items};
}

function historyTrendNode(row) {
  const recent = (row.samples || []).filter((sample) => sample?.[1] !== null && sample?.[1] !== undefined).slice(-5).map((sample) => fmtBytes(sample[1])).join(" → ");
  const root = element("div","history-row");
  const main = element("div","history-row-main"); const path=element("span","",`${row.drive} · ${row.displayPath}`); path.title=String(row.displayPath ?? "");
  main.append(path,element("b",Number(row.cumulativeBytes)>=0?"growth-value":"release-value",`累计 ${Number(row.cumulativeBytes)>0?"+":""}${fmtBytes(row.cumulativeBytes)}`));
  const meta = element("div","history-row-meta"); [row.label,`增长 ${row.growthCount} 次`,`释放 ${row.releaseCount} 次`,recent || "暂无大小序列"].forEach((text) => meta.append(element("span","",text)));
  const dates = element("div","history-row-meta"); dates.append(element("span","",`首次 ${formatLocalDate(row.firstSeen)}`),element("span","",`最近 ${formatLocalDate(row.lastSeen)}`));
  root.append(main,meta,sizeSparklineNode(row.samples),dates);
  return root;
}

function sizeSparklineNode(samples) {
  const values = (samples || []).filter((sample) => sample?.[1] !== null && sample?.[1] !== undefined).map((sample) => Number(sample[1]));
  const svg = document.createElementNS(svgNs,"svg"); svg.classList.add("history-spark"); svg.setAttribute("viewBox","0 0 160 26"); svg.setAttribute("aria-hidden","true");
  if (values.length < 2) return svg;
  const min=Math.min(...values),max=Math.max(...values),span=max-min||1;
  const path=document.createElementNS(svgNs,"path"); path.setAttribute("d",values.map((value,index)=>`${index?"L":"M"}${(index/(values.length-1)*158+1).toFixed(1)} ${(24-(value-min)/span*22).toFixed(1)}`).join(" ")); svg.append(path);
  return svg;
}

function allDirectoryTrends() {
  return HISTORY_CENTER.flatMap((disk) => (disk.trends || []).map((trend) => ({...trend,drive:disk.drive})));
}

function directoryTrendRows(id,level) {
  const drive = HISTORY_CENTER.find((disk) => normalizeDriveId(disk.drive) === normalizeDriveId(id));
  return (drive?.trends || []).filter((row) => Number(row.level) === Number(level)).sort((a,b) => Math.abs(Number(b.cumulativeBytes))-Math.abs(Number(a.cumulativeBytes))).slice(0,6).map((row) => ({...row,drive:drive.drive}));
}

function renderHistoryCenter() {
  const labels = {previous:"上一次完整扫描",day:"约 24 小时前",week:"约 7 天前",earliest:"最早可用快照",custom:"自选历史快照"};
  if (state.historyRange === "custom") HISTORY_CENTER.forEach((disk) => { state.historyCustom[disk.drive] ||= defaultHistoryCustomScanId(disk); });
  const {selections,items} = selectedHistoryState();
  const rows = items.flatMap((item) => reliableHistoryRows(item.changes).filter((row) => Number(row.level) === 1));
  const rankings = rankChanges(rows);
  const summary = summarizeChanges(items,rows);
  const unexplained = summary.comparable.reduce((sum,item) => sum + Number(item.coverage?.unexplainedBytes || 0),0);
  const gross = summary.added + summary.released;
  const activity = summary.activityPreferred ? `活动总量 ${fmtBytes(gross)}` : summary.rate === null ? "解释率不适用" : `解释率 ${summary.rate.toFixed(1)}%`;
  const mainGrowth = rankings.growth[0]?.displayPath || "无可靠增长";
  const mainRelease = rankings.release[0]?.displayPath || "无可靠释放";
  $("history-range-note").textContent = `${labels[state.historyRange]} · ${summary.comparable.length} / ${items.length} 个磁盘可可靠比较${selections.filter(x=>x.comparison).length ? " · " + selections.filter(x=>x.comparison).map(x=>`${x.disk.drive} ${formatLocalDate(x.comparison.completedAt)}`).join("；") : " · 当前没有合格历史基线"}`;
  const historySummary = $("history-summary"); historySummary.replaceChildren();
  historySummary.className="history-summary history-rail";
  [
    ["较上次增长","+"+fmtBytes(summary.added)],["较上次释放",summary.released?"-"+fmtBytes(summary.released):fmtBytes(0)],
    ["净变化",fmtBytes(summary.located)],["本次扫描时长",SCAN_META.startedAt && SCAN_META.completedAt ? `${Math.max(0,Math.round((new Date(SCAN_META.completedAt)-new Date(SCAN_META.startedAt))/60000))} 分钟` : "-"],
    ["扫描时间",formatLocalDate(SCAN_META.completedAt)],["上次扫描",selections.find(x=>x.comparison)?.comparison?.completedAt ? formatLocalDate(selections.find(x=>x.comparison).comparison.completedAt) : "暂无历史"]
  ].forEach(([label,value]) => { const metric=element("div","history-metric"); const strong=element("b","",value); strong.title=String(value); metric.append(element("span","",label),strong); historySummary.append(metric); });

  const historyCustom = $("history-custom"); historyCustom.replaceChildren();
  if (state.historyRange === "custom") HISTORY_CENTER.forEach((disk) => {
    const label=element("label","",disk.drive); const select=element("select","select history-custom-baseline"); select.dataset.drive=disk.drive;
    (disk.comparisons || []).forEach((item) => { const option=element("option","",formatLocalDate(item.completedAt)); option.value=String(item.scanId); option.selected=state.historyCustom[disk.drive]===item.scanId; select.append(option); });
    label.append(select); historyCustom.append(label);
  });

  const trends = allDirectoryTrends();
  const lists = {
    growth: trends.filter((row) => row.label === "持续增长").sort((a,b) => Number(b.cumulativeBytes)-Number(a.cumulativeBytes)),
    release: trends.filter((row) => row.label === "持续释放").sort((a,b) => Number(a.cumulativeBytes)-Number(b.cumulativeBytes)),
    trend: trends.filter((row) => row.label !== "数据不足" || Number(row.occurrenceCount) > 0).sort((a,b) => Math.abs(Number(b.cumulativeBytes))-Math.abs(Number(a.cumulativeBytes)))
  };
  const ids = {growth:"sustained-growth-list",release:"sustained-release-list",trend:"history-trend-list"};
  const titles = {growth:"持续增长",release:"持续释放",trend:"历史变化"};
  const empty = {growth:"历史样本不足，至少需要 3 次有效比较。",release:"本范围内没有持续释放目录。",trend:"历史样本不足，暂无明显历史变化。"};
  Object.entries(lists).forEach(([list,listRows]) => {
    const panel = $(`history-${list}-panel`);
    const active = state.historyTab === list;
    panel.hidden = !active;
    const tab = document.querySelector(`[data-history-tab="${list}"]`);
    tab.classList.toggle("is-active",active);
    tab.setAttribute("aria-selected",String(active));
    tab.textContent = `${titles[list]}（${listRows.length}）`;
    const listRoot=$(ids[list]); listRoot.replaceChildren();
    const visible=visibleHistoryRows(listRows,list,state.historyExpanded);
    if (visible.length) visible.forEach((row) => listRoot.append(historyTrendNode(row)));
    else listRoot.append(element("div","history-empty",empty[list]));
    const expand = panel.querySelector(".history-expand");
    expand.hidden = listRows.length <= historyListLimits[list];
    expand.textContent = state.historyExpanded[list] ? "收起" : `展开全部（${listRows.length}）`;
    expand.setAttribute("aria-expanded",String(Boolean(state.historyExpanded[list])));
  });
}

function directoryTopThree(id) {
  const item = DIRECTORY.find((entry) => normalizeDriveId(entry.drive) === normalizeDriveId(id));
  return reliableChanges(item, 1).sort((a,b) => Math.abs(b.deltaBytes) - Math.abs(a.deltaBytes)).slice(0,3);
}

function changeRowNode(row, maxMagnitude, contributionBase) {
  const valueClass = row.deltaBytes >= 0 ? "growth-value" : "release-value";
  const intensity = maxMagnitude ? Math.max(4, Math.abs(Number(row.deltaBytes)) / maxMagnitude * 100) : 0;
  const contribution = contributionBase ? `${(Math.abs(Number(row.deltaBytes)) / contributionBase * 100).toFixed(1)}%` : "-";
  const root=element("div","change-item"), main=element("div","change-main"), path=element("span","change-path expandable-path",row.displayPath);
  path.title=String(row.displayPath ?? ""); main.append(path,element("div","change-context",`${row.drive} · ${row.level} 级 · 当前 ${fmtBytes(currentSizeBytes(row))} · 贡献 ${contribution}`));
  const side=element("div","change-side"); side.append(element("b",valueClass,`${row.deltaBytes >= 0 ? "+" : ""}${fmtBytes(row.deltaBytes)}`));
  const copy=element("button","copy-path","复制路径"); copy.type="button"; copy.dataset.copyPath=String(row.displayPath ?? ""); copy.setAttribute("aria-label",`复制路径 ${row.displayPath}`); side.append(copy);
  const track=element("div",`intensity-track ${valueClass}`),fill=element("span","intensity-fill"); fill.style.setProperty("--intensity",`${Math.max(0,Math.min(100,intensity)).toFixed(1)}%`); track.append(fill);
  root.append(main,side,track); return root;
}

function stateChangeRowNode(row) {
  const label = row.state === "unknown" ? "未知变化" : "当前不可用";
  const root=element("div","change-item"), main=element("div","change-main"), path=element("span","change-path expandable-path",row.displayPath); path.title=String(row.displayPath ?? "");
  main.append(path,element("div","change-context",`${row.drive} · ${row.level} 级 · ${label}`)); root.append(main,element("span","status-badge waiting",label)); return root;
}

function currentChangeFilters() {
  return {
    drive: $("change-drive-filter").value || defaultChangeFilters.drive,
    level: $("change-level-filter").value || defaultChangeFilters.level,
    direction: $("change-direction-filter").value || defaultChangeFilters.direction,
    state: $("change-state-filter").value || defaultChangeFilters.state,
    query: $("change-path-filter").value || defaultChangeFilters.query
  };
}

function selectedItems(filters) {
  return DIRECTORY.filter((item) => filters.drive === "all" || item.drive === filters.drive);
}

function capacityStatement(mostFull) {
  if (!mostFull || Number(mostFull.percent) < 75) return "当前没有明显容量压力";
  return `${mostFull.id} 使用率最高，建议关注`;
}

function renderCapacitySummary() {
  const t = totals();
  const overallPct = t.total > 0 ? t.used / t.total * 100 : 0;
  const mostFull = [...DATA].sort((a,b) => b.percent-a.percent)[0];
  const root = $("capacity-summary");
  root.replaceChildren();
  root.append(element("div","summary-label","整体容量"));
  const layout = element("div","capacity-layout");
  const ring = element("div","ring");
  ring.style.setProperty("--pct",String(Math.max(0,Math.min(100,Number(overallPct) || 0))));
  ring.append(element("span","",pct(overallPct)));
  const copy = element("div");
  copy.append(element("h2","summary-title",capacityStatement(mostFull)));
  copy.append(element("p","summary-note",`最高使用率 ${mostFull ? `${normalizeDriveId(mostFull.id)} ${pct(mostFull.percent)}` : "-"}`));
  layout.append(ring,copy);
  root.append(layout);
  const scan = confidenceFor(DIRECTORY);
  const baselineWaiting = DIRECTORY.some((item) => !item.baselineScanId);
  const allFailed = DIRECTORY.length > 0 && DIRECTORY.every((item) => item.status === "failed");
  const scanState = !DIRECTORY.length ? ["unknown","扫描状态未知"] : allFailed ? ["failed","扫描全部失败"] : scan.incomplete.length || scan.failed.length ? ["partial","扫描部分完成"] : baselineWaiting ? ["waiting","等待比较基线"] : ["complete","扫描全部完成"];
  const statusLink = element("a",`overview-scan-state ${scanState[0]}`,scanState[1]);
  statusLink.href = "#scan-completeness";
  root.append(statusLink);
  const facts = element("div","summary-facts");
  [["已用",fmt(t.used)],["总容量",fmt(t.total)],["剩余",fmt(t.free)]].forEach(([label,value]) => {
    const fact = element("div","summary-fact"); fact.append(element("span","",label),element("b","",value)); facts.append(fact);
  });
  root.append(facts);
}

function renderConfidence(items) {
  const c = confidenceFor(items);
  const root = $("comparison-confidence"); root.replaceChildren();
  const top=element("div","summary-card-link"); top.append(element("div","summary-label","可比磁盘概览"),element("a","summary-link","查看全部")); top.querySelector("a").href="#drive-details-section"; root.append(top);
  const body=element("div","confidence-body"); const copy=element("div"); copy.append(element("div",`confidence-count confidence-state ${c.state}`,`${c.comparable.length} / ${items.length}`),element("h2","summary-title","个磁盘可可靠比较"));
  const list = element("div","confidence-list");
  [`● ${c.comparable.length} 个磁盘相似`, `● ${c.waiting.length + c.incomplete.length + c.failed.length} 个磁盘不可比`, `优先建议：${c.inspect ? normalizeDriveId(c.inspect.drive) : "无需检查"}`].forEach((text) => list.append(element("span","",text))); copy.append(list);
  const art=element("div","confidence-illustration"); art.setAttribute("aria-hidden","true"); art.append(element("span","confidence-stack","▤"),element("span","confidence-check","✓")); body.append(copy,art); root.append(body);
}

function renderChangeSummary(items, summary, rankings) {
  const main = rankings.growth[0] || rankings.release[0];
  const gross = summary.added + summary.released;
  const contribution = main && gross ? Math.abs(Number(main.deltaBytes)) / gross * 100 : null;
  const headline = main ? `${main.deltaBytes > 0 ? "主要增长" : "主要释放"}来自 ${main.displayPath}` : emptyChangeCopy({waiting:!summary.comparable.length,comparable:summary.comparable.length > 0,kind:"all"});
  const fourthLabel = summary.activityPreferred ? "活动总量" : "目录解释率";
  const fourthValue = summary.activityPreferred ? fmtBytes(gross) : summary.rate === null ? "不适用" : `${summary.rate.toFixed(1)}%`;
  const root = $("latest-change"); root.replaceChildren();
  root.append(element("div","summary-label","最新变化"),element("h2","summary-title",headline));
  const hero = element("div","change-hero");
  hero.append(element("b","",main ? `${main.deltaBytes > 0 ? "+" : ""}${fmtBytes(main.deltaBytes)}` : "—"),element("span","summary-note",contribution === null ? "没有可靠变化排行" : `主路径贡献 ${contribution.toFixed(1)}%`));
  root.append(hero);
  const metrics = element("div","change-metrics");
  [["可靠新增",`+${fmtBytes(summary.added)}`],["可靠释放",`${summary.released ? "-" : ""}${fmtBytes(summary.released)}`],["已定位净变化",fmtBytes(summary.located)],[fourthLabel,fourthValue]].forEach(([label,value]) => {
    const metric = element("div","change-metric"); metric.append(element("span","",label),element("b","",value)); metrics.append(metric);
  });
  root.append(metrics,element("div","reliability-badge",`${summary.comparable.length} / ${items.length} 个磁盘可可靠比较`));
}

function renderAttention(rankings) {
  const root = $("attention-list"); root.replaceChildren();
  const rows = [...rankings.growth,...rankings.release].sort((a,b) => Math.abs(Number(b.deltaBytes))-Math.abs(Number(a.deltaBytes)));
  const items = buildAttentionItems(DATA,DIRECTORY,rows);
  root.dataset.count = String(items.length);
  items.forEach((item) => {
    const link = element("a",`attention-item ${item.tone}`);
    link.href = item.href;
    const marker = element("span","attention-marker","⚠");
    const label = element("span","attention-severity",item.tone === "critical" ? "高关注" : item.tone === "warning" ? "提醒" : "关注");
    const copy = element("span","attention-copy"); copy.append(element("b","",item.title),element("small","",item.detail));
    link.append(marker,element("span","attention-heading","关注中心"),label,copy,element("span","attention-arrow","查看详情"));
    root.append(link);
  });
}

function renderDirectoryChanges() {
  const driveFilter = $("change-drive-filter");
  if (!driveFilter.options.length) {
    driveFilter.add(new Option("全部磁盘", "all"));
    DIRECTORY.forEach((item) => driveFilter.add(new Option(item.drive, item.drive)));
  }
  const filters = currentChangeFilters();
  const items = selectedItems(filters);
  const rows = filterChangeRows(DIRECTORY, filters);
  const rankings = rankChanges(rows);
  const growth = rankings.growth.slice(0,5), release = rankings.release.slice(0,5);
  const maxMagnitude = Math.max(0,...growth.concat(release).map((row) => Math.abs(Number(row.deltaBytes))));
  const gross = rows.filter(isReliableChange).reduce((sum,row) => sum + Math.abs(Number(row.deltaBytes)),0);
  const waiting = items.length > 0 && items.every((item) => !item.baselineScanId);
  const reliableView = filters.state === "reliable";
  const lists = $("change-details").querySelector(".change-lists");
  lists.hidden = !reliableView;
  const onlyGrowth = reliableView && growth.length > 0 && release.length === 0;
  const onlyRelease = reliableView && release.length > 0 && growth.length === 0;
  const bothEmpty = reliableView && growth.length === 0 && release.length === 0;
  lists.classList.toggle("only-growth",onlyGrowth);
  lists.classList.toggle("only-release",onlyRelease);
  lists.classList.toggle("both-empty",bothEmpty);
  $("release-empty-note").hidden = !onlyGrowth;
  $("growth-empty-note").hidden = !onlyRelease;
  $("state-change-list").hidden = reliableView;
  if (reliableView) {
    [["growth-list",growth,"growth"],["release-list",release,"release"]].forEach(([id,list,kind]) => { const root=$(id); root.replaceChildren(); if(list.length) list.forEach((row)=>root.append(changeRowNode(row,maxMagnitude,gross))); else if (!bothEmpty || kind === "growth") root.append(element("div","baseline-guide",emptyChangeCopy({waiting,comparable:!waiting,kind:bothEmpty?"all":kind}))); });
  } else {
    $("state-change-title").textContent = filters.state === "unknown" ? "未知变化" : "不可用项目";
    const stateRoot=$("state-change-body"); stateRoot.replaceChildren();
    if(rows.length) rows.forEach((row)=>stateRoot.append(stateChangeRowNode(row))); else stateRoot.append(element("div","baseline-guide","当前筛选没有对应项目。"));
  }
  const summary = summarizeChanges(items,rows);
  renderChangeSummary(items,summary,rankings);
  renderConfidence(items);
  renderAttention(rankings);
}

function capacityStatusLabel(status) {
  return status === "critical" ? "严重" : status === "warning" ? "提醒" : "正常";
}

function renderCapacityDriveList() {
  const root = $("capacity-drive-select"); root.replaceChildren();
  capacityDriveOrder(DATA).forEach((drive) => {
    const id = normalizeDriveId(drive.id);
    const selected = id === state.capacityDrive;
    const button = element("button",`capacity-drive-row ${drive.status}${selected ? " is-selected" : ""}`);
    button.type = "button";
    button.dataset.capacityDrive = id;
    button.setAttribute("aria-pressed",String(selected));
    button.setAttribute("aria-label",`${id}，使用率 ${pct(drive.percent)}，已用 ${fmt(drive.used)}，剩余 ${fmt(drive.free)}，总容量 ${fmt(drive.total)}`);
    const head = element("span","capacity-drive-head");
    head.append(element("b","",id),element("span",`capacity-drive-state ${drive.status}`,capacityStatusLabel(drive.status)));
    head.append(element("span",`capacity-current${selected ? "" : " is-placeholder"}`,selected ? "当前" : "占位"));
    head.append(element("strong","",pct(drive.percent)));
    const bar = element("span","capacity-ratio-track");
    const fill = element("span","capacity-ratio-fill");
    fill.style.width = `${Math.max(0,Math.min(100,Number(drive.percent) || 0))}%`;
    bar.append(fill);
    const facts = element("span","capacity-drive-facts",`已用 ${fmt(drive.used)} · 剩余 ${fmt(drive.free)} · 总容量 ${fmt(drive.total)}`);
    button.append(head,bar,facts);
    root.append(button);
  });
  if (!DATA.length) root.append(element("p","capacity-empty","当前没有可显示的磁盘。"));
}

function capacityRangeLabel(range) {
  return range === "all" ? "全部历史" : `最近 ${range} 天`;
}

function renderCapacityChart(samples, drive) {
  const root = $("capacity-trend-chart"); root.replaceChildren();
  const stats = capacityTrendStats(samples);
  if (!stats) {
    root.append(element("div","capacity-empty","当前范围没有有效容量样本。"));
    return;
  }
  const width = 720, height = 270, left = 56, right = 18, top = 24, bottom = 38;
  const plotWidth = width-left-right, plotHeight = height-top-bottom;
  const minTime = stats.first.time, maxTime = stats.last.time;
  const rawSpan = stats.max-stats.min;
  const padding = rawSpan > 0 ? rawSpan*.12 : Math.max(1,stats.max*.04);
  const minUsed = Math.max(0,stats.min-padding), maxUsed = stats.max+padding;
  const x = (sample) => left + (maxTime === minTime ? plotWidth/2 : (sample.time-minTime)/(maxTime-minTime)*plotWidth);
  const y = (sample) => top + (maxUsed-sample.used)/(maxUsed-minUsed)*plotHeight;
  const svg = document.createElementNS(svgNs,"svg");
  svg.classList.add("capacity-svg");
  svg.setAttribute("viewBox",`0 0 ${width} ${height}`);
  svg.setAttribute("role","img");
  const titleId = "capacity-chart-title", descId = "capacity-chart-desc";
  svg.setAttribute("aria-labelledby",`${titleId} ${descId}`);
  const title = document.createElementNS(svgNs,"title"); title.id=titleId; title.textContent=`${drive.id} 已用容量历史趋势`;
  const desc = document.createElementNS(svgNs,"desc"); desc.id=descId; desc.textContent=`${capacityRangeLabel(state.capacityRange)}，${formatLocalDate(stats.first.timestamp)} 至 ${formatLocalDate(stats.last.timestamp)}，共 ${stats.count} 个有效样本。`;
  svg.append(title,desc);
  const defs = document.createElementNS(svgNs,"defs");
  const gradient = document.createElementNS(svgNs,"linearGradient");
  gradient.id="capacity-area-gradient"; gradient.setAttribute("x1","0"); gradient.setAttribute("y1","0"); gradient.setAttribute("x2","0"); gradient.setAttribute("y2","1");
  [["0%",".24"],["100%",".02"]].forEach(([offset,opacity]) => { const stop=document.createElementNS(svgNs,"stop"); stop.setAttribute("offset",offset); stop.setAttribute("stop-color","var(--blue)"); stop.setAttribute("stop-opacity",opacity); gradient.append(stop); });
  defs.append(gradient); svg.append(defs);
  [0,.5,1].forEach((ratio) => {
    const line = document.createElementNS(svgNs,"line");
    const lineY = top+plotHeight*ratio;
    line.setAttribute("x1",String(left)); line.setAttribute("x2",String(width-right)); line.setAttribute("y1",String(lineY)); line.setAttribute("y2",String(lineY)); line.classList.add("capacity-grid-line"); svg.append(line);
    const label = document.createElementNS(svgNs,"text"); label.setAttribute("x",String(left-8)); label.setAttribute("y",String(lineY+4)); label.setAttribute("text-anchor","end"); label.classList.add("capacity-axis-label"); label.textContent=fmt(maxUsed-(maxUsed-minUsed)*ratio); svg.append(label);
  });
  const area = document.createElementNS(svgNs,"path");
  area.classList.add("capacity-area");
  area.setAttribute("d",`${samples.map((sample,index) => `${index ? "L" : "M"}${x(sample).toFixed(2)},${y(sample).toFixed(2)}`).join(" ")} L${x(samples[samples.length-1]).toFixed(2)},${top+plotHeight} L${x(samples[0]).toFixed(2)},${top+plotHeight} Z`);
  svg.append(area);
  const path = document.createElementNS(svgNs,"path");
  path.classList.add("capacity-line");
  path.setAttribute("d",samples.map((sample,index) => `${index ? "L" : "M"}${x(sample).toFixed(2)},${y(sample).toFixed(2)}`).join(" "));
  svg.append(path);
  samples.forEach((sample) => {
    const point = document.createElementNS(svgNs,"circle");
    point.classList.add("capacity-point"); point.setAttribute("cx",x(sample).toFixed(2)); point.setAttribute("cy",y(sample).toFixed(2)); point.setAttribute("r","2.4");
    const tooltip = document.createElementNS(svgNs,"title"); tooltip.textContent=`${formatLocalDate(sample.timestamp)} · ${fmt(sample.used)} · ${pct(sample.percent)}`; point.append(tooltip); svg.append(point);
  });
  [[left,stats.first.timestamp,"start"],[width-right,stats.last.timestamp,"end"]].forEach(([labelX,timestamp,anchor]) => {
    const label = document.createElementNS(svgNs,"text"); label.setAttribute("x",String(labelX)); label.setAttribute("y",String(height-10)); label.setAttribute("text-anchor",anchor); label.classList.add("capacity-axis-label"); label.textContent=formatLocalDate(timestamp).slice(0,10); svg.append(label);
  });
  root.append(svg);
  if (stats.count === 1) root.append(element("p","capacity-empty","样本不足，无法计算变化。"));
}

function renderCapacityVisuals() {
  if (!DATA.some((drive) => normalizeDriveId(drive.id) === state.capacityDrive)) state.capacityDrive = defaultCapacityDrive(DATA,SYSTEM_DRIVE);
  renderCapacityDriveList();
  document.querySelectorAll("[data-capacity-range]").forEach((button) => button.setAttribute("aria-pressed",String(button.dataset.capacityRange === state.capacityRange)));
  const drive = DATA.find((item) => normalizeDriveId(item.id) === state.capacityDrive);
  const statsRoot = $("capacity-trend-stats"); statsRoot.replaceChildren();
  if (!drive) {
    $("capacity-trend-caption").textContent = "当前没有可显示的磁盘";
    $("capacity-trend-chart").replaceChildren(element("div","capacity-empty","当前没有可显示的磁盘。"));
    $("print-meta").textContent = `报告生成时间：${TS} · 无可用容量趋势`;
    return;
  }
  const allSamples = cleanCapacitySamples(HISTORY,drive,state.capacityDrive,TS);
  const samples = filterCapacitySamples(allSamples,state.capacityRange,TS);
  const stats = capacityTrendStats(samples);
  $("capacity-trend-caption").textContent = `${state.capacityDrive} · ${capacityRangeLabel(state.capacityRange)}`;
  statsRoot.className="capacity-trend-stats trend-summary";
  const statValues = stats ? [["当前使用",fmt(drive.used)],["总容量",fmt(drive.total)],["可用容量",fmt(drive.free)],["较范围起点",stats.change === null ? "样本不足" : `${stats.change >= 0 ? "+" : ""}${fmt(stats.change)}`]] : [["当前使用","—"],["总容量","—"],["可用容量","—"],["较范围起点","—"]];
  statValues.forEach(([label,value]) => { const card=element("div","capacity-stat"); card.append(element("span","",label),element("b","",value)); statsRoot.append(card); });
  renderCapacityChart(samples,drive);
  const rangeText = stats ? `${formatLocalDate(stats.first.timestamp)} 至 ${formatLocalDate(stats.last.timestamp)} · ${stats.count} 个有效样本` : "当前范围没有有效样本";
  $("print-meta").textContent = `报告生成时间：${TS} · 趋势磁盘：${state.capacityDrive} · ${rangeText}`;
}

function miniNode(label,value,previous) {
  const root=element("div","mini"); root.append(element("span","",label),element("b","",value)); if(previous !== null) root.append(element("small","",`上次 ${previous}`)); return root;
}

function topPathNode(row,maxMagnitude) {
  const root=element("div","top-path-row"), path=element("span","top-path-name expandable-path",row.displayPath); path.title=String(row.displayPath ?? "");
  const valueClass=row.deltaBytes>=0?"growth-value":"release-value"; root.append(path,element("b",valueClass,`${row.deltaBytes>=0?"+":""}${fmtBytes(row.deltaBytes)}`));
  const copy=element("button","copy-path","复制"); copy.type="button"; copy.dataset.copyPath=String(row.displayPath ?? ""); copy.setAttribute("aria-label",`复制路径 ${row.displayPath}`); root.append(copy);
  const track=element("span",`intensity-track ${valueClass}`),fill=element("span","intensity-fill"); const intensity=maxMagnitude?Math.max(4,Math.abs(Number(row.deltaBytes))/maxMagnitude*100):0; fill.style.setProperty("--intensity",`${Math.max(0,Math.min(100,intensity)).toFixed(1)}%`); track.append(fill); root.append(track); return root;
}

function evidenceGroupNode(title,rows) {
  const root=element("div","detail-group"); root.append(element("b","",title));
  if(rows.length){ const list=element("ul"); rows.forEach((item)=>{ const row=element("li","",`${item.path} · ${item.reason}`); row.title=String(item.path ?? ""); list.append(row); }); root.append(list); }
  else root.append(element("p","","无")); return root;
}

function renderCards() {
  const drives = sortedDrives(), grid=$("grid");
  $("empty").style.display = drives.length ? "none" : "block";
  grid.replaceChildren();
  drives.forEach((d) => {
    const rows=historyFor(d.id),lastSeen=rows.length?rows[rows.length-1].Timestamp:TS,prev=rows.length>=2?rows[rows.length-2]:null;
    const directory=DIRECTORY.find((item)=>normalizeDriveId(item.drive)===normalizeDriveId(d.id)),coverage=directoryCoverage(d.id),topThree=directoryTopThree(d.id);
    const topThreeMax=Math.max(0,...topThree.map((row)=>Math.abs(Number(row.deltaBytes)))),detailLevel=Number(state.driveLevels[d.id]||1);
    const topTen=reliableChanges(directory,detailLevel).sort((a,b)=>Math.abs(b.deltaBytes)-Math.abs(a.deltaBytes)).slice(0,10),trendRows=directoryTrendRows(d.id,detailLevel),detailMax=Math.max(0,...topTen.map((row)=>Math.abs(Number(row.deltaBytes))));
    const scanEvidence=classifyScanEvidence(directory?[directory]:[]),cardStatus=!directory?.baselineScanId?"waiting":directory.status==="failed"?"failed":directory.status==="partial"?"partial":"complete";
    const activityLabel=coverage?.activityPreferred?`活动总量 ${fmtBytes(Number(coverage.addedBytes||0)+Number(coverage.releasedBytes||0))}`:`目录解释率 ${directory?coverageLabel(directory):"-"}`;
    const card=element("article",`card ${d.status}`);
    const top=element("div","card-top"),heading=element("div"); heading.append(element("div","drive-name",`磁盘 ${normalizeDriveId(d.id)}`),element("div","drive-sub",`最近采样 ${lastSeen}`));
    const actions=element("div","card-top-actions"); actions.append(element("span",`status-badge ${cardStatus}`,directory?statusLabel(directory.status,directory.baselineScanId):"未扫描"),element("div","badge",`使用率 ${pct(d.percent)}`)); top.append(heading,actions); card.append(top);
    const bar=element("div","bar-track"),fill=element("div","bar-fill"); fill.dataset.w=`${Math.max(0,Math.min(100,Number(d.percent)||0))}%`; bar.append(fill); card.append(bar);
    const meta=element("div","meta"); meta.append(miniNode("已用",fmt(d.used),prev?fmt(prev.Used):null),miniNode("剩余",fmt(d.free),prev?fmt(prev.Free):null),miniNode("总量",fmt(d.total),prev?fmt(prev.Total):null)); card.append(meta);
    const spark=element("div","spark-row"),trendCopy=element("div"),trendLine=element("div"),estimate=element("div","",estimateDays(d,rows)); trendLine.append(trend(d.diff)); trendCopy.append(trendLine,estimate); spark.append(sparkline(rows),trendCopy); card.append(spark);
    const extra=element("div","directory-card-extra"); extra.append(element("b","",directory?.baselineScanId?`目录净变化 ${fmtBytes(coverage?.actualNetBytes)}`:"当前目录规模已记录"),element("span","",activityLabel));
    if(topThree.length){ const paths=element("div","top-paths"); topThree.forEach((row)=>paths.append(topPathNode(row,topThreeMax))); extra.append(paths); } else extra.append(element("p","",directory?.baselineScanId?"本次没有可靠目录变化。":"建立完整基线后显示目录变化 Top 3。")); card.append(extra);
    const details=element("details","drive-details"); details.append(element("summary","","展开目录与扫描详情")); const body=element("div","drive-details-body");
    const levelLabel=element("label","","目录层级 "),levelSelect=element("select","select drive-level-switch"); levelSelect.dataset.drive=d.id; [[1,"一级目录"],[2,"二级目录"]].forEach(([value,label])=>{ const option=element("option","",label); option.value=String(value); option.selected=detailLevel===value; levelSelect.append(option); }); levelLabel.append(levelSelect); body.append(levelLabel);
    const detailPaths=element("div","top-paths"); if(topTen.length) topTen.forEach((row)=>detailPaths.append(topPathNode(row,detailMax))); else detailPaths.append(element("p","",emptyChangeCopy({waiting:!directory?.baselineScanId,comparable:Boolean(directory?.baselineScanId),kind:"all"}))); body.append(detailPaths);
    const trends=element("div","directory-trends"); trends.append(element("b","","目录历史序列")); if(trendRows.length) trendRows.forEach((row)=>trends.append(historyTrendNode(row))); else trends.append(element("p","history-empty","历史样本不足，暂无可展示序列。")); body.append(trends);
    const groups=element("div","detail-groups"); groups.append(evidenceGroupNode("预期排除",scanEvidence.expected),evidenceGroupNode("意外不可用",scanEvidence.unexpected)); body.append(groups,element("p","",`基线时间：${directory?.baselineCompletedAt||"等待完整基线"} · 扫描状态：${directory?statusLabel(directory.status,directory.baselineScanId):"未扫描"}`));
    const detailSpark=element("div"); detailSpark.append(sparkline(rows)); body.append(detailSpark); details.append(body); card.append(details); grid.append(card);
  });
  requestAnimationFrame(() => {
    document.querySelectorAll(".bar-fill").forEach((bar) => {
      bar.style.width = bar.dataset.w;
    });
  });
}

function renderScanCompleteness() {
  const {expected,unexpected} = classifyScanEvidence(DIRECTORY);
  const root = $("scan-detail-body"); root.replaceChildren();
  const grid = element("div","scan-completeness-grid");
  const addGroup = (title,description,rows,empty) => {
    const group = element("div","detail-group"); group.append(element("h3","",title),element("p","",description));
    if (rows.length) {
      const list = element("ul");
      rows.forEach((row) => { const item=element("li","",`${row.drive} · ${row.path} · ${row.reason}`); item.title=String(row.path ?? ""); list.append(item); });
      group.append(list);
    } else group.append(element("p","",empty));
    grid.append(group);
  };
  addGroup("预期排除","重解析点、联接、符号链接、$RECYCLE.BIN 和 System Volume Information 属于正常排除。",expected,"没有记录到预期排除项。");
  addGroup("意外不可用","访问被拒绝、扫描中消失、枚举失败或暂时不可用会列在这里。",unexpected,"没有意外不可用项目。");
  root.append(grid);
}

function renderScanMetadata() {
  const start = SCAN_META.startedAt ? new Date(SCAN_META.startedAt) : null;
  const end = SCAN_META.completedAt ? new Date(SCAN_META.completedAt) : null;
  const duration = start && end ? `${Math.max(0,Math.round((end-start)/1000))} 秒` : "-";
  const fields = [["扫描开始",formatLocalDate(SCAN_META.startedAt),SCAN_META.startedAt||"-"],["扫描完成",formatLocalDate(SCAN_META.completedAt),SCAN_META.completedAt||"-"],["总耗时",duration,duration],["扫描磁盘",`${Number(SCAN_META.driveCount||0)} 个`,`${Number(SCAN_META.driveCount||0)} 个`]];
  const scanId = String(SCAN_META.scanId||"-");
  const root = $("scan-metadata"); root.className="scan-metadata scan-summary-card"; root.replaceChildren();
  fields.forEach(([label,value,title]) => { const item=element("div","metadata-item"); const strong=element("b","",value); strong.title=String(title); item.append(element("span","",label),strong); root.append(item); });
  const item = element("div","metadata-item"); item.append(element("span","","快照 ID"));
  const value = element("div","snapshot-value"); const strong=element("b","",shortSnapshotId(scanId)); strong.title=scanId;
  const copy = element("button","copy-path snapshot-copy","复制"); copy.type="button"; copy.dataset.copyPath=scanId; copy.setAttribute("aria-label","复制快照 ID");
  value.append(strong,copy); item.append(value); root.append(item);
}

function render() {
  document.body.classList.toggle("compact", state.compact);
  renderCapacitySummary();
  renderDirectoryChanges();
  renderCapacityVisuals();
  renderHistoryCenter();
  renderCards();
  renderScanCompleteness();
  renderScanMetadata();
}

function openHistoryFromHash() {
  if (location.hash !== "#history-center" && location.hash !== "#history-details") return;
  const details = $("history-details");
  if (details) details.open = true;
}

["change-drive-filter","change-level-filter","change-direction-filter","change-state-filter"].forEach((id) => $(id).addEventListener("change", renderDirectoryChanges));
$("change-path-filter").addEventListener("input", renderDirectoryChanges);
$("history-range").addEventListener("change", (event) => { state.historyRange = event.target.value; renderHistoryCenter(); });
document.addEventListener("click", async (event) => {
  const capacityDrive = event.target.closest("[data-capacity-drive]");
  if (capacityDrive) {
    state.capacityDrive = normalizeDriveId(capacityDrive.dataset.capacityDrive);
    renderCapacityVisuals();
    announce(`已选择 ${state.capacityDrive} 容量趋势`);
    return;
  }
  const capacityRange = event.target.closest("[data-capacity-range]");
  if (capacityRange) {
    state.capacityRange = capacityRange.dataset.capacityRange;
    renderCapacityVisuals();
    announce(`已切换为${capacityRangeLabel(state.capacityRange)}`);
    return;
  }
  const historyTab = event.target.closest("[data-history-tab]");
  if (historyTab) {
    state.historyTab = historyTab.dataset.historyTab;
    renderHistoryCenter();
    return;
  }
  const historyExpand = event.target.closest(".history-expand");
  if (historyExpand) {
    const list = historyExpand.dataset.historyList;
    state.historyExpanded[list] = !state.historyExpanded[list];
    renderHistoryCenter();
    return;
  }
  const button = event.target.closest(".copy-path");
  if (button) {
    const path = button.dataset.copyPath;
    try { await navigator.clipboard.writeText(path); const old=button.textContent; button.textContent="已复制"; announce("已复制到剪贴板"); setTimeout(()=>button.textContent=old,1200); }
    catch { alert(path); }
    return;
  }
  const path = event.target.closest(".expandable-path");
  if (path && window.matchMedia("(max-width: 560px)").matches) path.classList.toggle("is-expanded");
});
document.addEventListener("change", (event) => {
  const customBaseline = event.target.closest(".history-custom-baseline");
  if (customBaseline) {
    state.historyCustom[customBaseline.dataset.drive] = customBaseline.value;
    renderHistoryCenter();
    return;
  }
  const level = event.target.closest(".drive-level-switch");
  if (!level) return;
  state.driveLevels[level.dataset.drive] = level.value;
  renderCards();
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
  $("themeBtn").setAttribute("aria-label",next === "dark" ? "切换到浅色主题" : "切换到深色主题");
  announce(next === "dark" ? "已切换到深色主题" : "已切换到浅色主题");
});

(function() {
  var t = document.documentElement.getAttribute("data-theme");
  $("themeBtn").textContent = t === "dark" ? " 浅色" : " 深色";
  $("themeBtn").setAttribute("aria-label",t === "dark" ? "切换到浅色主题" : "切换到深色主题");
})();

$("print-report").addEventListener("click", () => window.print());

window.addEventListener("hashchange",openHistoryFromHash);
openHistoryFromHash();

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
    announce("摘要已复制到剪贴板");
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

$replacementMap = @{
    INJECT_DATA = $jsonArray
    INJECT_HISTORY = $historyJson
    INJECT_DIRECTORY = $directoryJson
    INJECT_HISTORY_CENTER = $historyCenterJson
    INJECT_SCAN_META = $scanMetaJson
    INJECT_TS_JSON = $timestampJson
    INJECT_SYSTEM_DRIVE = $systemDriveJson
}
$placeholderPattern = 'INJECT_(?:HISTORY_CENTER|SYSTEM_DRIVE|SCAN_META|TS_JSON|DIRECTORY|HISTORY|DATA)'
$html = [regex]::Replace($html, $placeholderPattern, { param($match) [string]$replacementMap[$match.Value] })

$utf8NoBom = New-Object System.Text.UTF8Encoding $false
[System.IO.File]::WriteAllText($htmlFile, $html, $utf8NoBom)
$reportStopwatch.Stop()
$scanStage = "生成报告"

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
$runStopwatch.Stop()
& $clearConsoleProgress
Write-Host ("扫描完成：{0:N1} 秒" -f $runStopwatch.Elapsed.TotalSeconds)
Write-Host ("报告生成：{0:N3} 秒，{1:N0} 字节" -f $reportStopwatch.Elapsed.TotalSeconds, ([Text.Encoding]::UTF8.GetByteCount($html)))
Write-Host "报告位置：$htmlFile"
foreach ($driveResult in $snapshot.drives) {
    Write-Host ("{0} 无法访问 {1} 个路径，主动排除 {2} 个路径" -f $driveResult.drive, @($driveResult.unavailable).Count, @($driveResult.excluded).Count)
}
}
catch {
$runStopwatch.Stop()
& $clearConsoleProgress
Write-Host "扫描失败：$scanStage" -ForegroundColor Red
Write-Host ("已用时间：{0:N1} 秒" -f $runStopwatch.Elapsed.TotalSeconds)
Write-Host "错误：$($_.Exception.Message)" -ForegroundColor Red
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
    & $clearConsoleProgress
    Release-DiskPulseLock $paths $owner
}
}

if ($env:DISKPULSE_TEST_MODE -ne "1") {
    Invoke-DiskPulse
}
