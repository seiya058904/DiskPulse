$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$projectRoot = Split-Path -Parent $PSScriptRoot
$appJs = Join-Path $projectRoot 'src\dashboard\app.js'
$template = Join-Path $projectRoot 'src\dashboard\template.html'

if (-not (Test-Path -LiteralPath $appJs -PathType Leaf)) { throw 'Canonical app.js is missing.' }
if (-not (Test-Path -LiteralPath $template -PathType Leaf)) { throw 'Canonical template.html is missing.' }

& node --check $appJs
if ($LASTEXITCODE -ne 0) { throw 'Canonical dashboard JavaScript failed node --check.' }

$js = Get-Content -Raw -LiteralPath $appJs -Encoding UTF8
if ($js -match 'innerHTML\s*=') { throw 'Canonical dashboard JavaScript must not assign innerHTML.' }

$html = Get-Content -Raw -LiteralPath $template -Encoding UTF8
foreach ($placeholder in @('__DISKPULSE_STYLE__', '__DISKPULSE_SCRIPT__', 'INJECT_BRAND_DATA_URI')) {
    if ($html -notmatch [regex]::Escape($placeholder)) { throw "Canonical template is missing placeholder: $placeholder" }
}
foreach ($placeholder in @('INJECT_DATA', 'INJECT_HISTORY', 'INJECT_DIRECTORY', 'INJECT_HISTORY_CENTER', 'INJECT_SCAN_META', 'INJECT_TS_JSON', 'INJECT_SYSTEM_DRIVE', 'INJECT_AI_ANALYSIS', 'INJECT_AI_COPY_TEXT')) {
    if ($js -notmatch [regex]::Escape($placeholder)) { throw "Canonical app.js is missing placeholder: $placeholder" }
}

$idMatches = [regex]::Matches($html, '\bid="([^"]+)"')
$ids = @($idMatches | ForEach-Object { $_.Groups[1].Value })
$duplicates = @($ids | Group-Object | Where-Object Count -gt 1 | Select-Object -ExpandProperty Name)
if ($duplicates.Count -gt 0) { throw "Duplicate dashboard IDs: $($duplicates -join ', ')" }

Write-Host 'PASS: canonical dashboard source syntax and static safety invariants.'

& node (Join-Path $PSScriptRoot 'volume-identity-dashboard.cjs')
if ($LASTEXITCODE -ne 0) { throw 'Volume identity dashboard regression failed.' }
