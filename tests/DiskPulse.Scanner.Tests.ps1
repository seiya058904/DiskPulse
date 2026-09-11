$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'TestHelpers.ps1')
$projectRoot = Split-Path -Parent $PSScriptRoot
$canonicalTestSource = New-DiskPulseCanonicalTestSource -Components @('Common', 'Scanner', 'History', 'Progress', 'Persistence', 'AI')
try {
    . $canonicalTestSource
}
finally {
    if (Test-Path -LiteralPath $canonicalTestSource) { Remove-Item -LiteralPath $canonicalTestSource -Force }
}

if (-not (Get-Command Invoke-DirectoryScan -ErrorAction SilentlyContinue)) {
    throw 'Invoke-DirectoryScan is missing.'
}
if ([DiskPulseFastScanner]::NormalizeRoot('D:\') -ne 'D:\') {
    throw 'A drive root must retain its trailing separator so the whole drive is scanned.'
}

$progressLine = Format-ScanProgressLine -Progress ([pscustomobject]@{
    drive='T:'; filesProcessed=1234; directoriesProcessed=56; currentPath=('T:\' + ('long-path\' * 12)); elapsedMilliseconds=12500; percentComplete=50
}) -CompletedDrives 1 -TotalDrives 4
$filledBlock = [string][char]0x2588
$emptyBlock = [string][char]0x2591
if (-not $progressLine.Contains($filledBlock) -or -not $progressLine.Contains($emptyBlock) -or $progressLine -notmatch 'T:' -or $progressLine -notmatch '1234' -or $progressLine.Length -gt 130) {
    throw 'Lightweight progress line must show a bounded bar, drive, and activity counters.'
}

$renderState = @{ LastRenderedMilliseconds = -1 }
if (-not (Should-RenderConsoleProgress -Progress ([pscustomobject]@{ filesProcessed=0; completedTopLevel=0; totalTopLevel=10; elapsedMilliseconds=0 }) -State $renderState)) {
    throw 'The first console progress update must render immediately.'
}
if (Should-RenderConsoleProgress -Progress ([pscustomobject]@{ filesProcessed=10; completedTopLevel=1; totalTopLevel=10; elapsedMilliseconds=100 }) -State $renderState) {
    throw 'Console progress updates inside the one-second window must be skipped.'
}
if (-not (Should-RenderConsoleProgress -Progress ([pscustomobject]@{ filesProcessed=20; completedTopLevel=2; totalTopLevel=10; elapsedMilliseconds=1100 }) -State $renderState)) {
    throw 'Console progress must refresh after one second.'
}
if (-not (Should-RenderConsoleProgress -Progress ([pscustomobject]@{ filesProcessed=30; completedTopLevel=10; totalTopLevel=10; elapsedMilliseconds=1150 }) -State $renderState)) {
    throw 'The final console progress update must render immediately.'
}

$baselineNow = [pscustomobject]@{ scanId='now'; startedAt='2026-07-13T12:00:00Z'; drives=@([pscustomobject]@{ drive='T:'; rootPath='T:\' }) }
$baselineCandidates = @(
    [pscustomobject]@{ scanId='broken'; completedAt='2026-07-13T11:00:00Z'; drives=@([pscustomobject]@{ drive='T:'; status='complete' }) }
    [pscustomobject]@{ scanId='wrong-root'; completedAt='2026-07-13T10:30:00Z'; drives=@([pscustomobject]@{ drive='T:'; rootPath='T:'; status='complete'; usedBytes=1 }) }
    [pscustomobject]@{ scanId='valid'; completedAt='2026-07-13T10:00:00Z'; drives=@([pscustomobject]@{ drive='T:'; rootPath='T:\'; status='complete'; usedBytes=1 }) }
)
if ((Find-DriveBaseline -Snapshots $baselineCandidates -Drive 'T:' -Current $baselineNow).scanId -ne 'valid') {
    throw 'An incomplete snapshot must never be selected as a drive baseline.'
}

$temp = Join-Path ([IO.Path]::GetTempPath()) ('DiskPulse-Scanner-' + [guid]::NewGuid().ToString('N'))
$alpha = Join-Path $temp 'Alpha'
$a1 = Join-Path $alpha 'A1'
$unicodeName = ([string][char]0x6D4B) + [char]0x8BD5
$childName = ([string][char]0x5B50) + [char]0x76EE + [char]0x5F55
$unicode = Join-Path $temp $unicodeName
$u1 = Join-Path $unicode $childName
$empty = Join-Path $temp 'Empty'
$junction = Join-Path $temp 'AlphaLink'
$locked = Join-Path $temp 'Locked'
@($temp, $alpha, $a1, $unicode, $u1, $empty, $locked) | ForEach-Object { [IO.Directory]::CreateDirectory($_) | Out-Null }

try {
    [IO.File]::WriteAllBytes((Join-Path $temp 'root.bin'), ([byte[]](1..10)))
    [IO.File]::WriteAllBytes((Join-Path $alpha 'alpha.bin'), ([byte[]](1..20)))
    [IO.File]::WriteAllBytes((Join-Path $a1 'one.bin'), ([byte[]](1..30)))
    [IO.File]::WriteAllBytes((Join-Path $u1 'two.bin'), ([byte[]](1..40)))
    [IO.File]::WriteAllBytes((Join-Path $locked 'locked.bin'), ([byte[]](1..5)))
    cmd /c "mklink /J `"$junction`" `"$alpha`"" | Out-Null
    if (-not (Test-Path -LiteralPath $junction)) { throw "Test fixture could not create a junction." }

    $progressEvents = [System.Collections.Generic.List[object]]::new()
    $scan = Invoke-DirectoryScan -Drive "T:" -RootPath $temp -ProgressCallback {
        param($progress)
        $progressEvents.Add($progress)
    }
    if ($scan.status -ne 'complete') { throw "Fixture scan must complete, got $($scan.status)." }
    if (-not $progressEvents.Count) { throw "Progress callback must be invoked." }
    $previousFiles = 0
    $previousDirectories = 0
    $previousElapsed = 0
    foreach ($progress in $progressEvents) {
        if ([string]::IsNullOrWhiteSpace([string]$progress.phase) -or [string]::IsNullOrWhiteSpace([string]$progress.drive) -or [string]::IsNullOrWhiteSpace([string]$progress.currentPath)) {
            throw "Progress must include a phase, drive, and current path."
        }
        if ($progress.filesProcessed -lt $previousFiles -or $progress.directoriesProcessed -lt $previousDirectories -or $progress.elapsedMilliseconds -lt $previousElapsed) {
            throw "Progress counters must be monotonic."
        }
        if ($progress.percentComplete -lt -1 -or $progress.percentComplete -gt 100) { throw "Progress percent is out of range." }
        $previousFiles = $progress.filesProcessed
        $previousDirectories = $progress.directoriesProcessed
        $previousElapsed = $progress.elapsedMilliseconds
    }
    $finalProgress = $progressEvents[-1]
    if ($finalProgress.filesProcessed -ne 5 -or $finalProgress.directoriesProcessed -ne 7) {
        throw "Final progress counters must match real fixture activity."
    }
    if ($finalProgress.completedTopLevel -ne $finalProgress.totalTopLevel -or $finalProgress.totalTopLevel -ne 4) {
        throw "Every top-level subtree must be complete in final progress."
    }
    $expectedScanProperties = @('childrenEnumerationComplete','drive','enumerationComplete','errors','excluded','records','rootPath','scopeSignature','scopeVersion','status','unavailable')
    $actualScanProperties = @($scan.PSObject.Properties.Name | Sort-Object)
    if (($actualScanProperties -join ',') -ne ($expectedScanProperties -join ',')) {
        throw "Progress support must not change the snapshot drive structure."
    }
    $records = @($scan.records)
    $root = $records | Where-Object kind -eq "rootFiles"
    $alphaRecord = $records | Where-Object { $_.level -eq 1 -and $_.displayPath -eq $alpha }
    $a1Record = $records | Where-Object { $_.level -eq 2 -and $_.displayPath -eq $a1 }
    $unicodeRecord = $records | Where-Object { $_.level -eq 1 -and $_.displayPath -eq $unicode }
    $emptyRecord = $records | Where-Object { $_.level -eq 1 -and $_.displayPath -eq $empty }

    if ($root.sizeBytes -ne 10 -or $root.fileCount -ne 1) { throw "Root-file aggregate is incorrect." }
    if ($alphaRecord.sizeBytes -ne 50 -or $alphaRecord.fileCount -ne 2) { throw "Level-one aggregate is incorrect." }
    if ($a1Record.sizeBytes -ne 30 -or $a1Record.fileCount -ne 1) { throw "Level-two aggregate is incorrect." }
    if ($unicodeRecord.sizeBytes -ne 40 -or $emptyRecord.sizeBytes -ne 0) { throw "Unicode or empty-directory aggregation is incorrect." }
    if (-not (@($scan.excluded | Where-Object path -eq $junction).Count)) { throw "Reparse points must be excluded." }
    $alphaWithSeparator = $alpha.ToUpperInvariant() + [IO.Path]::DirectorySeparatorChar
    if ((Normalize-PathKey $alphaWithSeparator) -ne (Normalize-PathKey $alpha)) { throw "Normalized keys must ignore case and trailing separators." }

    $missing = Invoke-DirectoryScan -Drive "T:" -RootPath (Join-Path $temp "missing")
    if ($missing.status -ne "failed" -or @($missing.errors).Count -ne 1) { throw "Missing root must return failed with one error." }

    $denyResult = & icacls.exe $locked /inheritance:r /deny "$($env:USERNAME):(OI)(CI)F" 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Test fixture could not apply a temporary deny ACL: $denyResult" }
    $permissionScan = Invoke-DirectoryScan -Drive "T:" -RootPath $temp
    if ($permissionScan.status -ne "complete" -or @($permissionScan.unavailable).Count -ne 0 -or -not @($permissionScan.excluded | Where-Object reason -eq 'access-denied').Count) {
        throw "A child permission denial must be an explicit expected exclusion without making the drive partial."
    }
    & icacls.exe $locked /remove:d $env:USERNAME /inheritance:e | Out-Null

    # Three real native scans: a still-present parent must not report ACL loss as freed bytes.
    $full = Invoke-DirectoryScan -Drive 'T:' -RootPath $temp
    try {
        & icacls.exe $a1 /inheritance:r /deny "$($env:USERNAME):(OI)(CI)F" | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Nested ACL fixture failed.' }
        $denied = Invoke-DirectoryScan -Drive 'T:' -RootPath $temp
        $loss = @(Compare-DriveRecords $denied $full)
        $parentLoss = $loss | Where-Object displayPath -eq $alpha
        if ($parentLoss.state -ne 'unknown' -or $null -ne $parentLoss.deltaBytes) { throw 'ACL denial must not manufacture reliable release.' }
        if (@($loss | Where-Object { $_.displayPath -eq $unicode -and $_.state -eq 'unchanged' }).Count -ne 1) { throw 'ACL failure contaminated unrelated directory.' }
    } finally { & icacls.exe $a1 /remove:d $env:USERNAME /inheritance:e | Out-Null }
    $restored = Invoke-DirectoryScan -Drive 'T:' -RootPath $temp
    $gain = @(Compare-DriveRecords $restored $denied)
    if (@($gain | Where-Object { $_.displayPath -eq $alpha -and $_.state -eq 'unknown' }).Count -ne 1) { throw 'Incomplete baseline must not manufacture growth.' }
    if (@(Compare-DriveRecords $restored $full | Where-Object { $_.state -in @('created','changed','removed') }).Count) { throw 'Stable exclusions must allow unchanged comparison.' }
    $changedScope = $restored | ConvertTo-Json -Depth 12 | ConvertFrom-Json
    $changedScope.scopeSignature = 'changed-policy'
    if (@(Compare-DriveRecords $changedScope $full | Where-Object state -ne 'unknown').Count) { throw 'Different policy must not produce reliable deltas.' }
    $legacy = $full | ConvertTo-Json -Depth 12 | ConvertFrom-Json
    foreach($record in $legacy.records) { $record.PSObject.Properties.Remove('enumerationComplete') }
    if (@(Compare-DriveRecords $restored $legacy | Where-Object state -ne 'unknown').Count) { throw 'Missing legacy evidence must be explicit.' }
    foreach($drive in @($full,$denied,$restored)) { $drive | Add-Member usedBytes ([int64]1000) }
    $before=[pscustomobject]@{scanId='before-acl';startedAt='2026-01-01T00:00:00Z';completedAt='2026-01-01T00:01:00Z';status='complete';drives=@($full)}
    $during=[pscustomobject]@{scanId='during-acl';startedAt='2026-01-02T00:00:00Z';completedAt='2026-01-02T00:01:00Z';status='complete';drives=@($denied)}
    $after=[pscustomobject]@{scanId='after-acl';startedAt='2026-01-03T00:00:00Z';completedAt='2026-01-03T00:01:00Z';status='complete';drives=@($restored)}
    $center=@(New-HistoryComparisonCenter @($before) $during)
    $trend=$center[0].trends | Where-Object displayPath -eq $alpha
    if ($null -ne $trend.samples[-1][1] -or $trend.cumulativeBytes -ne 0) { throw 'History trend must leave a gap for incomplete aggregates.' }
    $baseline=Find-DriveBaseline @($before,$during) 'T:' $after
    $comparison=New-HistoryComparison $restored $baseline.drives[0] $baseline
    if ($comparison.coverage.addedBytes -ne 0 -or $comparison.coverage.releasedBytes -ne 0) { throw 'ACL recovery polluted coverage.' }
    $directory=@([pscustomobject]@{drive='T:';status='complete';baselineScanId=$baseline.scanId;changes=$comparison.changes;coverage=$comparison.coverage;errors=@();excluded=@();unavailable=@()})
    if (Test-DiskPulseAIInputEligible $directory) { throw 'ACL-only differences must not qualify as AI evidence.' }

    $callbackFailureScan = Invoke-DirectoryScan -Drive "T:" -RootPath $temp -ProgressCallback { throw "progress failure" }
    if ($callbackFailureScan.status -ne "complete") { throw "Progress callback errors must not change scan status." }

    $vanishing = Join-Path $temp 'vanishing.bin'
    [IO.File]::WriteAllBytes($vanishing, ([byte[]](1..6)))
    $vanishScan = Invoke-DirectoryScan -Drive "T:" -RootPath $temp -BeforeEntry {
        param($entry)
        if ($entry.FullName -eq $vanishing -and (Test-Path -LiteralPath $vanishing)) { Remove-Item -LiteralPath $vanishing -Force }
    }
    if ($vanishScan.status -eq "partial" -or -not @($vanishScan.unavailable | Where-Object reason -eq "transient-missing").Count -or -not @($vanishScan.errors | Where-Object kind -eq "transient-missing").Count) {
        throw "A vanishing entry must be recorded as transient-missing without making the drive partial."
    }

    [pscustomobject]@{
        level1 = @($records | Where-Object level -eq 1).Count
        level2 = @($records | Where-Object level -eq 2).Count
        rootFiles = $root.fileCount
        excluded = @($scan.excluded).Count
        unavailable = @($scan.unavailable).Count
        errors = @($scan.errors).Count
        permissionExcluded = @($permissionScan.excluded | Where-Object reason -eq 'access-denied').Count
        permissionErrors = @($permissionScan.errors).Count
        disappearingErrors = @($vanishScan.errors | Where-Object kind -eq "entry-disappeared").Count
    } | ConvertTo-Json -Compress | Write-Host
}
finally {
    if (Test-Path -LiteralPath $locked) { & icacls.exe $locked /remove:d $env:USERNAME /inheritance:e | Out-Null }
    $fixtureFiles = @(
        (Join-Path $u1 "two.bin")
        (Join-Path $a1 "one.bin")
        (Join-Path $alpha "alpha.bin")
        (Join-Path $temp "root.bin")
        (Join-Path $locked "locked.bin")
        (Join-Path $temp "vanishing.bin")
    )
    foreach ($file in $fixtureFiles) {
        if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file -Force }
    }
    if (Test-Path -LiteralPath $junction) { [IO.Directory]::Delete($junction) }
    foreach ($directory in @($u1, $unicode, $a1, $alpha, $empty, $locked, $temp)) {
        if (Test-Path -LiteralPath $directory) { [IO.Directory]::Delete($directory) }
    }
}

# --- Arithmetic, special characters, hidden/read-only, zero-byte ---
$specialRoot = Join-Path ([IO.Path]::GetTempPath()) ('DiskPulse-ScannerSpecial-' + [guid]::NewGuid().ToString('N'))
$dirA = Join-Path $specialRoot 'A (1) # & [x]'
$dirB = Join-Path $specialRoot 'B 测试'
$subA = Join-Path $dirA 'Sub'
New-Item -ItemType Directory -Path $dirA -Force | Out-Null
New-Item -ItemType Directory -Path $dirB -Force | Out-Null
New-Item -ItemType Directory -Path $subA -Force | Out-Null
$hiddenFile = $null
$readOnlyFile = $null
try {
    [IO.File]::WriteAllBytes((Join-Path $specialRoot 'root.bin'), ([byte[]](1..11)))
    [IO.File]::WriteAllBytes((Join-Path $dirA 'a.bin'), ([byte[]](1..23)))
    [IO.File]::WriteAllBytes((Join-Path $subA 'sub.bin'), ([byte[]](1..37)))
    [IO.File]::WriteAllBytes((Join-Path $dirB 'zero.bin'), ([byte[]]@()))
    $hiddenFile = Join-Path $specialRoot 'hidden.bin'
    [IO.File]::WriteAllBytes($hiddenFile, ([byte[]](1..5)))
    Set-ItemProperty -LiteralPath $hiddenFile -Name Attributes -Value ([IO.FileAttributes]::Hidden)
    $readOnlyFile = Join-Path $dirA 'readonly.bin'
    [IO.File]::WriteAllBytes($readOnlyFile, ([byte[]](1..7)))
    Set-ItemProperty -LiteralPath $readOnlyFile -Name Attributes -Value ([IO.FileAttributes]::ReadOnly)

    $specialScan = Invoke-DirectoryScan -Drive 'S:' -RootPath $specialRoot
    if ($specialScan.status -ne 'complete') { throw "Special-character fixture scan must complete, got $($specialScan.status)" }
    $rootRec = @($specialScan.records | Where-Object { $_.kind -eq 'rootFiles' })[0]
    $aRec = @($specialScan.records | Where-Object { $_.level -eq 1 -and $_.displayPath -eq $dirA })[0]
    $bRec = @($specialScan.records | Where-Object { $_.level -eq 1 -and $_.displayPath -eq $dirB })[0]
    $subRec = @($specialScan.records | Where-Object { $_.level -eq 2 -and $_.displayPath -eq $subA })[0]
    if ($rootRec.sizeBytes -ne 16) { throw "Root files must count root.bin + hidden.bin (16), got $($rootRec.sizeBytes)" }
    if ($aRec.sizeBytes -ne 67) { throw "Level-1 A must include a.bin + readonly.bin + Sub/sub.bin (67), got $($aRec.sizeBytes)" }
    if ($bRec.sizeBytes -ne 0 -or $bRec.fileCount -ne 1) { throw "Zero-byte file must preserve file count and contribute zero bytes." }
    if ($subRec.sizeBytes -ne 37) { throw "Level-2 Sub must be 37 bytes, got $($subRec.sizeBytes)" }
    if (@($specialScan.records | Where-Object { $_.key -eq (Normalize-PathKey $dirA) }).Count -ne 1) { throw 'Directory aggregation must not create duplicate logical keys.' }
}
finally {
    foreach ($file in @((Join-Path $specialRoot 'root.bin'), (Join-Path $dirA 'a.bin'), (Join-Path $subA 'sub.bin'), (Join-Path $dirB 'zero.bin'), $hiddenFile, $readOnlyFile)) {
        if (Test-Path -LiteralPath $file) {
            Set-ItemProperty -LiteralPath $file -Name Attributes -Value Normal -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
        }
    }
    if (Test-Path -LiteralPath $specialRoot) { Remove-Item -LiteralPath $specialRoot -Recurse -Force -ErrorAction SilentlyContinue }
}

# --- Reparse-point matrix: junction always, symlinks when supported ---
$linkBase = Join-Path ([IO.Path]::GetTempPath()) ('DiskPulse-ScannerLinks-' + [guid]::NewGuid().ToString('N'))
$linkRoot = Join-Path $linkBase 'scanroot'
$linkTarget = Join-Path $linkBase 'target'
$linkJunction = Join-Path $linkRoot 'junction'
$linkSymDir = Join-Path $linkRoot 'symdir'
$linkSymFile = Join-Path $linkRoot 'symfile.bin'
New-Item -ItemType Directory -Path $linkRoot -Force | Out-Null
New-Item -ItemType Directory -Path $linkTarget -Force | Out-Null
[IO.File]::WriteAllBytes((Join-Path $linkTarget 'inside.bin'), ([byte[]](1..9)))
$symlinkSupported = $true
try {
    cmd /c mklink /J "$linkJunction" "$linkTarget" | Out-Null
    try {
        New-Item -ItemType SymbolicLink -Path $linkSymDir -Target $linkTarget | Out-Null
        New-Item -ItemType SymbolicLink -Path $linkSymFile -Target (Join-Path $linkTarget 'inside.bin') | Out-Null
    } catch {
        $symlinkSupported = $false
    }

    $linkScan = Invoke-DirectoryScan -Drive 'L:' -RootPath $linkRoot
    if ($linkScan.status -ne 'complete') { throw "Link fixture scan must complete, got $($linkScan.status)" }
    if (@($linkScan.excluded | Where-Object { $_.path -eq $linkJunction -and $_.reason -eq 'reparse-point' }).Count -ne 1) {
        throw 'Directory junction must be excluded as a reparse point.'
    }
    if (@($linkScan.records | Where-Object { $_.displayPath -like '*target*' -or $_.displayPath -like '*inside.bin*' }).Count -ne 0) {
        throw 'Scanner must not traverse into linked target content.'
    }
    if ($symlinkSupported) {
        if (@($linkScan.excluded | Where-Object { $_.path -eq $linkSymDir -or $_.path -eq $linkSymFile -and $_.reason -eq 'reparse-point' }).Count -lt 1) {
            throw 'Supported symbolic links must be excluded as reparse points.'
        }
    } else {
        Write-Host 'SKIP: symbolic-link fixture not available without required privilege/developer mode.'
    }
}
finally {
    foreach ($link in @($linkJunction, $linkSymDir, $linkSymFile)) {
        if (Test-Path -LiteralPath $link) {
            Remove-Item -LiteralPath $link -Force -Recurse -ErrorAction SilentlyContinue
        }
    }
    if (Test-Path -LiteralPath $linkBase) { Remove-Item -LiteralPath $linkBase -Recurse -Force -ErrorAction SilentlyContinue }
}

# --- Very long path: conditional on host/filesystem support ---
$longRoot = Join-Path ([IO.Path]::GetTempPath()) ('DiskPulse-ScannerLong-' + [guid]::NewGuid().ToString('N'))
$longCurrent = $longRoot
$longSegments = New-Object 'System.Collections.Generic.List[string]'
$longSupported = $true
try {
    while ($longCurrent.Length -lt 280) {
        $longNext = Join-Path $longCurrent ('seg-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        [IO.Directory]::CreateDirectory($longNext) | Out-Null
        $longSegments.Add($longNext)
        $longCurrent = $longNext
    }
    [IO.File]::WriteAllBytes((Join-Path $longCurrent 'deep.bin'), ([byte[]](1..3)))
}
catch {
    $longSupported = $false
    Write-Host 'SKIP: very long path fixture could not be created on this host.'
}
if ($longSupported) {
    try {
        $longScan = Invoke-DirectoryScan -Drive 'L:' -RootPath $longRoot
        if ($longScan.status -eq 'failed' -and @($longScan.errors).Count -gt 0) {
            Write-Host 'SKIP: scanner does not guarantee long-path support on this host.'
        } else {
            $longRecordsWithDeepFile = @($longScan.records | Where-Object { $_.sizeBytes -eq 3 -and $_.fileCount -ge 1 })
            if ($longScan.status -ne 'complete' -or $longRecordsWithDeepFile.Count -eq 0) {
                throw "Long-path scan did not account for the deep file in directory aggregation records: status=$($longScan.status), matchingRecords=$($longRecordsWithDeepFile.Count)"
            }
        }
    }
    finally {
        if (Test-Path -LiteralPath $longRoot) { Remove-Item -LiteralPath $longRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

# --- Numeric type audit ---
$csharpSource = Get-Content -Raw -LiteralPath (Join-Path $projectRoot 'src\scanner\DiskPulseFastScanner.cs') -Encoding UTF8
if ($csharpSource -notmatch 'long sizeBytes' -or $csharpSource -notmatch 'long length') {
    throw 'C# scanner must use 64-bit long for file/aggregate byte accounting.'
}
$numericRecord = New-DirectoryRecord 'T:\numeric' 1
$numericRecord.sizeBytes = [int64]::MaxValue
if ($numericRecord.sizeBytes.GetType().Name -ne 'Int64') { throw 'PowerShell aggregate record size must remain Int64.' }

# --- Scanner to snapshot integration ---
$snapRoot = Join-Path ([IO.Path]::GetTempPath()) ('DiskPulse-ScannerSnapshot-' + [guid]::NewGuid().ToString('N'))
$snapRuntime = Join-Path $snapRoot 'runtime'
$snapSnapshots = Join-Path $snapRuntime 'snapshots'
New-Item -ItemType Directory -Path $snapSnapshots -Force | Out-Null
$snapPaths = [pscustomobject]@{ Runtime=$snapRuntime; Snapshots=$snapSnapshots; Events=Join-Path $snapRuntime 'scans.jsonl' }
try {
    [IO.File]::WriteAllBytes((Join-Path $snapRoot 'snap.bin'), ([byte[]](1..42)))
    $snapScan = Invoke-DirectoryScan -Drive 'T:' -RootPath $snapRoot
    $snapDrive = [pscustomobject]@{
        drive = 'T:'
        rootPath = $snapRoot
        status = $snapScan.status
        usedBytes = 42
        records = $snapScan.records
        excluded = $snapScan.excluded
        unavailable = $snapScan.unavailable
        errors = $snapScan.errors
    }
    $snapshot = [pscustomobject]@{
        scanId = 'scanner-snapshot-integration'
        startedAt = '2026-01-01T00:00:00Z'
        completedAt = '2026-01-01T00:01:00Z'
        status = 'complete'
        drives = @($snapDrive)
    }
    Write-AtomicJson (Join-Path $snapSnapshots ($snapshot.scanId + '.json')) $snapshot
    Write-ScanEvent $snapPaths ([pscustomobject]@{ scanId = $snapshot.scanId; status = 'complete'; completedAt = $snapshot.completedAt })
    $readSnapshots = Read-Snapshots $snapPaths
    if (@($readSnapshots | Where-Object scanId -eq $snapshot.scanId).Count -ne 1) {
        throw 'Scanner-produced snapshot must survive snapshot persistence and Read-Snapshots.'
    }
}
finally {
    if (Test-Path -LiteralPath $snapRoot) { Remove-Item -LiteralPath $snapRoot -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Host "PASS: real directory scanner aggregation and root failure behavior."
