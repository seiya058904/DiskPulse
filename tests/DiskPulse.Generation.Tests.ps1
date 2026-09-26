$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$projectRoot = Split-Path -Parent $PSScriptRoot
$generator = Join-Path $projectRoot 'scripts\build-check.ps1'
$trackedCheckBat = Join-Path $projectRoot 'check.bat'

$requiredSources = @(
    'src\bootstrap.bat'
    'src\powershell\Common.ps1'
    'src\powershell\Scanner.ps1'
    'src\powershell\History.ps1'
    'src\powershell\Persistence.ps1'
    'src\powershell\Progress.ps1'
    'src\powershell\AI.ps1'
    'src\powershell\App.ps1'
    'src\scanner\DiskPulseFastScanner.cs'
    'src\dashboard\template.html'
    'src\dashboard\styles.css'
    'src\dashboard\app.js'
)

foreach ($relative in $requiredSources) {
    $path = Join-Path $projectRoot $relative
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Missing canonical source: $relative"
    }
}

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

$tempRoot = Join-Path $env:TEMP ('DiskPulse-Generation-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

try {
    $generatedA = Join-Path $tempRoot 'check-a.bat'
    $generatedB = Join-Path $tempRoot 'check-b.bat'

    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $generator -OutputPath $generatedA
    if ($LASTEXITCODE -ne 0) { throw 'First generation failed.' }
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $generator -OutputPath $generatedB
    if ($LASTEXITCODE -ne 0) { throw 'Second generation failed.' }

    $hashA = (Get-FileHash -Algorithm SHA256 -LiteralPath $generatedA).Hash
    $hashB = (Get-FileHash -Algorithm SHA256 -LiteralPath $generatedB).Hash
    $trackedHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $trackedCheckBat).Hash

    Assert-True ($hashA -eq $hashB) 'Generation must be deterministic across runs.'
    Assert-True ($hashA -eq $trackedHash) 'Tracked check.bat must match freshly generated output.'

    $generatedContent = Get-Content -Raw -LiteralPath $generatedA -Encoding UTF8
    $payload = $generatedContent.Substring($generatedContent.IndexOf('#>') + 2)
    $null = [scriptblock]::Create($payload)

    $env:DISKPULSE_TEST_MODE = '1'
    $env:DISKPULSE_ROOT = $projectRoot
    $env:DISKPULSE_SCRIPT_PATH = $generatedA
    Invoke-Expression $payload
    foreach ($name in @('Get-DiskPulsePaths','Write-ScanEvent','Compact-ScanEvents','Invoke-DirectoryScan','Read-Snapshots','New-HistoryComparisonCenter','Invoke-DiskPulseAIAnalysis','Invoke-DiskPulse','Select-DiskPulseScannableDrives','Get-DiskPulseDriveVolumeGuid','Get-DiskPulseDosDeviceTarget','Get-DiskPulseDriveVolumeSerial')) {
        if (-not (Get-Command $name -ErrorAction SilentlyContinue)) {
            throw "Generated check.bat is missing function: $name"
        }
    }
    # Resolving drive aliases is what keeps a SUBST-style drive letter from being scanned and counted
    # twice, so the generated pipeline must actually call it rather than merely define it.
    Assert-True ($generatedContent.Contains('Select-DiskPulseScannableDrives -Drives $drives')) 'Generated check.bat must resolve drive aliases during enumeration.'
    Assert-True ($generatedContent.Contains('VolumeGuid         = Get-DiskPulseDriveVolumeGuid')) 'Generated check.bat must resolve authoritative Volume GUID identity before de-duplication.'
    Assert-True ($generatedContent.Contains('DosDeviceTarget     = Get-DiskPulseDosDeviceTarget')) 'Generated check.bat must classify DOS redirects so the real mount point wins canonical selection.'
    Assert-True ($generatedContent.Contains('$skippedDriveAliases')) 'Generated check.bat must carry the skipped drive aliases into the report.'

    # The dashboard reads driveAliases as a list. A one-element list must serialize as a list too,
    # which is exactly what a calculated Select-Object property fails to do.
    $metaSnapshot = [pscustomobject]@{ scanId = 'scan-1'; startedAt = 's'; completedAt = 'c'; status = 'complete'; drives = @([pscustomobject]@{ drive = 'C:' }) }
    $singleAliasMeta = New-DiskPulseScanMetaJson -Snapshot $metaSnapshot -DriveAliases @([pscustomobject]@{ id = 'X:'; aliasOf = 'D:' })
    Assert-True ($singleAliasMeta.Contains('"driveAliases":[{"id":"X:","aliasOf":"D:"}]')) "A single skipped drive alias must serialize as a one-element list, got: $singleAliasMeta"
    $noAliasMeta = New-DiskPulseScanMetaJson -Snapshot $metaSnapshot -DriveAliases @()
    Assert-True ($noAliasMeta.Contains('"driveAliases":[]')) "Without a skipped alias the list must serialize as empty, got: $noAliasMeta"
    Assert-True ($noAliasMeta.Contains('"driveCount":1')) "The scan metadata must keep reporting the scanned drive count, got: $noAliasMeta"

    Write-Host ("GENERATION hash={0} bytes={1}" -f $hashA, (Get-Item -LiteralPath $generatedA).Length)
}
finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host 'PASS: canonical generation is deterministic and tracked check.bat is fresh.'
