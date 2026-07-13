$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$projectRoot = Split-Path -Parent $PSScriptRoot
$source = Get-Content -Raw -LiteralPath (Join-Path $projectRoot 'check.bat') -Encoding UTF8
$required = @(
    'function Get-DiskPulsePaths',
    'function ConvertTo-JsonArray',
    'function New-ScanId',
    'function Copy-LegacyHistory',
    'function Acquire-DiskPulseLock',
    'function Write-ScanEvent',
    'function Write-AtomicJson'
)

foreach ($name in $required) {
    if ($source -notmatch [regex]::Escape($name)) {
        throw "Missing Phase 1 helper: $name"
    }
}

$env:DISKPULSE_TEST_MODE = '1'
$env:DISKPULSE_ROOT = $projectRoot
$env:DISKPULSE_SCRIPT_PATH = Join-Path $projectRoot 'check.bat'
$payload = $source.Substring($source.IndexOf('#>') + 2)
Invoke-Expression $payload

$single = ConvertTo-JsonArray @([pscustomobject]@{ value = 1 }) | ConvertFrom-Json
if ($single -isnot [array] -or $single.Count -ne 1) {
    throw 'Single-item JSON must remain an array.'
}

$ids = 1..5 | ForEach-Object { New-ScanId }
if (@($ids | Select-Object -Unique).Count -ne 5 -or @($ids | Where-Object { $_ -notmatch '^\d{8}-\d{6}-\d{3}-[0-9a-f]{6}$' }).Count) {
    throw 'Scan IDs must use milliseconds plus a unique six-character GUID suffix.'
}

$temp = Join-Path ([IO.Path]::GetTempPath()) ('DiskPulse-Phase1-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($temp) | Out-Null
try {
    $paths = [pscustomobject]@{
        Root = $temp
        Runtime = Join-Path $temp 'runtime'
        Legacy = Join-Path $temp 'runtime\legacy'
        Events = Join-Path $temp 'runtime\scans.jsonl'
        Lock = Join-Path $temp 'runtime\DiskPulse.lock'
    }
    Ensure-Directory $paths.Runtime
    Ensure-Directory $paths.Legacy

    'Timestamp,ID,Total,Free,Used,Percent' | Set-Content -LiteralPath (Join-Path $temp 'DiskPulse.csv') -Encoding UTF8
    Copy-LegacyHistory $paths | Out-Null
    if (-not (Test-Path -LiteralPath (Join-Path $paths.Legacy 'DiskPulse-v1.csv')) -or -not (Test-Path -LiteralPath (Join-Path $paths.Runtime '.legacy-imported'))) {
        throw 'Legacy history and marker must be created after validation.'
    }

    $owner = Acquire-DiskPulseLock $paths 'test-lock'
    try {
        Acquire-DiskPulseLock $paths 'second-lock' | Out-Null
        throw 'A live lock must reject a second owner.'
    }
    catch {
        if ($_.Exception.Message -eq 'A live lock must reject a second owner.') { throw }
    }
    Release-DiskPulseLock $paths $owner
    if (Test-Path -LiteralPath $paths.Lock) { throw 'The owning process must release its lock.' }

    Write-ScanEvent $paths ([pscustomobject]@{ scanId='event'; status='running' })
    Write-ScanEvent $paths ([pscustomobject]@{ scanId='event'; status='complete' })
    $events = @(Get-Content -LiteralPath $paths.Events -Encoding UTF8 | ForEach-Object { $_ | ConvertFrom-Json })
    if ($events.Count -ne 2 -or $events[-1].status -ne 'complete') { throw 'Scan events must append valid JSON lines.' }

    $jsonPath = Join-Path $paths.Runtime 'atomic.json'
    Write-AtomicJson $jsonPath ([pscustomobject]@{ ok=$true }) | Out-Null
    if (-not (Get-Content -Raw -LiteralPath $jsonPath -Encoding UTF8 | ConvertFrom-Json).ok) { throw 'Atomic JSON must be readable.' }
    try {
        Write-AtomicJson $jsonPath ([pscustomobject]@{ ok=$false }) | Out-Null
        throw 'Atomic JSON must reject an existing destination.'
    }
    catch {
        if ($_.Exception.Message -eq 'Atomic JSON must reject an existing destination.') { throw }
    }
}
finally {
    foreach ($file in @(
        (Join-Path $paths.Runtime 'atomic.json'),
        $paths.Events,
        $paths.Lock,
        (Join-Path $paths.Runtime '.legacy-imported'),
        (Join-Path $paths.Legacy 'DiskPulse-v1.csv'),
        (Join-Path $temp 'DiskPulse.csv')
    )) {
        if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file -Force }
    }
    [IO.Directory]::Delete($paths.Legacy)
    [IO.Directory]::Delete($paths.Runtime)
    [IO.Directory]::Delete($temp)
}

foreach ($marker in @('DriveInfo', 'critical', 'warning', 'data-theme', 'class="overview"', 'element("div","ring"', 'id="attention-center"', 'sparkline', 'estimateDays', 'id="search"', 'id="sort"', 'id="compact"', 'id="copy"', '@media')) {
    if ($source -notmatch [regex]::Escape($marker)) { throw "Stable dashboard marker missing: $marker" }
}

Write-Host 'PASS: Phase 1 helpers, locking, migration, events, atomic JSON, and stable dashboard markers.'
