[CmdletBinding()]
param(
    [string]$OutputPath = ''
)

$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))

if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path $root 'check.bat'
}

function Read-CanonicalSource {
    param([string]$RelativePath)
    $path = Join-Path $root $RelativePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Missing canonical source: $RelativePath"
    }
    return [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8)
}

function ConvertTo-CrLf {
    param([string]$Text)
    $Text = $Text.Replace("`r`n", "`n")
    return $Text.Replace("`n", "`r`n")
}

function Remove-TrailingNewline {
    param([string]$Text)
    return $Text.TrimEnd("`r", "`n")
}

$bootstrap    = Read-CanonicalSource 'src/bootstrap.bat'
$common       = Read-CanonicalSource 'src/powershell/Common.ps1'
$csharp       = Remove-TrailingNewline (Read-CanonicalSource 'src/scanner/DiskPulseFastScanner.cs')
$scannerPs    = Read-CanonicalSource 'src/powershell/Scanner.ps1'
$history      = Read-CanonicalSource 'src/powershell/History.ps1'
$persistence  = Read-CanonicalSource 'src/powershell/Persistence.ps1'
$progress     = Read-CanonicalSource 'src/powershell/Progress.ps1'
$ai           = Read-CanonicalSource 'src/powershell/AI.ps1'
$migration    = Read-CanonicalSource 'src/powershell/Migration.ps1'
$app          = Read-CanonicalSource 'src/powershell/App.ps1'

$scannerBlockLines = @(
    "if (-not ('DiskPulseFastScanner' -as [type])) {",
    "Add-Type -TypeDefinition @'",
    $csharp,
    "'@",
    'Profile-Mark "addType"',
    '}'
)
$scannerBlock = ($scannerBlockLines -join "`n") + "`n"

$template = Read-CanonicalSource 'src/dashboard/template.html'
$styles   = Remove-TrailingNewline (Read-CanonicalSource 'src/dashboard/styles.css')
$script   = Remove-TrailingNewline (Read-CanonicalSource 'src/dashboard/app.js')
$template = $template.Replace('__DISKPULSE_STYLE__', $styles)
$template = $template.Replace('__DISKPULSE_SCRIPT__', $script)
$dashboardBody = Remove-TrailingNewline $template
$app = $app.Replace('__DISKPULSE_DASHBOARD__', $dashboardBody)
if (-not $app.EndsWith("`n")) { $app += "`n" }

$header = "# GENERATED FILE - edit canonical source under src/ and run scripts/build-check.ps1`n`n"
$content = $bootstrap + $header + $common + $scannerBlock + $scannerPs + $history + $persistence + $progress + $ai + $migration + $app
$content = ConvertTo-CrLf $content

$directory = Split-Path -Parent $OutputPath
if (-not (Test-Path -LiteralPath $directory)) {
    [IO.Directory]::CreateDirectory($directory) | Out-Null
}

$temporaryPath = Join-Path $directory ('.check-build-' + [guid]::NewGuid().ToString('N') + '.tmp')
$backupPath = Join-Path $directory ('.check-backup-' + [guid]::NewGuid().ToString('N') + '.bak')
try {
    [IO.File]::WriteAllText($temporaryPath, $content, (New-Object Text.UTF8Encoding $false))
    if (Test-Path -LiteralPath $OutputPath -PathType Leaf) {
        try {
            [IO.File]::Replace($temporaryPath, $OutputPath, $backupPath, $true)
        }
        finally {
            if (Test-Path -LiteralPath $temporaryPath) { Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue }
            if (Test-Path -LiteralPath $backupPath) { Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue }
        }
    }
    else {
        try {
            [IO.File]::Move($temporaryPath, $OutputPath)
        }
        finally {
            if (Test-Path -LiteralPath $temporaryPath) { Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue }
        }
    }
}
finally {
    if (Test-Path -LiteralPath $temporaryPath) { Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue }
    if (Test-Path -LiteralPath $backupPath) { Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue }
}

Write-Output "Built: $OutputPath"
