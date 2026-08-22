param(
    [string]$OutputPath = (Join-Path $PSScriptRoot 'dist'),
    [string]$Version = ''
)

$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath($PSScriptRoot)

# Canonical version: the ONLY source is version.txt in the repository root.
if ([string]::IsNullOrWhiteSpace($Version)) {
    $versionFile = Join-Path $root 'version.txt'
    if (-not (Test-Path -LiteralPath $versionFile)) { throw "Canonical version file not found: $versionFile" }
    $Version = (Get-Content -Raw -LiteralPath $versionFile -Encoding UTF8).Trim()
}
$version4 = if ($Version.Split('.').Count -ge 4) { $Version } else { $Version + '.0' * (4 - $Version.Split('.').Count) }

# Inject version metadata into DiskPulse.exe via a temporary AssemblyInfo (not kept in the repo).
$assemblyInfoFile = Join-Path $env:TEMP ('DiskPulse-AssemblyInfo-' + [guid]::NewGuid().ToString('N') + '.cs')
$assemblyInfoLines = @(
    'using System.Reflection;'
    '[assembly: AssemblyTitle("DiskPulse")]'
    '[assembly: AssemblyProduct("DiskPulse")]'
    '[assembly: AssemblyDescription("DiskPulse Disk Dashboard")]'
    '[assembly: AssemblyCompany("DiskPulse")]'
    '[assembly: AssemblyCopyright("DiskPulse")]'
    ('[assembly: AssemblyVersion("{0}")]' -f $version4)
    ('[assembly: AssemblyFileVersion("{0}")]' -f $version4)
    ('[assembly: AssemblyInformationalVersion("{0}")]' -f $Version)
) -join [Environment]::NewLine
[IO.File]::WriteAllText($assemblyInfoFile, $assemblyInfoLines, (New-Object System.Text.UTF8Encoding $false))
$compiler = if ([Environment]::Is64BitOperatingSystem) {
    Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
} else {
    Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe'
}
$output = [IO.Path]::GetFullPath($OutputPath)
$resourceFile = Join-Path $env:TEMP ('DiskPulse-' + [guid]::NewGuid().ToString('N') + '.resources')
$payload = @('check.bat', 'DiskPulse.vbs', 'configure-ai.bat', 'assets\DiskPulse.png')
$iconPath = Join-Path $root 'assets\DiskPulse.ico'

if (-not (Test-Path -LiteralPath $compiler)) { throw "C# compiler not found: $compiler" }
foreach ($file in $payload) {
    if (-not (Test-Path -LiteralPath (Join-Path $root $file))) { throw "Payload file not found: $file" }
}
if (-not (Test-Path -LiteralPath $iconPath)) { throw "Icon file not found: $iconPath" }

New-Item -ItemType Directory -Path $output -Force | Out-Null
$writer = New-Object System.Resources.ResourceWriter($resourceFile)
try {
    foreach ($file in $payload) {
        $writer.AddResource($file, [IO.File]::ReadAllBytes((Join-Path $root $file)))
    }
} finally {
    $writer.Close()
}

$exe = Join-Path $output 'DiskPulse.exe'
$arguments = @(
    '/nologo', '/target:winexe', "/out:$exe",
    "/win32icon:$iconPath",
    "/resource:$resourceFile,DiskPulse.Payload",
    "/reference:System.dll", '/reference:System.Core.dll',
    '/reference:System.Drawing.dll', '/reference:System.Windows.Forms.dll',
    $assemblyInfoFile,
    (Join-Path $root 'launcher\DiskPulseLauncher.cs')
)
& $compiler @arguments
if ($LASTEXITCODE -ne 0) { throw "Launcher compilation failed with exit code $LASTEXITCODE." }
Remove-Item -LiteralPath $resourceFile -Force
if (Test-Path -LiteralPath $assemblyInfoFile) { Remove-Item -LiteralPath $assemblyInfoFile -Force }
Write-Output "Built: $exe"
