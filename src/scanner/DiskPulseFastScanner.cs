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
