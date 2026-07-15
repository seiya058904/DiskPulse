$ErrorActionPreference = 'Stop'

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

$root = Split-Path -Parent $PSScriptRoot
$buildScript = Join-Path $root 'build-installer.ps1'
$installerScript = Join-Path $root 'installer\DiskPulse.nsi'

Assert-True (Test-Path -LiteralPath $buildScript) 'build-installer.ps1 is missing.'
Assert-True (Test-Path -LiteralPath $installerScript) 'installer/DiskPulse.nsi is missing.'
Assert-True (Test-Path -LiteralPath (Join-Path $root 'assets\DiskPulse.png')) 'assets/DiskPulse.png is missing.'
Assert-True (Test-Path -LiteralPath (Join-Path $root 'assets\DiskPulse.ico')) 'assets/DiskPulse.ico is missing.'
Assert-True ((Get-Content -Raw -LiteralPath (Join-Path $root 'check.bat') -Encoding UTF8) -match 'DISKPULSE_DATA_ROOT') 'check.bat does not support a separate data root.'

$output = Join-Path $env:TEMP ('DiskPulse-installer-test-' + [guid]::NewGuid().ToString('N'))
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $buildScript -OutputPath $output

$setup = Join-Path $output 'DiskPulse-Setup.exe'
Assert-True (Test-Path -LiteralPath $setup) 'DiskPulse-Setup.exe was not created.'
$bytes = [IO.File]::ReadAllBytes($setup)
Assert-True ($bytes.Length -gt 2 -and $bytes[0] -eq 0x4D -and $bytes[1] -eq 0x5A) 'Installer is not a Windows executable.'

Write-Output 'PASS: NSIS installer build'
