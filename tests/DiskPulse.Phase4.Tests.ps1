$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot;$source=Get-Content -Raw -LiteralPath (Join-Path $root 'check.bat') -Encoding UTF8
$stable=@('class="overview"','class="insights"','class="grid"','sparkline','estimateDays','id="search"','id="sort"','id="compact"','id="copy"','data-theme','@media')
$phase4=@('INJECT_DIRECTORY','directory-overview','change-summary','growth-list','release-list','change-drive-filter','change-level-filter','change-direction-filter','copy-path','scan-details','baseline-guide','completeness-warning','directoryTopThree','directoryCoverage','Array.isArray(RAW_DIRECTORY)')
foreach($marker in @($stable+$phase4)){if($source-notmatch[regex]::Escape($marker)){throw "Missing dashboard marker: $marker"}}
if($source-notmatch [regex]::Escape('$directoryJson = ConvertTo-JsonArray ([object[]]$directoryResults)')){throw 'Directory result serialization must materialize the generic list as object[].'}
foreach($marker in 'isReliableChange','reliableChanges','statusLabel','coverageLabel','single-sided','growth-value','release-value','focus-visible','prefers-reduced-motion'){if($source-notmatch[regex]::Escape($marker)){throw "Missing Apple redesign behavior: $marker"}}
foreach($marker in 'badge-copy-v2','trust-summary'){if($source-notmatch[regex]::Escape($marker)){throw "Missing final semantic copy: $marker"}}
$readme=Get-Content -Raw -LiteralPath (Join-Path $root 'README.md') -Encoding UTF8
foreach($forbidden in 'SMART','性能衰退','健康指标','实时监控'){if($readme-match[regex]::Escape($forbidden)){throw "README contains unverified claim: $forbidden"}}
Write-Host 'PASS: stable dashboard and Phase 4 integration markers.'
