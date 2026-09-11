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

function New-IsolatedPaths {
    param([string]$Name)
    $root = Join-Path ([IO.Path]::GetTempPath()) ('DiskPulse-Persistence-' + $Name + '-' + [guid]::NewGuid().ToString('N'))
    $runtime = Join-Path $root 'runtime'
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

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('DiskPulse-Persistence-Suite-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot -Force | Out-Null

try {
    # --- Atomic text publication preserves old file on failed validation ---
    $atomic = Join-Path $testRoot 'atomic'
    New-Item -ItemType Directory -Path $atomic -Force | Out-Null
    $htmlFile = Join-Path $atomic 'DiskPulse.html'
    [IO.File]::WriteAllText($htmlFile, '<html>old</html>', (New-Object Text.UTF8Encoding $false))

    try {
        Write-DiskPulseAtomicText -FinalPath $htmlFile -Content '<html>new</html>' -Validate {
            param($Path)
            return $false
        }
        throw 'Expected validation failure'
    }
    catch {
        if ($_.Exception.Message -eq 'Expected validation failure') { throw }
    }

    Assert-True ((Get-Content -Raw -LiteralPath $htmlFile -Encoding UTF8) -eq '<html>old</html>') 'Old HTML must survive failed publication.'
    Assert-True (@(Get-ChildItem -LiteralPath $atomic -Filter '.diskpulse-*.tmp' -File).Count -eq 0) 'Failed publication must not leave temp files.'

    Write-DiskPulseAtomicText -FinalPath $htmlFile -Content '<html>new</html>'
    Assert-True ((Get-Content -Raw -LiteralPath $htmlFile -Encoding UTF8) -eq '<html>new</html>') 'Successful atomic text replacement must publish new content.'

    $newHtml = Join-Path $atomic 'new.html'
    Write-DiskPulseAtomicText -FinalPath $newHtml -Content '<html>first</html>'
    Assert-True ((Get-Content -Raw -LiteralPath $newHtml -Encoding UTF8) -eq '<html>first</html>') 'First atomic write must create the destination.'

    # --- CSV atomic publication ---
    $csvDir = Join-Path $testRoot 'csv'
    New-Item -ItemType Directory -Path $csvDir -Force | Out-Null
    $csvFile = Join-Path $csvDir 'DiskPulse.csv'
    $csvRows = @(
        [pscustomobject]@{ Timestamp = '2026-01-01 00:00:00'; ID = 'C:'; Total = '100.00'; Free = '40.00'; Used = '60.00'; Percent = '60.0' }
        [pscustomobject]@{ Timestamp = '2026-01-01 00:00:00'; ID = 'D:'; Total = '200.00'; Free = '100.00'; Used = '100.00'; Percent = '50.0' }
    )
    Write-DiskPulseAtomicCsv -FinalPath $csvFile -Rows $csvRows
    $importedCsv = @(Import-Csv -LiteralPath $csvFile)
    Assert-True ($importedCsv.Count -eq 2) 'CSV atomic publication must preserve all rows.'
    Assert-True ($importedCsv[0].ID -eq 'C:') 'CSV row order/content must be preserved.'
    Assert-True (@(Get-ChildItem -LiteralPath $csvDir -Filter '.diskpulse-*.tmp' -File).Count -eq 0) 'CSV publication must not leave temp files.'

    # --- Write-AtomicJson behavior ---
    $jsonDir = Join-Path $testRoot 'json'
    New-Item -ItemType Directory -Path $jsonDir -Force | Out-Null
    $jsonPath = Join-Path $jsonDir 'snapshot.json'
    Write-AtomicJson $jsonPath ([pscustomobject]@{ scanId = 's1'; status = 'complete' })
    Assert-True (Test-Path -LiteralPath $jsonPath) 'Write-AtomicJson must create a valid snapshot file.'
    try {
        Write-AtomicJson $jsonPath ([pscustomobject]@{ scanId = 's2'; status = 'complete' })
        throw 'Expected overwrite rejection'
    }
    catch {
        if ($_.Exception.Message -eq 'Expected overwrite rejection') { throw }
    }
    Assert-True (@(Get-ChildItem -LiteralPath $jsonDir -Filter '.diskpulse-*.tmp' -File).Count -eq 0) 'Write-AtomicJson must not leave temp files.'

    # --- Corrupt snapshot tolerance ---
    $snapPaths = New-IsolatedPaths 'snapshots'
    Set-Content -LiteralPath $snapPaths.Events -Value '{"scanId":"valid","status":"complete","completedAt":"2026-01-01T00:00:00Z"}' -Encoding UTF8
    $validSnapshot = [pscustomobject]@{
        scanId = 'valid'
        completedAt = '2026-01-01T00:00:00Z'
        drives = @([pscustomobject]@{ drive = 'C:'; rootPath = 'C:\'; status = 'complete'; usedBytes = 1 })
    }
    Write-AtomicJson (Join-Path $snapPaths.Snapshots 'valid.json') $validSnapshot
    Set-Content -LiteralPath (Join-Path $snapPaths.Snapshots 'bad.json') -Value '{bad' -Encoding UTF8
    $snapshots = Read-Snapshots $snapPaths
    Assert-True (@($snapshots | Where-Object scanId -eq 'valid').Count -eq 1) 'Valid snapshot must remain usable next to a malformed snapshot.'
    Assert-True (@($snapshots | Where-Object scanId -eq 'bad').Count -eq 0) 'Malformed snapshot must be ignored.'

    # --- Corrupt scan-event line tolerance and interrupted-scan idempotence ---
    $eventPaths = New-IsolatedPaths 'events'
    $eventLines = @(
        '{"scanId":"old","status":"complete","completedAt":"2026-01-01T00:00:00Z"}'
        '{bad json'
        '{"scanId":"run","status":"running","startedAt":"2026-01-01T00:00:00Z"}'
        '{"scanId":"new","status":"complete","completedAt":"2026-01-02T00:00:00Z"}'
    )
    Set-Content -LiteralPath $eventPaths.Events -Value ($eventLines -join [Environment]::NewLine) -Encoding UTF8
    $originalEvents=[IO.File]::ReadAllText($eventPaths.Events)
    try { Complete-InterruptedScans $eventPaths; throw 'Middle corruption accepted.' }
    catch { Assert-True ($_.Exception.Message -ne 'Middle corruption accepted.') 'Middle corruption must be diagnosed.' }
    Assert-True ([IO.File]::ReadAllText($eventPaths.Events) -eq $originalEvents) 'Recovery must preserve a corrupt journal.'
    Set-Content -LiteralPath $eventPaths.Events -Value (($eventLines | Where-Object { $_ -ne '{bad json' }) -join [Environment]::NewLine) -Encoding UTF8
    Complete-InterruptedScans $eventPaths
    $eventsAfterFirst = @(Get-Content -LiteralPath $eventPaths.Events -Encoding UTF8 | Where-Object { $_.Trim() } | ForEach-Object { try { $_ | ConvertFrom-Json } catch { $null } } | Where-Object { $_ })
    Assert-True (@($eventsAfterFirst | Where-Object { $_.status -eq 'failed' -and $_.reason -eq 'interrupted' }).Count -eq 1) 'Interrupted scan must be finalized once.'
    $firstCount = $eventsAfterFirst.Count
    Complete-InterruptedScans $eventPaths
    $eventsAfterSecond = @(Get-Content -LiteralPath $eventPaths.Events -Encoding UTF8 | Where-Object { $_.Trim() } | ForEach-Object { try { $_ | ConvertFrom-Json } catch { $null } } | Where-Object { $_ })
    Assert-True ($eventsAfterSecond.Count -eq $firstCount) 'Interrupted-scan recovery must be idempotent.'

    # --- Large synthetic scan-event compaction ---
    $compactPaths = New-IsolatedPaths 'compact'
    $largeLines = New-Object 'System.Collections.Generic.List[string]'
    for ($i = 0; $i -lt 750; $i++) {
        $id = 'scan{0:D4}' -f $i
        $largeLines.Add((ConvertTo-Json -InputObject ([pscustomobject]@{ scanId = $id; status = 'running'; startedAt = '2026-01-01T00:00:00Z' }) -Compress))
        $largeLines.Add((ConvertTo-Json -InputObject ([pscustomobject]@{ scanId = $id; status = 'complete'; completedAt = '2026-01-02T00:00:00Z' }) -Compress))
    }
    $largeLines.Add('{bad json')
    Set-Content -LiteralPath $compactPaths.Events -Value ($largeLines -join [Environment]::NewLine) -Encoding UTF8

    $protectedSnapshot = [pscustomobject]@{
        scanId = 'scan0000'
        completedAt = '2026-01-02T00:00:00Z'
        status = 'complete'
        drives = @()
    }
    Write-AtomicJson (Join-Path $compactPaths.Snapshots 'scan0000.json') $protectedSnapshot

    $beforeLines = @(Get-Content -LiteralPath $compactPaths.Events -Encoding UTF8 | Where-Object { $_.Trim() })
    $beforeBytes = (Get-Item -LiteralPath $compactPaths.Events).Length
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    Compact-ScanEvents -Paths $compactPaths -MaxLines 500 -RecentFinalizedScans 10
    $stopwatch.Stop()
    $afterLines = @(Get-Content -LiteralPath $compactPaths.Events -Encoding UTF8 | Where-Object { $_.Trim() })
    $afterBytes = (Get-Item -LiteralPath $compactPaths.Events).Length

    Assert-True ($afterLines.Count -lt $beforeLines.Count) 'Compaction must reduce the event journal.'
    Assert-True ($afterLines.Count -le 300) 'Compaction must bound the event journal.'
    Assert-True (@($afterLines | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object scanId -eq 'scan0000').Count -gt 0) 'Compaction must retain events for retained snapshots.'
    Assert-True (@($afterLines | Where-Object { $_ -match 'bad json' }).Count -eq 0) 'Compaction must drop malformed lines.'
    Assert-True (@(Get-ChildItem -LiteralPath $compactPaths.Runtime -Filter '.diskpulse-*.tmp' -File).Count -eq 0) 'Compaction must not leave temp files.'

    Write-Host ("EVENT_COMPACT {0} lines {1} bytes -> {2} lines {3} bytes {4} ms" -f $beforeLines.Count, $beforeBytes, $afterLines.Count, $afterBytes, $stopwatch.ElapsedMilliseconds)
}
finally {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host 'PASS: persistence atomic publication, corrupt snapshot/event tolerance, and bounded event compaction.'
