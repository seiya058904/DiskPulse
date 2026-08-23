param(
    [string]$TestsPath = (Join-Path $PSScriptRoot '.')
)

$ErrorActionPreference = 'Continue'
$testFiles = @(Get-ChildItem -LiteralPath $TestsPath -Filter '*.Tests.ps1' -File | Sort-Object Name)
if ($testFiles.Count -eq 0) {
    Write-Error "No test files matching tests\*.Tests.ps1 were found in $TestsPath."
    exit 1
}

$failures = New-Object System.Collections.Generic.List[string]
foreach ($test in $testFiles) {
    Write-Host ("=== {0} ===" -f $test.Name) -ForegroundColor Cyan
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $test.FullName
    if ($LASTEXITCODE -ne 0) {
        $failures.Add($test.Name)
        Write-Host ("FAIL: {0} (exit code {1})" -f $test.Name, $LASTEXITCODE) -ForegroundColor Red
    } else {
        Write-Host ("PASS: {0}" -f $test.Name) -ForegroundColor Green
    }
}

if ($failures.Count -gt 0) {
    Write-Error ("DiskPulse test suite failed: {0}" -f ($failures -join ', '))
    exit 1
}

Write-Host ("DiskPulse test suite passed: {0} test files." -f $testFiles.Count) -ForegroundColor Green
exit 0
