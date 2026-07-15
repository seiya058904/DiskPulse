$ErrorActionPreference = 'Stop'

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

$root = Split-Path -Parent $PSScriptRoot
$buildScript = Join-Path $root 'build-release.ps1'
$launcherSource = Get-Content -Raw -LiteralPath (Join-Path $root 'launcher\DiskPulseLauncher.cs') -Encoding UTF8
$output = Join-Path $env:TEMP ('DiskPulse-launcher-test-' + [guid]::NewGuid().ToString('N'))

Assert-True (Test-Path -LiteralPath $buildScript) 'build-release.ps1 is missing.'
Assert-True ($launcherSource -match 'DISKPULSE_NO_OPEN') 'Launcher must suppress script-side browser opening.'
Assert-True ($launcherSource -match 'app", "runtime') 'Launcher must migrate runtime data from the previous app folder.'
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $buildScript -OutputPath $output

$exe = Join-Path $output 'DiskPulse.exe'
Assert-True (Test-Path -LiteralPath $exe) 'DiskPulse.exe was not created.'
$files = @(Get-ChildItem -LiteralPath $output -File)
Assert-True ($files.Count -eq 1 -and $files[0].Name -eq 'DiskPulse.exe') 'Release output must contain only DiskPulse.exe.'
$bytes = [IO.File]::ReadAllBytes($exe)
Assert-True ($bytes.Length -gt 2 -and $bytes[0] -eq 0x4D -and $bytes[1] -eq 0x5A) 'Output is not a Windows executable.'

$assembly = [Reflection.Assembly]::LoadFrom($exe)
$dataType = $assembly.GetType('DataPaths', $true)
$migrate = $dataType.GetMethod('MigrateDirectory', [Reflection.BindingFlags]'NonPublic,Static')
$source = Join-Path $env:TEMP ('DiskPulse-migrate-source-' + [guid]::NewGuid().ToString('N'))
$destination = Join-Path $env:TEMP ('DiskPulse-migrate-destination-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path (Join-Path $source 'snapshots') -Force | Out-Null
New-Item -ItemType Directory -Path $destination -Force | Out-Null
Set-Content -LiteralPath (Join-Path $source 'snapshots\one.json') -Value 'old' -Encoding UTF8
Set-Content -LiteralPath (Join-Path $destination 'keep.txt') -Value 'new' -Encoding UTF8
$migrate.Invoke($null, [object[]]@([string]$source, [string]$destination)) | Out-Null
Assert-True (Test-Path -LiteralPath (Join-Path $destination 'snapshots\one.json')) 'Migration did not copy nested history files.'
Assert-True ((Get-Content -Raw -LiteralPath (Join-Path $destination 'keep.txt') -Encoding UTF8).Trim() -eq 'new') 'Migration overwrote existing data.'

Write-Output 'PASS: single-file launcher build'
