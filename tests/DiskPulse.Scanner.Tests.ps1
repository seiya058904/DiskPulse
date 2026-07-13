$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$projectRoot = Split-Path -Parent $PSScriptRoot
$source = Get-Content -Raw -LiteralPath (Join-Path $projectRoot 'check.bat') -Encoding UTF8
$env:DISKPULSE_TEST_MODE = '1'
$env:DISKPULSE_ROOT = $projectRoot
$env:DISKPULSE_SCRIPT_PATH = Join-Path $projectRoot 'check.bat'
Invoke-Expression $source.Substring($source.IndexOf('#>') + 2)

if (-not (Get-Command Invoke-DirectoryScan -ErrorAction SilentlyContinue)) {
    throw 'Invoke-DirectoryScan is missing.'
}

$temp = Join-Path ([IO.Path]::GetTempPath()) ('DiskPulse-Scanner-' + [guid]::NewGuid().ToString('N'))
$alpha = Join-Path $temp 'Alpha'
$a1 = Join-Path $alpha 'A1'
$unicodeName = ([string][char]0x6D4B) + [char]0x8BD5
$childName = ([string][char]0x5B50) + [char]0x76EE + [char]0x5F55
$unicode = Join-Path $temp $unicodeName
$u1 = Join-Path $unicode $childName
$empty = Join-Path $temp 'Empty'
$junction = Join-Path $temp 'AlphaLink'
$locked = Join-Path $temp 'Locked'
@($temp, $alpha, $a1, $unicode, $u1, $empty, $locked) | ForEach-Object { [IO.Directory]::CreateDirectory($_) | Out-Null }

try {
    [IO.File]::WriteAllBytes((Join-Path $temp 'root.bin'), ([byte[]](1..10)))
    [IO.File]::WriteAllBytes((Join-Path $alpha 'alpha.bin'), ([byte[]](1..20)))
    [IO.File]::WriteAllBytes((Join-Path $a1 'one.bin'), ([byte[]](1..30)))
    [IO.File]::WriteAllBytes((Join-Path $u1 'two.bin'), ([byte[]](1..40)))
    [IO.File]::WriteAllBytes((Join-Path $locked 'locked.bin'), ([byte[]](1..5)))
    cmd /c "mklink /J `"$junction`" `"$alpha`"" | Out-Null
    if (-not (Test-Path -LiteralPath $junction)) { throw "Test fixture could not create a junction." }

    $scan = Invoke-DirectoryScan -Drive "T:" -RootPath $temp
    if ($scan.status -ne 'complete') { throw "Fixture scan must complete, got $($scan.status)." }
    $records = @($scan.records)
    $root = $records | Where-Object kind -eq "rootFiles"
    $alphaRecord = $records | Where-Object { $_.level -eq 1 -and $_.displayPath -eq $alpha }
    $a1Record = $records | Where-Object { $_.level -eq 2 -and $_.displayPath -eq $a1 }
    $unicodeRecord = $records | Where-Object { $_.level -eq 1 -and $_.displayPath -eq $unicode }
    $emptyRecord = $records | Where-Object { $_.level -eq 1 -and $_.displayPath -eq $empty }

    if ($root.sizeBytes -ne 10 -or $root.fileCount -ne 1) { throw "Root-file aggregate is incorrect." }
    if ($alphaRecord.sizeBytes -ne 50 -or $alphaRecord.fileCount -ne 2) { throw "Level-one aggregate is incorrect." }
    if ($a1Record.sizeBytes -ne 30 -or $a1Record.fileCount -ne 1) { throw "Level-two aggregate is incorrect." }
    if ($unicodeRecord.sizeBytes -ne 40 -or $emptyRecord.sizeBytes -ne 0) { throw "Unicode or empty-directory aggregation is incorrect." }
    if (-not (@($scan.excluded | Where-Object path -eq $junction).Count)) { throw "Reparse points must be excluded." }
    $alphaWithSeparator = $alpha.ToUpperInvariant() + [IO.Path]::DirectorySeparatorChar
    if ((Normalize-PathKey $alphaWithSeparator) -ne (Normalize-PathKey $alpha)) { throw "Normalized keys must ignore case and trailing separators." }

    $missing = Invoke-DirectoryScan -Drive "T:" -RootPath (Join-Path $temp "missing")
    if ($missing.status -ne "failed" -or @($missing.errors).Count -ne 1) { throw "Missing root must return failed with one error." }

    $denyResult = & icacls.exe $locked /inheritance:r /deny "$($env:USERNAME):(OI)(CI)F" 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Test fixture could not apply a temporary deny ACL: $denyResult" }
    $partial = Invoke-DirectoryScan -Drive "T:" -RootPath $temp
    if ($partial.status -ne "partial" -or -not @($partial.unavailable).Count) { throw "A child permission failure must return partial with unavailable evidence." }
    & icacls.exe $locked /remove:d $env:USERNAME /inheritance:e | Out-Null

    $vanishing = Join-Path $temp 'vanishing.bin'
    [IO.File]::WriteAllBytes($vanishing, ([byte[]](1..6)))
    $vanishScan = Invoke-DirectoryScan -Drive "T:" -RootPath $temp -BeforeEntry {
        param($entry)
        if ($entry.FullName -eq $vanishing -and (Test-Path -LiteralPath $vanishing)) { Remove-Item -LiteralPath $vanishing -Force }
    }
    if ($vanishScan.status -ne "partial" -or -not @($vanishScan.errors | Where-Object kind -eq "entry-disappeared").Count) {
        throw "A disappearing file must be recorded without terminating the scan."
    }

    [pscustomobject]@{
        level1 = @($records | Where-Object level -eq 1).Count
        level2 = @($records | Where-Object level -eq 2).Count
        rootFiles = $root.fileCount
        excluded = @($scan.excluded).Count
        unavailable = @($scan.unavailable).Count
        errors = @($scan.errors).Count
        permissionUnavailable = @($partial.unavailable).Count
        permissionErrors = @($partial.errors).Count
        disappearingErrors = @($vanishScan.errors | Where-Object kind -eq "entry-disappeared").Count
    } | ConvertTo-Json -Compress | Write-Host
}
finally {
    if (Test-Path -LiteralPath $locked) { & icacls.exe $locked /remove:d $env:USERNAME /inheritance:e | Out-Null }
    $fixtureFiles = @(
        (Join-Path $u1 "two.bin")
        (Join-Path $a1 "one.bin")
        (Join-Path $alpha "alpha.bin")
        (Join-Path $temp "root.bin")
        (Join-Path $locked "locked.bin")
        (Join-Path $temp "vanishing.bin")
    )
    foreach ($file in $fixtureFiles) {
        if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file -Force }
    }
    if (Test-Path -LiteralPath $junction) { [IO.Directory]::Delete($junction) }
    foreach ($directory in @($u1, $unicode, $a1, $alpha, $empty, $locked, $temp)) {
        if (Test-Path -LiteralPath $directory) { [IO.Directory]::Delete($directory) }
    }
}

Write-Host "PASS: real directory scanner aggregation and root failure behavior."
