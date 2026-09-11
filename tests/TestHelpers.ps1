# Shared helpers for tests that exercise canonical source directly.
# This file is not a test file; it is dot-sourced by focused tests.

function New-DiskPulseCanonicalTestSource {
    param(
        [string[]]$Components = @('Common', 'Scanner', 'History', 'Progress')
    )

    $projectRoot = Split-Path -Parent $PSScriptRoot
    $sourceRoot = Join-Path $projectRoot 'src'
    $lines = New-Object 'System.Collections.Generic.List[string]'

    function Read-CanonicalTestSource {
        param([string]$RelativePath)
        $path = Join-Path $sourceRoot $RelativePath
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "Missing canonical source: $RelativePath"
        }
        return (Get-Content -Raw -LiteralPath $path -Encoding UTF8).TrimEnd("`r", "`n")
    }

    if ($Components -contains 'Common') {
        $lines.Add((Read-CanonicalTestSource 'powershell\Common.ps1'))
    }

    if ($Components -contains 'Scanner') {
        $lines.Add("if (-not ('DiskPulseFastScanner' -as [type])) {")
        $lines.Add("Add-Type -TypeDefinition @'")
        $lines.Add((Read-CanonicalTestSource 'scanner\DiskPulseFastScanner.cs'))
        $lines.Add("'@")
        $lines.Add('}')
        $lines.Add((Read-CanonicalTestSource 'powershell\Scanner.ps1'))
    }

    if ($Components -contains 'History') {
        $lines.Add((Read-CanonicalTestSource 'powershell\History.ps1'))
    }

    if ($Components -contains 'Progress') {
        $lines.Add((Read-CanonicalTestSource 'powershell\Progress.ps1'))
    }

    if ($Components -contains 'Persistence') {
        $lines.Add((Read-CanonicalTestSource 'powershell\Persistence.ps1'))
    }

    if ($Components -contains 'AI') {
        $lines.Add((Read-CanonicalTestSource 'powershell\AI.ps1'))
    }
    if ($Components -contains 'Migration') {
        $lines.Add((Read-CanonicalTestSource 'powershell\Migration.ps1'))
    }

    $tempPath = Join-Path $env:TEMP ('DiskPulse-CanonicalTest-' + [guid]::NewGuid().ToString('N') + '.ps1')
    [IO.File]::WriteAllText($tempPath, ($lines -join [Environment]::NewLine), (New-Object Text.UTF8Encoding $true))
    return $tempPath
}
