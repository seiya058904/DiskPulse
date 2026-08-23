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
$buildSource = Get-Content -Raw -LiteralPath $buildScript -Encoding UTF8
Assert-True ($buildSource -match '\[string\]\$NsisPath') 'Installer build must accept an explicit NSIS path.'
Assert-True ($buildSource -match 'DISKPULSE_NSIS_PATH' -and $buildSource -match 'Get-Command makensis\.exe') 'Installer build must support portable NSIS discovery.'
Assert-True ($buildSource -match 'DEXE_PATH') 'Installer build must pass the generated launcher path to NSIS.'
$installerSource = Get-Content -Raw -LiteralPath $installerScript -Encoding UTF8
Assert-True ($installerSource -match 'InstallDir "\$LOCALAPPDATA\\DiskPulse"') 'Installer must use the DiskPulse folder as the application directory.'
Assert-True ($installerSource -notmatch 'InstallDir "\$LOCALAPPDATA\\DiskPulse\\app"') 'Installer must not use a generic app folder.'
Assert-True ($installerSource -match '!include "MUI2\.nsh"') 'Installer must use the NSIS Modern UI.'
Assert-True ($installerSource -match 'MUI_PAGE_WELCOME' -and $installerSource -match 'MUI_PAGE_FINISH') 'Installer must include welcome and finish pages.'
Assert-True (Test-Path -LiteralPath (Join-Path $root 'assets\DiskPulse.png')) 'assets/DiskPulse.png is missing.'
Assert-True (Test-Path -LiteralPath (Join-Path $root 'assets\DiskPulse.ico')) 'assets/DiskPulse.ico is missing.'
Assert-True ((Get-Content -Raw -LiteralPath (Join-Path $root 'check.bat') -Encoding UTF8) -match 'DISKPULSE_DATA_ROOT') 'check.bat does not support a separate data root.'

$output = Join-Path $env:TEMP ('DiskPulse-installer-test-' + [guid]::NewGuid().ToString('N'))
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $buildScript -OutputPath $output

$expectedVersion = (Get-Content -Raw -LiteralPath (Join-Path $root 'version.txt') -Encoding UTF8).Trim()
$setup = Join-Path $output ('DiskPulse-Setup-' + $expectedVersion + '.exe')
Assert-True (Test-Path -LiteralPath $setup) ('Expected installer was not created: ' + $setup)
$bytes = [IO.File]::ReadAllBytes($setup)
Assert-True ($bytes.Length -gt 2 -and $bytes[0] -eq 0x4D -and $bytes[1] -eq 0x5A) 'Installer is not a Windows executable.'
$setupVersionInfo = (Get-Item -LiteralPath $setup).VersionInfo
Assert-True ($setupVersionInfo.FileVersion -eq $expectedVersion) 'Setup FileVersion must match the canonical version.'
Assert-True ($setupVersionInfo.ProductVersion -eq $expectedVersion) 'Setup ProductVersion must match the canonical version.'
Assert-True ($installerSource -match [regex]::Escape('VIProductVersion "${VERSION4}"')) 'Installer must derive VIProductVersion from ${VERSION4}.'
Assert-True ($installerSource -match [regex]::Escape('DisplayVersion" "${VERSION}"')) 'Installer must derive DisplayVersion from ${VERSION}.'
Assert-True ($installerSource -match '\$\{EXE_PATH\}') 'Installer must use the generated launcher path.'
Assert-True ($installerSource -notmatch 'VIProductVersion\s+"[0-9]') 'Installer must not hardcode a numeric VIProductVersion.'

Write-Output 'PASS: NSIS installer build'
