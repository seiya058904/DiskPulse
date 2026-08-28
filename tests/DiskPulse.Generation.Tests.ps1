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
    foreach ($name in @('Get-DiskPulsePaths','Write-ScanEvent','Compact-ScanEvents','Invoke-DirectoryScan','Read-Snapshots','New-HistoryComparisonCenter','Invoke-DiskPulseAIAnalysis','Invoke-DiskPulse')) {
        if (-not (Get-Command $name -ErrorAction SilentlyContinue)) {
            throw "Generated check.bat is missing function: $name"
        }
    }

    Write-Host ("GENERATION hash={0} bytes={1}" -f $hashA, (Get-Item -LiteralPath $generatedA).Length)
}
finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host 'PASS: canonical generation is deterministic and tracked check.bat is fresh.'
