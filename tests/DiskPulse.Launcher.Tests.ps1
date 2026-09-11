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
$expectedVersion = (Get-Content -Raw -LiteralPath (Join-Path $root 'version.txt') -Encoding UTF8).Trim()
$expectedVersion4 = if ($expectedVersion.Split('.').Count -ge 4) { $expectedVersion } else { $expectedVersion + '.0' * (4 - $expectedVersion.Split('.').Count) }
$exeVersionInfo = (Get-Item -LiteralPath $exe).VersionInfo
Assert-True ($exeVersionInfo.FileVersion -eq $expectedVersion4) 'DiskPulse.exe FileVersion must match the canonical version.'
Assert-True ($exeVersionInfo.ProductVersion -eq $expectedVersion) 'DiskPulse.exe ProductVersion must match the canonical version.'

$assembly = [Reflection.Assembly]::LoadFrom($exe)
$dataType = $assembly.GetType('DataPaths', $true)
$migrate = $dataType.GetMethod('RunMigration', [Reflection.BindingFlags]'NonPublic,Static')
$payloadRoot = Join-Path $output 'payload'
$extract = $assembly.GetType('Payload').GetMethod('EnsureExtracted', [Reflection.BindingFlags]'NonPublic,Static', $null, [Type[]]@([string]), $null)
$extract.Invoke($null, [object[]]@([string]$payloadRoot)) | Out-Null
$source = Join-Path $env:TEMP ('DiskPulse-migrate-source-' + [guid]::NewGuid().ToString('N'))
$destination = Join-Path $env:TEMP ('DiskPulse-migrate-destination-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path (Join-Path $source 'snapshots') -Force | Out-Null
$runtime = Join-Path $destination 'runtime'
New-Item -ItemType Directory -Path $runtime -Force | Out-Null
Set-Content -LiteralPath (Join-Path $source 'snapshots\one.json') -Value '{"scanId":"one","completedAt":"2026-01-01T00:00:00Z","drives":[]}' -Encoding UTF8
Set-Content -LiteralPath (Join-Path $source 'scans.jsonl') -Value '{"scanId":"one","status":"complete"}' -Encoding UTF8
Set-Content -LiteralPath (Join-Path $runtime 'keep.txt') -Value 'new' -Encoding UTF8
$diagnostics = $migrate.Invoke($null, [object[]]@([string]$payloadRoot, [string]$destination, [string[]]@($source)))
Assert-True ([string]::IsNullOrWhiteSpace($diagnostics)) 'Packaged migration returned an error.'
Assert-True (Test-Path -LiteralPath (Join-Path $runtime 'snapshots\one.json')) 'Migration did not import nested history files.'
Assert-True ((Get-Content -Raw -LiteralPath (Join-Path $runtime 'keep.txt') -Encoding UTF8).Trim() -eq 'new') 'Migration overwrote existing data.'

Write-Output 'PASS: single-file launcher build'
