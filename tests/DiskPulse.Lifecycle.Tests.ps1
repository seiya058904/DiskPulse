$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$projectRoot = Split-Path -Parent $PSScriptRoot

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

$outputDir = Join-Path $env:TEMP ('DiskPulse-Lifecycle-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $projectRoot 'build-release.ps1') -OutputPath $outputDir
if ($LASTEXITCODE -ne 0) { throw 'Launcher build failed.' }
$exe = Join-Path $outputDir 'DiskPulse.exe'
Assert-True (Test-Path -LiteralPath $exe) 'DiskPulse.exe was not created.'

$assembly = [Reflection.Assembly]::LoadFrom($exe)
$payloadType = $assembly.GetType('Payload', $true)
$dataPathsType = $assembly.GetType('DataPaths', $true)
$ensureExtracted = $payloadType.GetMethod('EnsureExtracted', [Reflection.BindingFlags]'NonPublic,Static', $null, [Type[]]@([string]), $null)
$migrate = $dataPathsType.GetMethod('MigrateDirectory', [Reflection.BindingFlags]'NonPublic,Static')

# --- Payload extraction ---
$payloadRoot = Join-Path $env:TEMP ('DiskPulse-PayloadRoot-' + [guid]::NewGuid().ToString('N'))
try {
    $ensureExtracted.Invoke($null, [object[]]@([string]$payloadRoot)) | Out-Null
    foreach ($relative in @('check.bat', 'DiskPulse.vbs', 'configure-ai.bat', 'assets\DiskPulse-dashboard.png')) {
        Assert-True (Test-Path -LiteralPath (Join-Path $payloadRoot $relative)) "Payload file missing: $relative"
    }

    $checkPath = Join-Path $payloadRoot 'check.bat'
    $firstHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $checkPath).Hash
    $ensureExtracted.Invoke($null, [object[]]@([string]$payloadRoot)) | Out-Null
    $secondHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $checkPath).Hash
    Assert-True ($firstHash -eq $secondHash) 'Identical payload extraction must leave files unchanged.'

    [IO.File]::WriteAllText($checkPath, 'truncated', (New-Object Text.UTF8Encoding $false))
    $ensureExtracted.Invoke($null, [object[]]@([string]$payloadRoot)) | Out-Null
    $repairedHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $checkPath).Hash
    Assert-True ($repairedHash -eq $firstHash) 'Corrupt replaceable payload must be repaired from embedded resource.'

    Assert-True (@(Get-ChildItem -LiteralPath $payloadRoot -Recurse -Filter '*.tmp' -File).Count -eq 0) 'Payload extraction must not leave temp files.'
}
finally {
    if (Test-Path -LiteralPath $payloadRoot) { Remove-Item -LiteralPath $payloadRoot -Recurse -Force -ErrorAction SilentlyContinue }
}

# --- Migration behavior ---
$migrationBase = Join-Path $env:TEMP ('DiskPulse-Migration-' + [guid]::NewGuid().ToString('N'))
$legacySource = Join-Path $migrationBase 'legacy'
$currentDestination = Join-Path $migrationBase 'current'
$outsideSentinelDir = Join-Path $migrationBase 'outside'
New-Item -ItemType Directory -Path (Join-Path $legacySource 'snapshots') -Force | Out-Null
New-Item -ItemType Directory -Path $currentDestination -Force | Out-Null
New-Item -ItemType Directory -Path $outsideSentinelDir -Force | Out-Null
try {
    [IO.File]::WriteAllText((Join-Path $legacySource 'DiskPulse.csv'), 'old-csv', (New-Object Text.UTF8Encoding $false))
    [IO.File]::WriteAllText((Join-Path $legacySource 'snapshots\one.json'), 'old-snapshot', (New-Object Text.UTF8Encoding $false))

    # New-only destination must remain untouched.
    [IO.File]::WriteAllText((Join-Path $currentDestination 'keep.txt'), 'new-data', (New-Object Text.UTF8Encoding $false))
    $migrate.Invoke($null, [object[]]@([string]$legacySource, [string]$currentDestination)) | Out-Null
    Assert-True ((Get-Content -Raw -LiteralPath (Join-Path $currentDestination 'keep.txt') -Encoding UTF8) -eq 'new-data') 'Migration must not overwrite existing destination data.'
    Assert-True ((Get-Content -Raw -LiteralPath (Join-Path $currentDestination 'DiskPulse.csv') -Encoding UTF8) -eq 'old-csv') 'Legacy-only file should migrate.'
    Assert-True ((Get-Content -Raw -LiteralPath (Join-Path $currentDestination 'snapshots\one.json') -Encoding UTF8) -eq 'old-snapshot') 'Nested legacy files should migrate preserving relative paths.'

    # Reparse-point safety: a junction inside legacy points outside and must not be traversed.
    $junction = Join-Path $legacySource 'escape'
    cmd /c mklink /J "$junction" "$outsideSentinelDir" | Out-Null
    [IO.File]::WriteAllText((Join-Path $outsideSentinelDir 'sentinel.txt'), 'do-not-copy', (New-Object Text.UTF8Encoding $false))
    $migrate.Invoke($null, [object[]]@([string]$legacySource, [string]$currentDestination)) | Out-Null
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $currentDestination 'escape\sentinel.txt'))) 'Migration must not traverse reparse points.'
}
finally {
    if (Test-Path -LiteralPath $migrationBase) { Remove-Item -LiteralPath $migrationBase -Recurse -Force -ErrorAction SilentlyContinue }
    if (Test-Path -LiteralPath $outputDir) { Remove-Item -LiteralPath $outputDir -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Host 'PASS: launcher payload extraction, self-repair, and migration safety.'
