[CmdletBinding()]
param(
    [switch]$IncludeInstaller,
    [switch]$SkipInstaller,
    [switch]$SkipPowerShell7,
    [switch]$SkipBuild
)

$ErrorActionPreference = 'Stop'
$script:Failed = $false
$script:Results = New-Object System.Collections.Generic.List[object]
$script:Root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))

function Add-CheckResult {
    param(
        [string]$Stage,
        [string]$Status,
        [string]$Detail = ''
    )

    $script:Results.Add([pscustomobject]@{
        Stage  = $Stage
        Status = $Status
        Detail = $Detail
    })

    if ($Status -eq 'FAIL') {
        $script:Failed = $true
    }

    $color = switch ($Status) {
        'PASS' { 'Green' }
        'SKIP' { 'Yellow' }
        'FAIL' { 'Red' }
        default { 'Gray' }
    }
    $line = "$Status $Stage"
    if ($Detail) {
        $line += " - $Detail"
    }
    Write-Host $line -ForegroundColor $color
}

function Get-DiskPulseNsisPath {
    if (-not [string]::IsNullOrWhiteSpace($env:DISKPULSE_NSIS_PATH)) {
        $candidate = $env:DISKPULSE_NSIS_PATH.Trim()
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return [IO.Path]::GetFullPath($candidate)
        }
    }

    $command = Get-Command makensis.exe -ErrorAction SilentlyContinue
    if ($command -and $command.Path -and (Test-Path -LiteralPath $command.Path -PathType Leaf)) {
        return $command.Path
    }

    $standardPaths = @(
        (Join-Path ${env:ProgramFiles(x86)} 'NSIS\makensis.exe'),
        (Join-Path $env:ProgramFiles 'NSIS\makensis.exe'),
        (Join-Path $env:LOCALAPPDATA 'NSIS\makensis.exe')
    )
    foreach ($candidatePath in $standardPaths) {
        if (Test-Path -LiteralPath $candidatePath -PathType Leaf) {
            return $candidatePath
        }
    }

    return $null
}

function Invoke-GitDiffCheck {
    Write-Host ''
    Write-Host '=== Repository checks ==='
    Push-Location $script:Root
    try {
        & git diff --check
        if ($LASTEXITCODE -ne 0) {
            Add-CheckResult 'git diff --check' 'FAIL' 'git reported whitespace errors'
        } else {
            Add-CheckResult 'git diff --check' 'PASS'
        }
    }
    finally {
        Pop-Location
    }
}

function Invoke-RequiredSourceFileChecks {
    $required = @(
        'check.bat'
        'DiskPulse.vbs'
        'check-profile.bat'
        'configure-ai.bat'
        'build-release.ps1'
        'build-installer.ps1'
        'scripts/build-check.ps1'
        'launcher\DiskPulseLauncher.cs'
        'installer\DiskPulse.nsi'
        'tests\Invoke-DiskPulseTestSuite.ps1'
        'version.txt'
    )

    $missing = @($required | Where-Object {
        -not (Test-Path -LiteralPath (Join-Path $script:Root $_))
    })

    if ($missing.Count -gt 0) {
        Add-CheckResult 'required source files' 'FAIL' ('Missing: ' + ($missing -join ', '))
    } else {
        Add-CheckResult 'required source files' 'PASS'
    }
}

function Invoke-VersionFormatCheck {
    $versionFile = Join-Path $script:Root 'version.txt'
    $version = (Get-Content -Raw -LiteralPath $versionFile -Encoding UTF8).Trim()
    if ($version -notmatch '^\d+\.\d+\.\d+$') {
        Add-CheckResult 'version.txt format' 'FAIL' "Invalid version '$version'; expected x.y.z"
    } else {
        Add-CheckResult 'version.txt format' 'PASS' "version=$version"
    }
}

function Invoke-AsciiOnlyCheck {
    foreach ($relativePath in @('DiskPulse.vbs', 'configure-ai.bat')) {
        $fullPath = Join-Path $script:Root $relativePath
        $bytes = [IO.File]::ReadAllBytes($fullPath)
        $nonAsciiCount = @($bytes | Where-Object { $_ -gt 127 }).Count
        if ($nonAsciiCount -gt 0) {
            Add-CheckResult 'ASCII-only launcher/config' 'FAIL' "$relativePath contains $nonAsciiCount non-ASCII byte(s)"
        } else {
            Add-CheckResult 'ASCII-only launcher/config' 'PASS' "$relativePath is ASCII-only"
        }
    }
}

function Invoke-TrackedArtifactCheck {
    Push-Location $script:Root
    try {
        $tracked = @(& git ls-files)
        $forbidden = @($tracked | Where-Object {
            $_ -match '(^|/)runtime/' -or $_ -match '(^|/)dist/' -or $_ -match '\.local\.json$'
        })
        if ($forbidden.Count -gt 0) {
            Add-CheckResult 'no runtime/dist/local.json tracked' 'FAIL' ('Forbidden tracked paths: ' + ($forbidden -join ', '))
        } else {
            Add-CheckResult 'no runtime/dist/local.json tracked' 'PASS'
        }
    }
    finally {
        Pop-Location
    }
}

function Invoke-WindowsPowerShellSuite {
    Write-Host ''
    Write-Host '=== Windows PowerShell tests ==='
    $suite = Join-Path $script:Root 'tests\Invoke-DiskPulseTestSuite.ps1'
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $suite
    if ($LASTEXITCODE -ne 0) {
        Add-CheckResult 'Windows PowerShell test suite' 'FAIL' "exit code $LASTEXITCODE"
    } else {
        Add-CheckResult 'Windows PowerShell test suite' 'PASS'
    }
}

function Invoke-PowerShell7Compatibility {
    Write-Host ''
    Write-Host '=== PowerShell 7 compatibility ==='
    if ($SkipPowerShell7) {
        Add-CheckResult 'PowerShell 7 compatibility' 'SKIP' 'disabled by -SkipPowerShell7'
        return
    }

    $pwsh = Get-Command pwsh -ErrorAction SilentlyContinue
    if (-not $pwsh) {
        Add-CheckResult 'PowerShell 7 compatibility' 'SKIP' 'pwsh not found on PATH'
        return
    }

    $testFiles = @(
        'tests\DiskPulse.Phase3.Tests.ps1'
        'tests\DiskPulse.Phase4.Tests.ps1'
        'tests\DiskPulse.VolumeIdentity.Tests.ps1'
    )
    $anyFailure = $false
    foreach ($relativePath in $testFiles) {
        $testPath = Join-Path $script:Root $relativePath
        & $pwsh.Source -NoProfile -File $testPath
        if ($LASTEXITCODE -ne 0) {
            $anyFailure = $true
            Add-CheckResult 'PowerShell 7 compatibility' 'FAIL' "$relativePath exit code $LASTEXITCODE"
        }
    }
    if (-not $anyFailure) {
        Add-CheckResult 'PowerShell 7 compatibility' 'PASS'
    }
}

function Invoke-BuildStages {
    Write-Host ''
    Write-Host '=== Build stages ==='
    if ($SkipBuild) {
        Add-CheckResult 'Launcher build' 'SKIP' 'disabled by -SkipBuild'
        Add-CheckResult 'Installer build' 'SKIP' 'disabled by -SkipBuild'
        return
    }

    if ($IncludeInstaller -and $SkipInstaller) {
        throw '-IncludeInstaller and -SkipInstaller cannot be used together.'
    }

    $nsisPath = Get-DiskPulseNsisPath

    if ($IncludeInstaller -and -not $nsisPath) {
        Add-CheckResult 'Launcher build' 'PASS' 'verified by Windows PowerShell suite'
        Add-CheckResult 'Installer build' 'FAIL' 'required by -IncludeInstaller but NSIS was not found'
        return
    }

    Add-CheckResult 'Launcher build' 'PASS' 'verified by Windows PowerShell suite'

    if ($SkipInstaller) {
        Add-CheckResult 'Installer build' 'SKIP' 'disabled by -SkipInstaller'
    } elseif ($nsisPath) {
        Add-CheckResult 'Installer build' 'PASS' 'verified by Windows PowerShell suite'
    } else {
        Add-CheckResult 'Installer build' 'SKIP' 'NSIS not found; use -IncludeInstaller to require it'
    }
}

Invoke-GitDiffCheck
Invoke-RequiredSourceFileChecks
Invoke-VersionFormatCheck
Invoke-AsciiOnlyCheck
Invoke-TrackedArtifactCheck
Invoke-WindowsPowerShellSuite
Invoke-PowerShell7Compatibility
Invoke-BuildStages

Write-Host ''
Write-Host '=== Summary ==='
$passCount = @($script:Results | Where-Object Status -eq 'PASS').Count
$skipCount = @($script:Results | Where-Object Status -eq 'SKIP').Count
$failCount = @($script:Results | Where-Object Status -eq 'FAIL').Count
Write-Host "Passed: $passCount, Skipped: $skipCount, Failed: $failCount"

if ($script:Failed) {
    Write-Host 'Verification failed.' -ForegroundColor Red
    exit 1
}

Write-Host 'Verification passed.' -ForegroundColor Green
exit 0
