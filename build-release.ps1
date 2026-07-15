param(
    [string]$OutputPath = (Join-Path $PSScriptRoot 'dist')
)

$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath($PSScriptRoot)
$compiler = if ([Environment]::Is64BitOperatingSystem) {
    Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
} else {
    Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe'
}
$output = [IO.Path]::GetFullPath($OutputPath)
$resourceFile = Join-Path $env:TEMP ('DiskPulse-' + [guid]::NewGuid().ToString('N') + '.resources')
$payload = @('check.bat', 'DiskPulse.vbs', 'configure-ai.bat')

if (-not (Test-Path -LiteralPath $compiler)) { throw "C# compiler not found: $compiler" }
foreach ($file in $payload) {
    if (-not (Test-Path -LiteralPath (Join-Path $root $file))) { throw "Payload file not found: $file" }
}

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
    "/resource:$resourceFile,DiskPulse.Payload",
    "/reference:System.dll", '/reference:System.Core.dll',
    '/reference:System.Drawing.dll', '/reference:System.Windows.Forms.dll',
    (Join-Path $root 'launcher\DiskPulseLauncher.cs')
)
& $compiler @arguments
if ($LASTEXITCODE -ne 0) { throw "Launcher compilation failed with exit code $LASTEXITCODE." }
Remove-Item -LiteralPath $resourceFile -Force
Write-Output "Built: $exe"
