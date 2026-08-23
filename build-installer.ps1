param(
    [string]$OutputPath = (Join-Path $PSScriptRoot 'dist'),
    [string]$Version = '',
    [string]$NsisPath = ''
)

$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath($PSScriptRoot)
$output = [IO.Path]::GetFullPath($OutputPath)

# Canonical version: the ONLY source is version.txt in the repository root.
if ([string]::IsNullOrWhiteSpace($Version)) {
    $versionFile = Join-Path $root 'version.txt'
    if (-not (Test-Path -LiteralPath $versionFile)) { throw "Canonical version file not found: $versionFile" }
    $Version = (Get-Content -Raw -LiteralPath $versionFile -Encoding UTF8).Trim()
}
$version4 = if ($Version.Split('.').Count -ge 4) { $Version } else { $Version + '.0' * (4 - $Version.Split('.').Count) }
$nsisCandidates = New-Object System.Collections.Generic.List[object]
if (-not [string]::IsNullOrWhiteSpace($NsisPath)) {
    $nsisCandidates.Add([pscustomobject]@{ source = 'explicit -NsisPath'; path = $NsisPath })
}
if (-not [string]::IsNullOrWhiteSpace($env:DISKPULSE_NSIS_PATH)) {
    $nsisCandidates.Add([pscustomobject]@{ source = 'DISKPULSE_NSIS_PATH'; path = $env:DISKPULSE_NSIS_PATH })
}
$command = Get-Command makensis.exe -ErrorAction SilentlyContinue
if ($command -and $command.Path) {
    $nsisCandidates.Add([pscustomobject]@{ source = 'Get-Command makensis.exe'; path = $command.Path })
}
$nsisCandidates.Add([pscustomobject]@{ source = 'local developer fallback'; path = 'D:\xia zai\NSIS\makensis.exe' })

$makensis = $null
$attempted = New-Object System.Collections.Generic.List[string]
foreach ($candidate in $nsisCandidates) {
    $attempted.Add(($candidate.source + ': ' + $candidate.path))
    if (Test-Path -LiteralPath $candidate.path -PathType Leaf) {
        $makensis = [IO.Path]::GetFullPath($candidate.path)
        break
    }
}
if ([string]::IsNullOrWhiteSpace($makensis)) {
    throw ('NSIS compiler not found. Tried:' + [Environment]::NewLine + ' - ' + ($attempted -join ([Environment]::NewLine + ' - ')))
}
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'build-release.ps1') -OutputPath $output -Version $Version
if ($LASTEXITCODE -ne 0) { throw 'Main EXE build failed.' }
New-Item -ItemType Directory -Path $output -Force | Out-Null
& $makensis "/DPROJECT_ROOT=$root" "/DOUTPUT_PATH=$output" "/DVERSION=$Version" "/DVERSION4=$version4" (Join-Path $root 'installer\DiskPulse.nsi')
if ($LASTEXITCODE -ne 0) { throw "NSIS build failed with exit code $LASTEXITCODE." }
Write-Output "Built: $(Join-Path $output ("DiskPulse-Setup-" + $Version + ".exe"))"
