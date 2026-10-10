$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$projectRoot = Split-Path -Parent $PSScriptRoot
$source = Get-Content -Raw -LiteralPath (Join-Path $projectRoot 'check.bat') -Encoding UTF8
$env:DISKPULSE_TEST_MODE = '1'
$env:DISKPULSE_ROOT = $projectRoot
$env:DISKPULSE_SCRIPT_PATH = Join-Path $projectRoot 'check.bat'
Invoke-Expression $source.Substring($source.IndexOf('#>') + 2)

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function New-RetentionPaths {
    param([string]$Name)
    # The bracketed variant exercises literal-path handling: '[' and ']' are
    # wildcard characters for -Path but literal for -LiteralPath.
    $leafName = if ($Name -like '*bracket') { 'data[retention-test]' } else { 'data-retention-test' }
    $root = Join-Path ([IO.Path]::GetTempPath()) ('DiskPulse-Retention-' + [guid]::NewGuid().ToString('N'))
    $runtime = Join-Path $root $leafName
    $snapshots = Join-Path $runtime 'snapshots'
    New-Item -ItemType Directory -Path $snapshots -Force | Out-Null
    return [pscustomobject]@{
        Root      = $root
        Runtime   = $runtime
        Snapshots = $snapshots
        Events    = Join-Path $runtime 'scans.jsonl'
        Csv       = Join-Path $runtime 'DiskPulse.csv'
        Html      = Join-Path $runtime 'DiskPulse.html'
    }
}

function New-RetentionSnapshot {
    param([string]$ScanId, [string]$CompletedAt, [string[]]$Drives = @('C:'), [string]$Status = 'complete')
    return [pscustomobject]@{
        scanId      = $ScanId
        status      = $Status
        completedAt = $CompletedAt
        startedAt   = $CompletedAt
        drives      = @($Drives | ForEach-Object {
            [pscustomobject]@{ drive = $_; rootPath = $_; status = 'complete'; usedBytes = 1 }
        })
    }
}

function Write-RetentionSnapshots {
    param($Paths, [array]$Snapshots)
    # Real scans also record a finalized event in scans.jsonl; Read-Snapshots
    # only returns snapshots whose event status is complete/partial.
    $base = [datetime]'2026-01-01T00:00:00Z'
    $events = New-Object 'System.Collections.Generic.List[string]'
    for ($i = 0; $i -lt $Snapshots.Count; $i++) {
        $completed = $base.AddMinutes($i).ToUniversalTime().ToString('o')
        $snapshot = $Snapshots[$i]
        $snapshot | Add-Member -NotePropertyName completedAt -NotePropertyValue $completed -Force
        $json = ConvertTo-Json -InputObject $snapshot -Depth 12
        [IO.File]::WriteAllText((Join-Path $Paths.Snapshots ($snapshot.scanId + '.json')), $json, (New-Object Text.UTF8Encoding $false))
        $events.Add((ConvertTo-Json -InputObject ([pscustomobject]@{ scanId = $snapshot.scanId; status = 'complete'; completedAt = $completed }) -Compress))
    }
    [IO.File]::WriteAllText($Paths.Events, ($events -join [Environment]::NewLine) + [Environment]::NewLine, (New-Object Text.UTF8Encoding $false))
}

function Get-RetainedIds {
    param($Paths)
    # Count only real snapshots; malformed files are asserted separately.
    return @(Get-ChildItem -LiteralPath $Paths.Snapshots -Filter 'ret-*.json' -File |
        ForEach-Object { [IO.Path]::GetFileNameWithoutExtension($_.Name) } |
        Sort-Object)
}

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('DiskPulse-Retention-Suite-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot -Force | Out-Null

try {
    # --- 29 and 30 snapshots: nothing is removed, in both directory shapes ---
    foreach ($count in @(29, 30)) {
        foreach ($shape in @('plain', 'bracket')) {
            $paths = New-RetentionPaths ('keep' + $count + $shape)
            $ids = 0..($count - 1) | ForEach-Object { 'ret-{0:D2}' -f $_ }
            Write-RetentionSnapshots -Paths $paths -Snapshots @($ids | ForEach-Object { New-RetentionSnapshot -ScanId $_ })
            Invoke-SnapshotRetention -Paths $paths -Snapshots @(Read-Snapshots $paths) -CurrentDrives @('C:') -CurrentScanId 'ret-29' -Limit 30
            $retained = Get-RetainedIds -Paths $paths
            Assert-True ($retained.Count -eq $count) ("{0}/{1}: retention below the limit must remove nothing (kept {2})." -f $count, $shape, $retained.Count)
        }
    }

    # --- 31 snapshots: exactly the oldest snapshot is removed; plain and
    #     bracketed directories must produce the identical retention set ---
    foreach ($shape in @('plain', 'bracket')) {
        $paths = New-RetentionPaths ('limit31' + $shape)
        $ids = 0..30 | ForEach-Object { 'ret-{0:D2}' -f $_ }
        Write-RetentionSnapshots -Paths $paths -Snapshots @($ids | ForEach-Object { New-RetentionSnapshot -ScanId $_ })
        Invoke-SnapshotRetention -Paths $paths -Snapshots @(Read-Snapshots $paths) -CurrentDrives @('C:') -CurrentScanId 'ret-30' -Limit 30
        $retained = Get-RetainedIds -Paths $paths
        Assert-True ($retained.Count -eq 30) ("31/{0}: retention must keep exactly 30 snapshots (kept {1})." -f $shape, $retained.Count)
        Assert-True ($retained -notcontains 'ret-00') ("31/{0}: the oldest snapshot must be removed." -f $shape)
        Assert-True (($retained | Where-Object { $_ -ne 'ret-30' }).Count -eq 29) ("31/{0}: newer snapshots must remain." -f $shape)
    }

    # --- 35 snapshots: the five oldest go, the newest 30 remain in both shapes ---
    foreach ($shape in @('plain', 'bracket')) {
        $paths = New-RetentionPaths ('limit35' + $shape)
        $ids = 0..34 | ForEach-Object { 'ret-{0:D2}' -f $_ }
        Write-RetentionSnapshots -Paths $paths -Snapshots @($ids | ForEach-Object { New-RetentionSnapshot -ScanId $_ })
        Invoke-SnapshotRetention -Paths $paths -Snapshots @(Read-Snapshots $paths) -CurrentDrives @('C:') -CurrentScanId 'ret-34' -Limit 30
        $retained = Get-RetainedIds -Paths $paths
        $expected = 5..34 | ForEach-Object { 'ret-{0:D2}' -f $_ }
        Assert-True (@($retained).Count -eq 30) ("35/{0}: retention must keep exactly 30 snapshots (kept {1})." -f $shape, $retained.Count)
        Assert-True (@(Compare-Object -ReferenceObject $expected -DifferenceObject $retained).Count -eq 0) ("35/{0}: the newest 30 snapshots must remain." -f $shape)
    }

    # --- per-drive protection: the only D: snapshot survives even when oldest ---
    foreach ($shape in @('plain', 'bracket')) {
        $paths = New-RetentionPaths ('driveprot' + $shape)
        $ids = 0..30 | ForEach-Object { 'ret-{0:D2}' -f $_ }
        $snapshots = @($ids | ForEach-Object { New-RetentionSnapshot -ScanId $_ })
        # ret-00 is the oldest overall but the only snapshot containing a D: drive
        $snapshots[0] = New-RetentionSnapshot -ScanId 'ret-00' -Drives @('C:', 'D:')
        Write-RetentionSnapshots -Paths $paths -Snapshots $snapshots
        Invoke-SnapshotRetention -Paths $paths -Snapshots @(Read-Snapshots $paths) -CurrentDrives @('C:', 'D:') -CurrentScanId 'ret-30' -Limit 30
        $retained = Get-RetainedIds -Paths $paths
        Assert-True ($retained.Count -eq 30) ("protection/{0}: retention must keep exactly 30 snapshots (kept {1})." -f $shape, $retained.Count)
        Assert-True ($retained -contains 'ret-00') ("protection/{0}: the only D: snapshot must be protected despite being oldest." -f $shape)
        Assert-True ($retained -notcontains 'ret-01') ("protection/{0}: the next-oldest unprotected snapshot must be removed instead." -f $shape)
    }

    # --- malformed files and other extensions are ignored and preserved ---
    foreach ($shape in @('plain', 'bracket')) {
        $paths = New-RetentionPaths ('malformed' + $shape)
        $ids = 0..30 | ForEach-Object { 'ret-{0:D2}' -f $_ }
        Write-RetentionSnapshots -Paths $paths -Snapshots @($ids | ForEach-Object { New-RetentionSnapshot -ScanId $_ })
        Set-Content -LiteralPath (Join-Path $paths.Snapshots 'bad.json') -Value '{bad json' -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $paths.Snapshots 'notes.txt') -Value 'not a snapshot' -Encoding UTF8
        New-Item -ItemType Directory -Path (Join-Path $paths.Snapshots 'subdir') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $paths.Snapshots 'subdir\nested.json') -Value '{}' -Encoding UTF8
        Invoke-SnapshotRetention -Paths $paths -Snapshots @(Read-Snapshots $paths) -CurrentDrives @('C:') -CurrentScanId 'ret-30' -Limit 30
        $retained = Get-RetainedIds -Paths $paths
        Assert-True ($retained.Count -eq 30) ("malformed/{0}: malformed files must not count as retention candidates (kept {1})." -f $shape, $retained.Count)
        Assert-True (Test-Path -LiteralPath (Join-Path $paths.Snapshots 'bad.json')) 'malformed/{0}: malformed JSON must be preserved, not deleted.'
        Assert-True (Test-Path -LiteralPath (Join-Path $paths.Snapshots 'notes.txt')) 'malformed/{0}: non-snapshot files must be preserved.'
        Assert-True (Test-Path -LiteralPath (Join-Path $paths.Snapshots 'subdir\nested.json')) 'malformed/{0}: subdirectories must not be traversed for retention.'
    }

    Write-Host 'PASS: snapshot retention honours literal paths, the 30-snapshot limit, per-drive protection, and malformed-file tolerance.'
}
finally {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
