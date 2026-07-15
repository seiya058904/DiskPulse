param(
    [string]$OutputPath = (Join-Path $PSScriptRoot 'dist')
)

$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath($PSScriptRoot)
$output = [IO.Path]::GetFullPath($OutputPath)
$makensis = 'D:\xia zai\NSIS\makensis.exe'

if (-not (Test-Path -LiteralPath $makensis)) { throw "NSIS compiler not found: $makensis" }
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'build-release.ps1') -OutputPath $output
if ($LASTEXITCODE -ne 0) { throw 'Main EXE build failed.' }
New-Item -ItemType Directory -Path $output -Force | Out-Null
& $makensis "/DPROJECT_ROOT=$root" "/DOUTPUT_PATH=$output" (Join-Path $root 'installer\DiskPulse.nsi')
if ($LASTEXITCODE -ne 0) { throw "NSIS build failed with exit code $LASTEXITCODE." }
Write-Output "Built: $(Join-Path $output 'DiskPulse-Setup.exe')"
