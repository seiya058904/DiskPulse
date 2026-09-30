function Get-DiskPulseDriveVolumeGuid {
    param([string] $Drive)
    # Volume GUID is the authoritative identity used for cross-letter de-duplication. Windows
    # resolves a SUBST letter to the same owning volume GUID as its target. Failure returns an
    # empty string so an unknown identity is kept rather than guessed.
    if ([string]::IsNullOrWhiteSpace($Drive)) { return '' }
    try { return [DiskPulseFastScanner]::GetVolumeGuid($Drive.TrimEnd('\') + '\') } catch { return '' }
}

function Get-DiskPulseDosDeviceTarget {
    param([string] $Drive)
    # Used only to prefer a real mount point over a SUBST/DOS redirect when two letters share the
    # same Volume GUID. Failure is unknown and never removes a drive by itself.
    if ([string]::IsNullOrWhiteSpace($Drive)) { return '' }
    try { return [DiskPulseFastScanner]::GetDosDeviceTarget($Drive.TrimEnd('\')) } catch { return '' }
}

function Get-DiskPulseDriveVolumeSerial {
    param([string] $Drive)
    # Retained as diagnostic metadata/fallback evidence only. Volume serial numbers are not globally
    # unique and therefore are no longer used to decide whether two drive letters are the same volume.
    if ([string]::IsNullOrWhiteSpace($Drive)) { return '' }
    try { return [DiskPulseFastScanner]::GetVolumeSerial($Drive.TrimEnd('\') + '\') } catch { return '' }
}

function Invoke-DirectoryScan {
    param(
        [string] $Drive,
        [string] $RootPath,
        [scriptblock] $BeforeEntry,
        [scriptblock] $ProgressCallback,
        [string] $VolumeGuid
    )

    # App passes the queried identity, including an explicit empty result. Direct callers
    # resolve the volume containing RootPath, not their synthetic/display drive letter.
    if (-not $PSBoundParameters.ContainsKey('VolumeGuid')) {
        $VolumeGuid = Get-DiskPulseDriveVolumeGuid ([IO.Path]::GetPathRoot([IO.Path]::GetFullPath($RootPath)))
    }
    $VolumeGuid = ConvertTo-DiskPulseVolumeGuid $VolumeGuid

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
            volumeGuid                  = $VolumeGuid
            scopeSignature              = 'diskpulse-scope-v1:fixed;depth=2;reparse=exclude;names=$recycle.bin,system volume information'
            scopeVersion                = 1
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
                        if (-not $entry.Exists) {
                            # Entry vanished between enumeration and processing (TOCTOU): record as
                            # transient-missing, skip it, do NOT flip the drive to partial.
                            $errors.Add([PSCustomObject]@{ path = [string]$entry.FullName; reason = "Entry disappeared during scan."; kind = "transient-missing" })
                            $unavailable.Add([PSCustomObject]@{ path = [string]$entry.FullName; reason = "transient-missing" })
                            continue
                        }
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
                    elseif ($_.Exception -is [DirectoryNotFoundException] -or $_.Exception -is [FileNotFoundException]) {
                        $errors.Add([PSCustomObject]@{ path = [string]$entry.FullName; reason = $_.Exception.Message; kind = "transient-missing" })
                        $unavailable.Add([PSCustomObject]@{ path = [string]$entry.FullName; reason = "transient-missing" })
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
            elseif ($_.Exception -is [DirectoryNotFoundException] -or $_.Exception -is [FileNotFoundException]) {
                $errors.Add([PSCustomObject]@{ path = $directory; reason = $_.Exception.Message; kind = "transient-missing" })
                $unavailable.Add([PSCustomObject]@{ path = $directory; reason = "transient-missing" })
            }
            else {
                $errors.Add([PSCustomObject]@{ path = $directory; reason = $_.Exception.Message; kind = "enumeration-failed" })
                $unavailable.Add([PSCustomObject]@{ path = $directory; reason = "enumeration-failed" })
                $status = "partial"
            }
            foreach ($record in $records.Values) {
                if ($record.kind -eq "directory" -and ($directory -eq $record.displayPath -or $directory.StartsWith($record.displayPath.TrimEnd('\')+'\', [StringComparison]::OrdinalIgnoreCase))) {
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
    foreach ($e in ([object[]]$unavailable)+@($excluded | Where-Object { $_.reason -eq 'access-denied' })) {
        foreach ($record in $recordValues) {
            if ($record.kind -eq 'directory' -and ($e.path -eq $record.displayPath -or $e.path.StartsWith($record.displayPath.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase))) { $record.childrenEnumerationComplete=$false }
            if ($record.kind -eq 'rootFiles' -and ($e.path -eq $root -or (-not $records.ContainsKey((Normalize-PathKey $e.path)) -and [IO.Path]::GetDirectoryName($e.path) -eq $root.TrimEnd('\')))) { $record.childrenEnumerationComplete=$false }
        }
    }
    $excludedValues = [object[]]$excluded
    $unavailableValues = [object[]]$unavailable
    $errorValues = [object[]]$errors
    [PSCustomObject]@{
        drive                       = $Drive.ToUpperInvariant()
        volumeGuid                  = $VolumeGuid
        scopeSignature              = 'diskpulse-scope-v1:fixed;depth=2;reparse=exclude;names=$recycle.bin,system volume information'
        scopeVersion                = 1
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
