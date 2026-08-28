param(
    [string]$HtmlPath,
    [string]$OutputDir = (Join-Path $env:TEMP 'DiskPulse-BrowserQA')
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($HtmlPath)) {
    throw 'HtmlPath is required. Pass a generated DiskPulse.html file.'
}
if (-not (Test-Path -LiteralPath $HtmlPath -PathType Leaf)) {
    throw "Generated HTML not found: $HtmlPath"
}

$nodeScript = Join-Path $PSScriptRoot 'run-browser-qa.js'
& node $nodeScript $HtmlPath $OutputDir
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}
Write-Output "Browser QA complete. Screenshots: $OutputDir"
