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
    [System.Runtime.InteropServices.DllImport("kernel32.dll", CharSet=System.Runtime.InteropServices.CharSet.Unicode, SetLastError=true)]
    static extern bool GetVolumeInformation(string rootPathName, System.Text.StringBuilder volumeNameBuffer, int volumeNameSize,
        out uint volumeSerialNumber, out uint maximumComponentLength, out uint fileSystemFlags,
        System.Text.StringBuilder fileSystemNameBuffer, int fileSystemNameSize);
    [System.Runtime.InteropServices.DllImport("kernel32.dll", CharSet=System.Runtime.InteropServices.CharSet.Unicode, SetLastError=true)]
    static extern bool GetVolumeNameForVolumeMountPoint(string volumeMountPoint, System.Text.StringBuilder volumeName, int bufferLength);
    [System.Runtime.InteropServices.DllImport("kernel32.dll", CharSet=System.Runtime.InteropServices.CharSet.Unicode, SetLastError=true)]
    static extern uint QueryDosDevice(string deviceName, System.Text.StringBuilder targetPath, int maxChars);
    // Stable Windows volume GUID path (for example \\?\Volume{...}), normalized without the
    // trailing separator, or "" when Windows cannot resolve the drive. SUBST aliases resolve to
    // the same owning volume GUID as their target, while distinct real volumes keep distinct GUIDs.
    // Failure is deliberately non-fatal: an unknown identity must never make a real drive vanish.
    public static string GetVolumeGuid(string rootPath) {
        if (string.IsNullOrEmpty(rootPath)) return "";
        try {
            string full=Path.GetFullPath(rootPath);
            if (!full.EndsWith("\\",StringComparison.Ordinal)) full += "\\";
            var name=new System.Text.StringBuilder(128);
            if (!GetVolumeNameForVolumeMountPoint(full, name, name.Capacity)) return "";
            string value=name.ToString().Trim();
            if (value.Length==0) return "";
            return value.TrimEnd('\\').ToUpperInvariant();
        } catch { return ""; }
    }
    // First DOS-device target for a drive letter (for example \Device\HarddiskVolume4 for a
    // real mount or \??\D: for a SUBST redirect), or "" when unavailable. This is not the
    // identity key; it is only a tie-breaker so a real mount point wins over its redirected alias.
    public static string GetDosDeviceTarget(string drive) {
        if (string.IsNullOrEmpty(drive)) return "";
        try {
            string name=drive.Trim().TrimEnd('\\');
            if (name.Length!=2 || name[1]!=':') return "";
            var target=new System.Text.StringBuilder(1024);
            if (QueryDosDevice(name, target, target.Capacity)==0) return "";
            return target.ToString();
        } catch { return ""; }
    }
    // Owning volume serial as 8 uppercase hex digits, or "" when it cannot be read. Retained for
    // diagnostics and compatibility only; it is not globally unique and is therefore not used as
    // the drive de-duplication key. Returns "" rather than throwing so an unreadable drive can
    // never abort a scan.
    public static string GetVolumeSerial(string rootPath) {
        if (string.IsNullOrEmpty(rootPath)) return "";
        try {
            uint serial, max, flags;
            if (!GetVolumeInformation(rootPath, null, 0, out serial, out max, out flags, null, 0)) return "";
            return serial.ToString("X8");
        } catch { return ""; }
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
                    catch(DirectoryNotFoundException ex) { AddEvidence(result.errors,entry,ex.Message,"transient-missing"); AddEvidence(result.unavailable,entry,"transient-missing"); }
                    catch(FileNotFoundException ex) { AddEvidence(result.errors,entry,ex.Message,"transient-missing"); AddEvidence(result.unavailable,entry,"transient-missing"); }
                    catch(Exception ex) { result.status="partial"; AddEvidence(result.errors,entry,ex.Message,"entry-disappeared"); AddEvidence(result.unavailable,entry,"entry-unavailable"); }
                }
                if(directory.Equals(root,StringComparison.OrdinalIgnoreCase)) { rootEnumerated=true; emit("scanning",current,true); }
            } catch(Exception ex) {
                if(directory.Equals(root,StringComparison.OrdinalIgnoreCase)) { AddEvidence(result.errors,directory,ex.Message,"enumeration-failed"); AddEvidence(result.unavailable,directory,"enumeration-failed"); result.status="failed"; rootFiles.enumerationComplete=false; rootFiles.childrenEnumerationComplete=false; break; }
                if(ex is UnauthorizedAccessException) AddEvidence(result.excluded,directory,"access-denied");
                else if(ex is DirectoryNotFoundException) { AddEvidence(result.errors,directory,ex.Message,"transient-missing"); AddEvidence(result.unavailable,directory,"transient-missing"); }
                else if(ex is FileNotFoundException) { AddEvidence(result.errors,directory,ex.Message,"transient-missing"); AddEvidence(result.unavailable,directory,"transient-missing"); }
                else { AddEvidence(result.errors,directory,ex.Message,"enumeration-failed"); AddEvidence(result.unavailable,directory,"enumeration-failed"); result.status="partial"; }
                foreach(var record in records.Values) if(record.kind=="directory" && (directory.Equals(record.displayPath,StringComparison.OrdinalIgnoreCase) || directory.StartsWith(record.displayPath.TrimEnd('\\')+"\\",StringComparison.OrdinalIgnoreCase))) record.childrenEnumerationComplete=false;
            }
            if(top!=null && pending.ContainsKey(top) && --pending[top]==0) { completed++; emit("scanning",directory,false); }
        }
        watch.Stop(); emit(result.status=="failed"?"failed":"complete",current,true);
        var failures=new List<DiskPulseFastEvidence>(result.unavailable);
        failures.AddRange(result.excluded.FindAll(e=>e.reason=="access-denied"));
        foreach(var evidence in failures) foreach(var record in records.Values) {
            if(record.kind=="directory" && (evidence.path.Equals(record.displayPath,StringComparison.OrdinalIgnoreCase) || evidence.path.StartsWith(record.displayPath.TrimEnd('\\')+"\\",StringComparison.OrdinalIgnoreCase))) record.childrenEnumerationComplete=false;
            if(record.kind=="rootFiles" && (evidence.path.Equals(root,StringComparison.OrdinalIgnoreCase) || (!records.ContainsKey(Key(evidence.path)) && String.Equals(Path.GetDirectoryName(evidence.path),root.TrimEnd('\\'),StringComparison.OrdinalIgnoreCase)))) record.childrenEnumerationComplete=false;
        }
        result.records.AddRange(records.Values); result.enumerationComplete=result.status=="complete"; result.childrenEnumerationComplete=result.status=="complete";
        return result;
    }
}
