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
$directoryResults = New-Object 'Collections.Generic.List[object]'
foreach ($driveSnapshot in $snapshot.drives) {
    $baselineSnapshot = Find-DriveBaseline -Snapshots @($priorSnapshots) -Drive $driveSnapshot.drive -Current $snapshot
    $baselineDrive = if ($baselineSnapshot) { $baselineSnapshot.drives | Where-Object drive -eq $driveSnapshot.drive | Select-Object -First 1 } else { $null }
    $changes = Compare-DriveRecords $driveSnapshot $baselineDrive
    $directoryResults.Add([PSCustomObject]@{ drive=$driveSnapshot.drive; status=$driveSnapshot.status; baselineScanId=if($baselineSnapshot){$baselineSnapshot.scanId}else{$null}; baselineCompletedAt=if($baselineSnapshot){$baselineSnapshot.completedAt}else{$null}; changes=$changes; coverage=Get-ChangeCoverage $driveSnapshot $baselineDrive $changes; errors=$driveSnapshot.errors; unavailable=$driveSnapshot.unavailable; excluded=$driveSnapshot.excluded })
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
$scanMetaJson = $snapshot | Select-Object scanId,startedAt,completedAt,status,@{n='driveCount';e={@($_.drives).Count}} | ConvertTo-Json -Compress
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
  .panel, .metric, .card, .change-list { border: 0; border-radius: 16px; box-shadow: none; }
  .overview { gap: 10px; }
  .panel { padding: 22px; }
  .metric { padding: 20px; min-height: 124px; }
  .metric-label { text-transform: none; letter-spacing: 0; font-weight: 600; }
  .metric-value { letter-spacing: -.02em; }
  .insights { gap: 1px; overflow: hidden; border-radius: 16px; background: var(--line); }
  .insight, .insight.warn, .insight.critical, .insight.good { border-left: 0; border-radius: 0; min-height: 82px; padding: 16px 18px; }
  .insight-title { text-transform: none; letter-spacing: 0; font-weight: 600; }
  .directory-overview { margin-top: 0; }
  .change-metrics { gap: 1px; overflow: hidden; border-radius: 12px; background: var(--line); }
  .change-metric { border-radius: 0; background: var(--track); padding: 14px 16px; }
  .change-controls { margin: 14px 0 10px; }
  .change-controls label { font-weight: 600; }
  .change-lists { gap: 10px; align-items: start; }
  .change-lists.single-sided { grid-template-columns: minmax(0, 1fr); }
  .change-lists.single-sided .change-list:has(> div > .baseline-guide) { display: none; }
  .change-list { padding: 18px 18px 8px; min-height: 0; }
  .state-change-list { margin-top: 10px; }
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

  /* Frozen dashboard hierarchy: semantic color, quiet surfaces, no decorative motion. */
  :root {
    --bg: #f4f6f9; --panel: #ffffff; --track: #eef2f7; --line: #e5e7eb;
    --text: #111827; --muted: #6b7280; --blue: #2563eb; --green: #059669;
    --orange: #d97706; --red: #dc2626; --unknown: #64748b;
  }
  [data-theme="dark"] {
    --bg: #0b0f17; --panel: #121826; --track: #182033; --line: #263244;
    --text: #f3f6fa; --muted: #94a3b8; --blue: #2563eb; --green: #059669;
    --orange: #d97706; --red: #dc2626; --unknown: #64748b;
  }
  .overview, .insights { display: block; margin: 0; background: transparent; border-radius: 0; overflow: visible; }
  .summary-grid { display: grid; grid-template-columns: 1.05fr 1.65fr .9fr; grid-template-areas: "capacity change confidence"; gap: 12px; margin: 8px 0 14px; }
  .summary-card, .system-conclusion, .scan-metadata { background: var(--panel); border: 1px solid var(--line); border-radius: 18px; padding: 22px; min-width: 0; }
  .summary-card { transition: transform 160ms ease, border-color 160ms ease; }
  .summary-card:hover { transform: translateY(-2px); }
  .capacity-summary { grid-area: capacity; }
  .latest-change { grid-area: change; color: #f3f6fa; background: linear-gradient(145deg,#111827,#1e293b); border-color: transparent; }
  [data-theme="dark"] .latest-change { background: linear-gradient(145deg,#172033,#1e293b); }
  .comparison-confidence { grid-area: confidence; }
  .summary-label { color: var(--muted); font-size: 12px; font-weight: 700; margin-bottom: 14px; }
  .latest-change .summary-label, .latest-change .summary-note { color: #aeb9c9; }
  .summary-title { font-size: 20px; letter-spacing: -.02em; margin-bottom: 8px; }
  .summary-note { color: var(--muted); font-size: 12px; line-height: 1.55; }
  .capacity-layout { display: grid; grid-template-columns: 92px 1fr; gap: 16px; align-items: center; }
  .capacity-layout .ring { width: 92px; }
  .capacity-layout .ring span { font-size: 20px; }
  .capacity-layout .summary-title { font-size: 18px; }
  .summary-facts { display: grid; grid-template-columns: repeat(3,minmax(0,1fr)); gap: 8px; margin-top: 16px; }
  .summary-fact { min-width: 0; }
  .summary-fact span { color: var(--muted); display: block; font-size: 11px; margin-bottom: 3px; }
  .summary-fact b { font-size: 15px; }
  .change-hero { display: flex; align-items: baseline; gap: 10px; flex-wrap: wrap; margin: 3px 0 12px; }
  .change-hero b { font-size: clamp(25px,3vw,36px); letter-spacing: -.04em; }
  .latest-change .change-metrics { background: rgba(255,255,255,.12); }
  .latest-change .change-metric { background: rgba(255,255,255,.06); }
  .latest-change .change-metric span { color: #aeb9c9; }
  .reliability-badge, .status-badge { display: inline-flex; align-items: center; width: fit-content; border-radius: 999px; padding: 6px 9px; font-size: 11px; font-weight: 700; }
  .reliability-badge { color: #dff8ed; background: rgba(5,150,105,.25); }
  .confidence-count { font-size: 34px; font-weight: 800; letter-spacing: -.04em; margin: 4px 0; }
  .confidence-list { display: grid; gap: 8px; margin-top: 14px; font-size: 12px; color: var(--muted); }
  .confidence-state.complete { color: var(--green); } .confidence-state.waiting { color: var(--unknown); }
  .confidence-state.partial { color: var(--orange); } .confidence-state.failed { color: var(--red); }
  .system-conclusion { padding: 15px 20px; }
  .conclusion-grid { display: grid; grid-template-columns: repeat(3,minmax(0,1fr)); gap: 8px; }
  .conclusion-item { display: grid; grid-template-columns: auto minmax(0,1fr); gap: 8px; align-items: center; min-width: 0; border-radius: 10px; background: var(--track); padding: 10px 12px; }
  .conclusion-item span { color: var(--blue); font-size: 11px; font-weight: 800; }
  .conclusion-item b { color: var(--text); font-size: 13px; font-weight: 650; line-height: 1.35; }
  .change-controls { display: grid; grid-template-columns: repeat(5,minmax(0,1fr)); padding: 14px; background: var(--panel); border: 1px solid var(--line); border-radius: 14px; }
  .change-controls .select, .change-controls .search { width: 100%; min-width: 0; background: var(--track); }
  .change-item { grid-template-columns: minmax(0,1fr) auto; gap: 8px 12px; }
  .change-main { min-width: 0; }
  .change-path { display: block; font-weight: 650; }
  .change-context { color: var(--muted); font-size: 11px; margin-top: 4px; }
  .change-side { display: flex; gap: 9px; align-items: center; }
  .change-lists.release-empty { grid-template-columns: 2fr 1fr; }
  .change-lists.growth-empty { grid-template-columns: 1fr 2fr; }
  .change-lists.release-empty .change-list:last-child, .change-lists.growth-empty .change-list:first-child { padding-bottom: 12px; }
  .intensity-track { grid-column: 1/-1; height: 3px; border-radius: 99px; background: var(--track); overflow: hidden; }
  .intensity-fill { display: block; height: 100%; width: var(--intensity); background: currentColor; transition: width 160ms ease; }
  .contribution { color: var(--muted); font-size: 11px; white-space: nowrap; }
  .grid { grid-template-columns: repeat(3,minmax(0,1fr)); }
  .card { min-width: 0; }
  .card-top-actions { display: flex; gap: 8px; align-items: center; }
  .status-badge.complete { color: var(--green); background: color-mix(in srgb,var(--green) 11%,transparent); }
  .status-badge.waiting { color: var(--unknown); background: color-mix(in srgb,var(--unknown) 13%,transparent); }
  .status-badge.partial { color: var(--orange); background: color-mix(in srgb,var(--orange) 11%,transparent); }
  .status-badge.failed { color: var(--red); background: color-mix(in srgb,var(--red) 11%,transparent); }
  .top-paths { display: grid; gap: 8px; margin-top: 10px; }
  .top-path-row { display: grid; grid-template-columns: minmax(0,1fr) auto auto; gap: 8px; align-items: center; min-width: 0; }
  .top-path-name { overflow: hidden; white-space: nowrap; text-overflow: ellipsis; min-width: 0; }
  .drive-details { border-top: 1px solid var(--line); margin-top: 14px; padding-top: 12px; }
  .drive-details summary { cursor: pointer; font-size: 12px; font-weight: 700; }
  .drive-details-body { display: grid; gap: 12px; margin-top: 12px; color: var(--muted); font-size: 12px; }
  .detail-groups { display: grid; grid-template-columns: 1fr 1fr; gap: 12px; }
  .detail-group { background: var(--track); border-radius: 10px; padding: 12px; min-width: 0; }
  .detail-group ul { margin: 7px 0 0 17px; }
  .scan-details { margin-top: 28px; border: 1px solid var(--line); }
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
    .conclusion-grid { grid-template-columns: 1fr; gap: 6px; }
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
    .change-lists.release-empty, .change-lists.growth-empty { grid-template-columns: 1fr; }
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
    .summary-grid { display: flex; flex-direction: column; }
    .latest-change { order: 1; } .capacity-summary { order: 2; } .comparison-confidence { order: 3; }
    .capacity-layout { grid-template-columns: 78px 1fr; } .capacity-layout .ring { width: 78px; }
    .summary-facts, .change-metrics, .change-controls, .scan-metadata, .scan-completeness-grid, .detail-groups { grid-template-columns: 1fr; }
    .change-side { align-items: flex-end; flex-direction: column; }
    .change-path.is-expanded, .top-path-name.is-expanded { white-space: normal; overflow-wrap: anywhere; }
    .top-path-row { grid-template-columns: minmax(0,1fr) auto; }
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

  <section class="overview" aria-label="磁盘摘要">
    <div class="summary-grid" id="summary-grid">
      <article class="summary-card capacity-summary" id="capacity-summary"></article>
      <article class="summary-card latest-change" id="latest-change"></article>
      <article class="summary-card comparison-confidence" id="comparison-confidence"></article>
    </div>
  </section>
  <section class="insights" aria-label="系统结论"><div class="system-conclusion" id="system-conclusion"></div></section>
  <div class="section-intro"><div><h2>变化详情</h2><p>摘要和排行会随筛选同步更新，整体容量保持不变</p></div></div>
  <section class="directory-overview" id="change-details">
    <div class="change-controls">
      <label>磁盘<select class="select" id="change-drive-filter" aria-label="筛选磁盘"></select></label>
      <label>目录层级<select class="select" id="change-level-filter" aria-label="筛选目录层级"><option value="1">一级目录</option><option value="2">二级目录</option><option value="all">全部层级</option></select></label>
      <label>变化方向<select class="select" id="change-direction-filter" aria-label="筛选变化方向"><option value="all">全部变化</option><option value="growth">仅增长</option><option value="release">仅释放</option></select></label>
      <label>数据状态<select class="select" id="change-state-filter" aria-label="筛选数据状态"><option value="reliable">可靠变化</option><option value="unknown">未知</option><option value="unavailable">不可用</option></select></label>
      <label>路径搜索<input class="search" id="change-path-filter" type="search" placeholder="筛选目录路径" aria-label="筛选目录路径"></label>
    </div>
    <div class="change-lists">
      <div class="change-list"><h3>Top 增长</h3><div id="growth-list"></div></div>
      <div class="change-list"><h3>Top 释放</h3><div id="release-list"></div></div>
    </div>
    <div class="change-list state-change-list" id="state-change-list" hidden><h3 id="state-change-title">数据状态</h3><div id="state-change-body"></div></div>
  </section>
  <div class="section-intro"><div><h2>磁盘详情</h2><p>容量趋势、比较可信度与目录来源</p></div></div>
  <section class="grid" id="grid"></section>
  <div class="empty" id="empty">没有匹配的磁盘</div>
  <details class="scan-details" id="scan-completeness"><summary>扫描完整性与详细原因</summary><div id="scan-detail-body"></div></details>
  <section class="scan-metadata" id="scan-metadata" aria-label="扫描元数据"></section>
  <footer id="footer"></footer>
</main>

<script>
const RAW_DATA = INJECT_DATA;
const RAW_HISTORY = INJECT_HISTORY;
const RAW_DIRECTORY = INJECT_DIRECTORY;
const RAW_SCAN_META = INJECT_SCAN_META;
const DATA = Array.isArray(RAW_DATA) ? RAW_DATA : RAW_DATA ? [RAW_DATA] : [];
const HISTORY = Array.isArray(RAW_HISTORY) ? RAW_HISTORY : RAW_HISTORY ? [RAW_HISTORY] : [];
const DIRECTORY = Array.isArray(RAW_DIRECTORY) ? RAW_DIRECTORY : RAW_DIRECTORY ? [RAW_DIRECTORY] : [];
const SCAN_META = RAW_SCAN_META || {};
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
  compact: false,
  driveLevels: {}
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
  const text = formatCapacityDelta(value);
  if (text === "容量基本不变") return `<span class="trend-st">${text}</span>`;
  return `<span class="${value > 0 ? "trend-up" : "trend-dn"}">${text}</span>`;
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

function directoryTopThree(id) {
  const item = DIRECTORY.find((entry) => entry.drive.replace(/\\/g, "") === id);
  return reliableChanges(item, 1).sort((a,b) => Math.abs(b.deltaBytes) - Math.abs(a.deltaBytes)).slice(0,3);
}

function changeRow(row, maxMagnitude, contributionBase) {
  const valueClass = row.deltaBytes >= 0 ? "growth-value" : "release-value";
  const intensity = maxMagnitude ? Math.max(4, Math.abs(Number(row.deltaBytes)) / maxMagnitude * 100) : 0;
  const contribution = contributionBase ? `${(Math.abs(Number(row.deltaBytes)) / contributionBase * 100).toFixed(1)}%` : "-";
  return `<div class="change-item"><div class="change-main"><span class="change-path expandable-path" title="${escapeHtml(row.displayPath)}">${escapeHtml(row.displayPath)}</span><div class="change-context">${escapeHtml(row.drive)} · ${row.level} 级 · 当前 ${fmtBytes(currentSizeBytes(row))} · 贡献 ${contribution}</div></div><div class="change-side"><b class="${valueClass}">${row.deltaBytes >= 0 ? "+" : ""}${fmtBytes(row.deltaBytes)}</b><button class="copy-path" type="button" data-copy-path="${escapeHtml(row.displayPath)}">复制路径</button></div><div class="intensity-track ${valueClass}"><span class="intensity-fill" style="--intensity:${intensity.toFixed(1)}%"></span></div></div>`;
}

function stateChangeRow(row) {
  const label = row.state === "unknown" ? "未知变化" : "当前不可用";
  return `<div class="change-item"><div class="change-main"><span class="change-path expandable-path" title="${escapeHtml(row.displayPath)}">${escapeHtml(row.displayPath)}</span><div class="change-context">${escapeHtml(row.drive)} · ${row.level} 级 · ${label}</div></div><span class="status-badge waiting">${label}</span></div>`;
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
  $("capacity-summary").innerHTML = `<div class="summary-label">整体容量</div><div class="capacity-layout"><div class="ring" style="--pct:${overallPct.toFixed(1)}"><span>${pct(overallPct)}</span></div><div><h2 class="summary-title">${capacityStatement(mostFull)}</h2><p class="summary-note">最高使用率 ${mostFull ? `${mostFull.id} ${pct(mostFull.percent)}` : "-"}</p></div></div><div class="summary-facts"><div class="summary-fact"><span>已用</span><b>${fmt(t.used)}</b></div><div class="summary-fact"><span>总容量</span><b>${fmt(t.total)}</b></div><div class="summary-fact"><span>剩余</span><b>${fmt(t.free)}</b></div></div>`;
}

function renderConfidence(items) {
  const c = confidenceFor(items);
  $("comparison-confidence").innerHTML = `<div class="summary-label">比较可信度</div><div class="confidence-count confidence-state ${c.state}">${c.comparable.length} / ${items.length}</div><h2 class="summary-title">个磁盘可可靠比较</h2><div class="confidence-list"><span>${c.waiting.length} 个等待完整基线</span><span>${c.incomplete.length + c.failed.length} 个扫描不完整</span><span>优先查看：${c.inspect ? escapeHtml(c.inspect.drive) : "无需检查"}</span></div>`;
}

function renderChangeSummary(items, summary, rankings) {
  const main = rankings.growth[0] || rankings.release[0];
  const gross = summary.added + summary.released;
  const contribution = main && gross ? Math.abs(Number(main.deltaBytes)) / gross * 100 : null;
  const headline = main ? `${main.deltaBytes > 0 ? "主要增长" : "主要释放"}来自 ${escapeHtml(main.displayPath)}` : emptyChangeCopy({waiting:!summary.comparable.length,comparable:summary.comparable.length > 0,kind:"all"});
  const fourthLabel = summary.activityPreferred ? "活动总量" : "目录解释率";
  const fourthValue = summary.activityPreferred ? fmtBytes(gross) : summary.rate === null ? "不适用" : `${summary.rate.toFixed(1)}%`;
  $("latest-change").innerHTML = `<div class="summary-label">最新变化</div><h2 class="summary-title">${headline}</h2><div class="change-hero"><b>${main ? `${main.deltaBytes > 0 ? "+" : ""}${fmtBytes(main.deltaBytes)}` : "—"}</b><span class="summary-note">${contribution === null ? "没有可靠变化排行" : `主路径贡献 ${contribution.toFixed(1)}%`}</span></div><div class="change-metrics"><div class="change-metric"><span>可靠新增</span><b>+${fmtBytes(summary.added)}</b></div><div class="change-metric"><span>可靠释放</span><b>${summary.released ? "-" : ""}${fmtBytes(summary.released)}</b></div><div class="change-metric"><span>已定位净变化</span><b>${fmtBytes(summary.located)}</b></div><div class="change-metric"><span>${fourthLabel}</span><b>${fourthValue}</b></div></div><div class="reliability-badge">${summary.comparable.length} / ${items.length} 个磁盘可可靠比较</div>`;
}

function renderConclusion(items, summary, rankings) {
  const mostFull = [...DATA].sort((a,b) => b.percent-a.percent)[0];
  const c = confidenceFor(items);
  const mainPaths = [...rankings.growth,...rankings.release].slice(0,2).map((row) => row.displayPath);
  const change = mainPaths.length ? `主要来自 ${mainPaths.join(" 和 ")}` : emptyChangeCopy({waiting:!summary.comparable.length,comparable:summary.comparable.length > 0,kind:"all"});
  const reliability = c.state === "complete" ? `${c.comparable.length} 个磁盘均可比较${summary.rate === null ? "" : ` · 解释率 ${summary.rate.toFixed(1)}%`}` : `${c.comparable.length} 个可比较 · ${c.waiting.length} 个等待 · ${c.incomplete.length + c.failed.length} 个不完整`;
  $("system-conclusion").innerHTML = `<div class="conclusion-grid"><div class="conclusion-item"><span>容量</span><b>${escapeHtml(capacityStatement(mostFull))}</b></div><div class="conclusion-item"><span>变化</span><b>${escapeHtml(change)}</b></div><div class="conclusion-item"><span>可信度</span><b>${escapeHtml(reliability)}</b></div></div>`;
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
  const growth = rankings.growth.slice(0,10), release = rankings.release.slice(0,10);
  const maxMagnitude = Math.max(0,...growth.concat(release).map((row) => Math.abs(Number(row.deltaBytes))));
  const gross = rows.filter(isReliableChange).reduce((sum,row) => sum + Math.abs(Number(row.deltaBytes)),0);
  const waiting = items.length > 0 && items.every((item) => !item.baselineScanId);
  const reliableView = filters.state === "reliable";
  const lists = $("change-details").querySelector(".change-lists");
  lists.hidden = !reliableView;
  lists.classList.toggle("release-empty",reliableView && growth.length > 0 && release.length === 0);
  lists.classList.toggle("growth-empty",reliableView && release.length > 0 && growth.length === 0);
  $("state-change-list").hidden = reliableView;
  if (reliableView) {
    $("growth-list").innerHTML = growth.map((row) => changeRow(row,maxMagnitude,gross)).join("") || `<div class="baseline-guide">${emptyChangeCopy({waiting,comparable:!waiting,kind:"growth"})}</div>`;
    $("release-list").innerHTML = release.map((row) => changeRow(row,maxMagnitude,gross)).join("") || `<div class="baseline-guide">${emptyChangeCopy({waiting,comparable:!waiting,kind:"release"})}</div>`;
  } else {
    $("state-change-title").textContent = filters.state === "unknown" ? "未知变化" : "不可用项目";
    $("state-change-body").innerHTML = rows.map(stateChangeRow).join("") || '<div class="baseline-guide">当前筛选没有对应项目。</div>';
  }
  const summary = summarizeChanges(items,rows);
  renderChangeSummary(items,summary,rankings);
  renderConfidence(items);
  renderConclusion(items,summary,rankings);
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
    const topThreeMax = Math.max(0,...topThree.map((row) => Math.abs(Number(row.deltaBytes))));
    const detailLevel = Number(state.driveLevels[d.id] || 1);
    const topTen = reliableChanges(directory,detailLevel).sort((a,b) => Math.abs(b.deltaBytes)-Math.abs(a.deltaBytes)).slice(0,10);
    const detailMax = Math.max(0,...topTen.map((row) => Math.abs(Number(row.deltaBytes))));
    const scanEvidence = classifyScanEvidence(directory ? [directory] : []);
    const cardStatus = !directory?.baselineScanId ? "waiting" : directory.status === "failed" ? "failed" : directory.status === "partial" ? "partial" : "complete";
    const activityLabel = coverage?.activityPreferred ? `活动总量 ${fmtBytes(Number(coverage.addedBytes || 0)+Number(coverage.releasedBytes || 0))}` : `目录解释率 ${directory ? coverageLabel(directory) : "-"}`;
    return `
      <article class="card ${d.status}">
        <div class="card-top">
          <div>
            <div class="drive-name">磁盘 ${d.id}</div>
            <div class="drive-sub">最近采样 ${lastSeen}</div>
          </div>
          <div class="card-top-actions"><span class="status-badge ${cardStatus}">${directory ? statusLabel(directory.status,directory.baselineScanId) : "未扫描"}</span><div class="badge">使用率 ${pct(d.percent)}</div><!-- badge-copy-v2 --></div>
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
        <div class="directory-card-extra"><b>${directory?.baselineScanId ? `目录净变化 ${fmtBytes(coverage?.actualNetBytes)}` : "当前目录规模已记录"}</b><span>${activityLabel}</span>${topThree.length ? `<div class="top-paths">${topThree.map((row) => `<div class="top-path-row"><span class="top-path-name expandable-path" title="${escapeHtml(row.displayPath)}">${escapeHtml(row.displayPath)}</span><b class="${row.deltaBytes >= 0 ? "growth-value" : "release-value"}">${row.deltaBytes >= 0 ? "+" : ""}${fmtBytes(row.deltaBytes)}</b><button class="copy-path" type="button" data-copy-path="${escapeHtml(row.displayPath)}">复制</button><span class="intensity-track ${row.deltaBytes>=0?"growth-value":"release-value"}"><span class="intensity-fill" style="--intensity:${topThreeMax?Math.max(4,Math.abs(Number(row.deltaBytes))/topThreeMax*100).toFixed(1):0}%"></span></span></div>`).join("")}</div>` : `<p>${directory?.baselineScanId ? "本次没有可靠目录变化。" : "建立完整基线后显示目录变化 Top 3。"}</p>`}</div>
        <details class="drive-details"><summary>展开目录与扫描详情</summary><div class="drive-details-body"><label>目录层级 <select class="select drive-level-switch" data-drive="${escapeHtml(d.id)}"><option value="1" ${detailLevel===1?"selected":""}>一级目录</option><option value="2" ${detailLevel===2?"selected":""}>二级目录</option></select></label><div class="top-paths">${topTen.length ? topTen.map((row) => `<div class="top-path-row"><span class="top-path-name expandable-path" title="${escapeHtml(row.displayPath)}">${escapeHtml(row.displayPath)}</span><b class="${row.deltaBytes >= 0 ? "growth-value" : "release-value"}">${row.deltaBytes >= 0 ? "+" : ""}${fmtBytes(row.deltaBytes)}</b><button class="copy-path" type="button" data-copy-path="${escapeHtml(row.displayPath)}">复制</button><span class="intensity-track ${row.deltaBytes>=0?"growth-value":"release-value"}"><span class="intensity-fill" style="--intensity:${detailMax ? Math.max(4,Math.abs(Number(row.deltaBytes))/detailMax*100).toFixed(1):0}%"></span></span></div>`).join("") : `<p>${emptyChangeCopy({waiting:!directory?.baselineScanId,comparable:Boolean(directory?.baselineScanId),kind:"all"})}</p>`}</div><div class="detail-groups"><div class="detail-group"><b>预期排除</b>${scanEvidence.expected.length?`<ul>${scanEvidence.expected.map((item)=>`<li title="${escapeHtml(item.path)}">${escapeHtml(item.path)} · ${escapeHtml(item.reason)}</li>`).join("")}</ul>`:"<p>无</p>"}</div><div class="detail-group"><b>意外不可用</b>${scanEvidence.unexpected.length?`<ul>${scanEvidence.unexpected.map((item)=>`<li title="${escapeHtml(item.path)}">${escapeHtml(item.path)} · ${escapeHtml(item.reason)}</li>`).join("")}</ul>`:"<p>无</p>"}</div></div><p>基线时间：${directory?.baselineCompletedAt?escapeHtml(directory.baselineCompletedAt):"等待完整基线"} · 扫描状态：${directory?statusLabel(directory.status,directory.baselineScanId):"未扫描"}</p><div>${sparkline(rows)}</div></div></details>
      </article>
    `;
  }).join("");
  requestAnimationFrame(() => {
    document.querySelectorAll(".bar-fill").forEach((bar) => {
      bar.style.width = bar.dataset.w;
    });
  });
}

function renderScanCompleteness() {
  const {expected,unexpected} = classifyScanEvidence(DIRECTORY);
  const list = (rows,empty) => rows.length ? `<ul>${rows.map((row) => `<li title="${escapeHtml(row.path)}">${escapeHtml(row.drive)} · ${escapeHtml(row.path)} · ${escapeHtml(row.reason)}</li>`).join("")}</ul>` : `<p>${empty}</p>`;
  $("scan-detail-body").innerHTML = `<div class="scan-completeness-grid"><div class="detail-group"><h3>预期排除</h3><p>重解析点、联接、符号链接、$RECYCLE.BIN 和 System Volume Information 属于正常排除。</p>${list(expected,"没有记录到预期排除项。")}</div><div class="detail-group"><h3>意外不可用</h3><p>访问被拒绝、扫描中消失、枚举失败或暂时不可用会列在这里。</p>${list(unexpected,"没有意外不可用项目。")}</div></div>`;
}

function renderScanMetadata() {
  const start = SCAN_META.startedAt ? new Date(SCAN_META.startedAt) : null;
  const end = SCAN_META.completedAt ? new Date(SCAN_META.completedAt) : null;
  const duration = start && end ? `${Math.max(0,Math.round((end-start)/1000))} 秒` : "-";
  const fields = [["扫描开始",formatLocalDate(SCAN_META.startedAt),SCAN_META.startedAt||"-"],["扫描完成",formatLocalDate(SCAN_META.completedAt),SCAN_META.completedAt||"-"],["总耗时",duration,duration],["扫描磁盘",`${Number(SCAN_META.driveCount||0)} 个`,`${Number(SCAN_META.driveCount||0)} 个`]];
  const metadata = fields.map(([label,value,title]) => `<div class="metadata-item"><span>${label}</span><b title="${escapeHtml(title)}">${escapeHtml(value)}</b></div>`).join("");
  const scanId = String(SCAN_META.scanId||"-");
  $("scan-metadata").innerHTML = `${metadata}<div class="metadata-item"><span>快照 ID</span><div class="snapshot-value"><b title="${escapeHtml(scanId)}">${escapeHtml(shortSnapshotId(scanId))}</b><button class="copy-path snapshot-copy" type="button" data-copy-path="${escapeHtml(scanId)}">复制</button></div></div>`;
}

function render() {
  document.body.classList.toggle("compact", state.compact);
  renderCapacitySummary();
  renderDirectoryChanges();
  renderCards();
  renderScanCompleteness();
  renderScanMetadata();
}

["change-drive-filter","change-level-filter","change-direction-filter","change-state-filter"].forEach((id) => $(id).addEventListener("change", renderDirectoryChanges));
$("change-path-filter").addEventListener("input", renderDirectoryChanges);
document.addEventListener("click", async (event) => {
  const button = event.target.closest(".copy-path");
  if (button) {
    const path = button.dataset.copyPath;
    try { await navigator.clipboard.writeText(path); const old=button.textContent; button.textContent="已复制"; setTimeout(()=>button.textContent=old,1200); }
    catch { alert(path); }
    return;
  }
  const path = event.target.closest(".expandable-path");
  if (path && window.matchMedia("(max-width: 560px)").matches) path.classList.toggle("is-expanded");
});
document.addEventListener("change", (event) => {
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
$html = $html.Replace('INJECT_SCAN_META', $scanMetaJson)
$html = $html.Replace('INJECT_TS', $timestamp)

$utf8NoBom = New-Object System.Text.UTF8Encoding $false
[System.IO.File]::WriteAllText($htmlFile, $html, $utf8NoBom)
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
