$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$projectRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'TestHelpers.ps1')
$canonicalTestSource = New-DiskPulseCanonicalTestSource -Components @('Common', 'AI')
try {
    . $canonicalTestSource
}
finally {
    if (Test-Path -LiteralPath $canonicalTestSource) { Remove-Item -LiteralPath $canonicalTestSource -Force }
}

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

# --- Endpoint validation ---
Assert-True (Test-DiskPulseAIEndpoint 'https://api.example.com/v1/chat/completions') 'Remote HTTPS endpoint must be allowed.'
Assert-True (Test-DiskPulseAIEndpoint 'http://localhost:1234/v1') 'Localhost HTTP endpoint must be allowed.'
Assert-True (Test-DiskPulseAIEndpoint 'http://127.0.0.1:1234/v1') 'Loopback HTTP endpoint must be allowed.'
Assert-True (Test-DiskPulseAIEndpoint 'http://[::1]:1234/v1') 'IPv6 loopback HTTP endpoint must be allowed.'
Assert-True (-not (Test-DiskPulseAIEndpoint 'http://api.example.com/v1')) 'Remote plaintext HTTP must be rejected.'
Assert-True (-not (Test-DiskPulseAIEndpoint 'ftp://example.com/v1')) 'Non-HTTP scheme must be rejected.'
Assert-True (-not (Test-DiskPulseAIEndpoint 'https://user:pass@api.example.com/v1')) 'Endpoint userinfo must be rejected.'
Assert-True (-not (Test-DiskPulseAIEndpoint 'http://user:pass@localhost:1234/v1')) 'Local endpoint userinfo must be rejected.'
Assert-True (-not (Test-DiskPulseAIEndpoint "https://api.example.com/`nX")) 'Control characters in endpoints must be rejected.'

# --- DPAPI / credential behavior ---
$fakeKey = 'DISKPULSE_TEST_SECRET_DO_NOT_PERSIST_12345'
$protected = Protect-DiskPulseSecret $fakeKey
Assert-True ($protected -and $protected -ne $fakeKey -and -not $protected.Contains($fakeKey)) 'Protected key must not contain plaintext.'
Assert-True ((Unprotect-DiskPulseSecret $protected) -eq $fakeKey) 'DPAPI round trip must return the original key.'
Assert-True ($null -eq (Unprotect-DiskPulseSecret 'not-valid-base64!!!')) 'Corrupt protected key must fail safely.'
Assert-True ($null -eq (Unprotect-DiskPulseSecret '')) 'Empty protected key must fail safely.'

# --- Safe JSON / HTML injection ---
$hostile = '</script><script>alert(1)</script><img src=x onerror=alert(2)>' + [string][char]0x2028 + [string][char]0x2029
$safeJson = ConvertTo-DiskPulseSafeJSON ([pscustomobject]@{ text = $hostile })
Assert-True ($safeJson -notmatch '</script>') 'Safe JSON must escape HTML closing script tags.'
Assert-True ($safeJson -notmatch [string][char]0x2028 -and $safeJson -notmatch [string][char]0x2029) 'Safe JSON must escape U+2028/U+2029.'

# --- Response validation ---
$validEnvelope = [pscustomobject]@{
    choices = @([pscustomobject]@{ message = [pscustomobject]@{ content = '{"summary":"ok","confidence":"medium","possibleCauses":[],"evidence":[],"recommendations":[],"cautions":[]}' } })
}
$valid = ConvertFrom-DiskPulseAIResponseEnvelope $validEnvelope
Assert-True ($valid.status -eq 'success' -and $valid.format -eq 'structured') 'Valid structured response must parse.'

$invalidEnvelope = [pscustomobject]@{ choices = @([pscustomobject]@{ message = [pscustomobject]@{ content = '<html>error</html>' } }) }
$invalid = ConvertFrom-DiskPulseAIResponseEnvelope $invalidEnvelope
Assert-True ($invalid.status -eq 'success' -and $invalid.format -eq 'text') 'Non-JSON provider output must fall back to plain text safely.'

$emptyEnvelope = [pscustomobject]@{ choices = @([pscustomobject]@{ message = [pscustomobject]@{ content = '' } }) }
$empty = ConvertFrom-DiskPulseAIResponseEnvelope $emptyEnvelope
Assert-True ($empty.status -eq 'invalid-response') 'Empty provider content must be invalid.'

# --- Atomic AI result publication ---
$aiTempRoot = Join-Path ([IO.Path]::GetTempPath()) ('DiskPulse-AI-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $aiTempRoot -Force | Out-Null
try {
    $aiResultPath = Join-Path $aiTempRoot 'last-ai-analysis.json'
    [IO.File]::WriteAllText($aiResultPath, '{"old":true}', (New-Object Text.UTF8Encoding $false))
    Write-DiskPulseAIResult -ScanId 's1' -Status 'success' -Model 'm' -Format 'structured' -Analysis ([pscustomobject]@{ summary = 'new' }) -RawText $null -OutputPath $aiResultPath
    $aiResult = Get-Content -Raw -LiteralPath $aiResultPath -Encoding UTF8 | ConvertFrom-Json
    Assert-True ($aiResult.status -eq 'success') 'Atomic AI result write must publish the new result.'
    Assert-True (@(Get-ChildItem -LiteralPath $aiTempRoot -Filter '*.tmp' -File).Count -eq 0) 'AI result write must not leave temp files.'
}
finally {
    if (Test-Path -LiteralPath $aiTempRoot) { Remove-Item -LiteralPath $aiTempRoot -Recurse -Force -ErrorAction SilentlyContinue }
}

# --- Stale HTML update protection ---
$htmlRoot = Join-Path ([IO.Path]::GetTempPath()) ('DiskPulse-AI-Html-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $htmlRoot -Force | Out-Null
try {
    $htmlPath = Join-Path $htmlRoot 'DiskPulse.html'
    $htmlContent = @'
<!DOCTYPE html><html><head></head><body>
<script>
const RAW_SCAN_META = {"scanId":"scan-new"};
/* DISKPULSE_AI_RESULT_START */
const RAW_AI_ANALYSIS = {};
/* DISKPULSE_AI_RESULT_END */
</script>
</body></html>
'@
    [IO.File]::WriteAllText($htmlPath, $htmlContent, (New-Object Text.UTF8Encoding $false))
    $staleUpdate = Update-DiskPulseAIHtmlResult -HtmlPath $htmlPath -ExpectedScanId 'scan-old' -AnalysisResult ([pscustomobject]@{ status = 'success' })
    Assert-True (-not $staleUpdate) 'Stale AI result must not update a newer dashboard.'
}
finally {
    if (Test-Path -LiteralPath $htmlRoot) { Remove-Item -LiteralPath $htmlRoot -Recurse -Force -ErrorAction SilentlyContinue }
}

# --- Offline / no-AI behavior ---
$offlineRoot = Join-Path ([IO.Path]::GetTempPath()) ('DiskPulse-AI-Offline-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $offlineRoot -Force | Out-Null
try {
    $offlineResultPath = Join-Path $offlineRoot 'last-ai-analysis.json'
    $offlineStatus = Invoke-DiskPulseAIAnalysis -ScanId 'offline' -DirectoryResults @() -HistoryCenter @() -Snapshot ([pscustomobject]@{ status = 'complete' }) -OutputPath $offlineResultPath -ConfigPath (Join-Path $offlineRoot 'missing-config.json')
    Assert-True ($offlineStatus.status -eq 'not-configured') 'No AI configuration must produce a non-fatal not-configured status.'
    Assert-True (Test-Path -LiteralPath $offlineResultPath) 'No-AI result should still be persisted as a non-fatal status.'
}
finally {
    if (Test-Path -LiteralPath $offlineRoot) { Remove-Item -LiteralPath $offlineRoot -Recurse -Force -ErrorAction SilentlyContinue }
}


# --- Redirect / Authorization forwarding behavior ---
function Get-FreeLoopbackPort {
    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    $listener.Start()
    $port = $listener.LocalEndpoint.Port
    $listener.Stop()
    return $port
}
$redirectPort1 = Get-FreeLoopbackPort
$redirectPort2 = Get-FreeLoopbackPort
$redirectCounter = Join-Path $env:TEMP ('DiskPulse-redirect-hit-' + [guid]::NewGuid().ToString('N') + '.txt')
$redirectJob1 = Start-Job -ArgumentList $redirectPort1, $redirectPort2 -ScriptBlock {
    param($p1, $p2)
    $listener = [Net.HttpListener]::new()
    $listener.Prefixes.Add("http://127.0.0.1:$p1/")
    $listener.Start()
    $context = $listener.GetContext()
    $context.Response.StatusCode = 302
    $context.Response.RedirectLocation = "http://127.0.0.1:$p2/target"
    $context.Response.Close()
    $listener.Stop()
}
$redirectJob2 = Start-Job -ArgumentList $redirectPort2, $redirectCounter -ScriptBlock {
    param($p2, $counter)
    $listener = [Net.HttpListener]::new()
    $listener.Prefixes.Add("http://127.0.0.1:$p2/")
    $listener.Start()
    $context = $listener.GetContext()
    [IO.File]::WriteAllText($counter, 'hit')
    $context.Response.StatusCode = 200
    $context.Response.Close()
    $listener.Stop()
}
try {
    Start-Sleep -Milliseconds 500
    $redirectKey = Protect-DiskPulseSecret 'DISKPULSE_TEST_SECRET_REDIRECT'
    $redirectConfig = [pscustomobject]@{
        endpoint = "http://127.0.0.1:$redirectPort1/v1"
        model = 'm'
        protectedApiKey = $redirectKey
        timeoutSeconds = 5
        temperature = [double]::NaN
    }
    $redirectResult = Invoke-DiskPulseAIRequest -Config $redirectConfig -Prompt ([pscustomobject]@{ system = 's'; user = 'u' })
    Assert-True ($redirectResult.ok -eq $false -and $redirectResult.error -eq 'redirect-rejected') 'AI redirects must be rejected.'
    Start-Sleep -Milliseconds 500
    Assert-True (-not (Test-Path -LiteralPath $redirectCounter)) 'Redirect target must not receive the original Authorization-bearing request.'
}
finally {
    Stop-Job $redirectJob1, $redirectJob2 -ErrorAction SilentlyContinue
    Remove-Job $redirectJob1, $redirectJob2 -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $redirectCounter) { Remove-Item -LiteralPath $redirectCounter -Force -ErrorAction SilentlyContinue }
}


# --- HTTP 5xx handling ---
$fiveCfg = [pscustomobject]@{
    endpoint = 'https://api.example.com/v1/chat/completions'
    model = 'm'
    protectedApiKey = (Protect-DiskPulseSecret 'DISKPULSE_TEST_SECRET_5XX')
    timeoutSeconds = 5
    temperature = [double]::NaN
}
foreach ($status in @('500', '503')) {
    $fiveResult = Invoke-DiskPulseAIRequest -Config $fiveCfg -Prompt ([pscustomobject]@{ system = 's'; user = 'u' }) -Transport {
        param($u, $h, $b, $t)
        throw (New-Object System.Net.WebException($status))
    }
    Assert-True ($fiveResult.ok -eq $false -and -not [string]::IsNullOrWhiteSpace($fiveResult.error)) "HTTP $status must fail safely."
}

Write-Host 'PASS: focused AI security/correctness tests via canonical source.'
