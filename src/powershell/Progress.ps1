# Lightweight scan-progress bridge for the packaged launcher.
# Publishes a flat, ASCII-safe state file (scan-progress.json) through the same atomic
# write path as every other published artifact. Contents are limited to scan status,
# coarse stage, drive letter, approximate percent and counters - never file paths,
# file contents or configuration. Readers must treat a stale updatedAt as unknown.
function New-DiskPulseProgressState {
    @{ Watch = [Diagnostics.Stopwatch]::StartNew(); LastPublishMilliseconds = -10000 }
}

function Get-DiskPulseScanOverallPercent {
    param($Progress, [int] $CompletedDrives, [int] $TotalDrives)
    if ($Progress -and [double]$Progress.percentComplete -ge 0 -and $TotalDrives -gt 0) {
        $driveFraction = [double]$Progress.percentComplete / 100
        return [math]::Max(0, [math]::Min(100, (($CompletedDrives + $driveFraction) / $TotalDrives) * 100))
    }
    if (-not $Progress -and $TotalDrives -gt 0 -and $CompletedDrives -ge $TotalDrives) { return 100 }
    return -1
}

function Write-DiskPulseScanProgress {
    param(
        $Paths,
        [string] $ScanId,
        [ValidateSet('running','complete','failed')] [string] $Status,
        [string] $Stage = '',
        [string] $Drive = '',
        $Progress = $null,
        [int] $CompletedDrives = 0,
        [int] $TotalDrives = 0,
        [long] $ElapsedMilliseconds = 0,
        $State = $null,
        [switch] $Force
    )
    # The progress bridge must never break a scan: any failure (locked file, disk hiccup,
    # unexpected state) is swallowed and the scan continues without live progress.
    try {
        if (-not $Paths -or -not ($Paths.PSObject.Properties.Name -contains 'Runtime')) { return }
        if ([string]::IsNullOrWhiteSpace($ScanId) -or -not (Test-DiskPulseAIScanId $ScanId)) { return }
        $runtime = [string]$Paths.Runtime
        if ([string]::IsNullOrWhiteSpace($runtime)) { return }
        if ($State -is [System.Collections.Hashtable] -and -not $Force) {
            $last = 0
            if ($State.Contains('LastPublishMilliseconds')) { $last = [int64]$State.LastPublishMilliseconds }
            if (($State.Watch.ElapsedMilliseconds - $last) -lt 800) { return }
            $State.LastPublishMilliseconds = $State.Watch.ElapsedMilliseconds
        }
        $percent = Get-DiskPulseScanOverallPercent -Progress $Progress -CompletedDrives $CompletedDrives -TotalDrives $TotalDrives
        $files = if ($Progress) { [int64]$Progress.filesProcessed } else { 0 }
        $directories = if ($Progress) { [int64]$Progress.directoriesProcessed } else { 0 }
        $now = (Get-Date).ToUniversalTime().ToString('o')
        $record = [PSCustomObject]@{
            scanId                = $ScanId
            status                = $Status
            stage                 = [string]$Stage
            drive                 = [string]$Drive
            percent               = [math]::Round($percent, 1)
            percentKnown          = ($percent -ge 0)
            completedDrives       = $CompletedDrives
            totalDrives           = $TotalDrives
            filesProcessed        = $files
            directoriesProcessed  = $directories
            elapsedMilliseconds   = [int64]$ElapsedMilliseconds
            updatedAt             = $now
        }
        $finalPath = Join-Path $runtime 'scan-progress.json'
        Write-DiskPulseAtomicText -FinalPath $finalPath -Content (ConvertTo-Json -InputObject $record -Depth 3 -Compress) -Validate {
            param($Path)
            try {
                $parsed = Get-Content -Raw -LiteralPath $Path -Encoding UTF8 | ConvertFrom-Json
                return ($null -ne $parsed -and [string]$parsed.scanId -eq $ScanId -and [string]$parsed.status -eq $Status)
            }
            catch {
                return $false
            }
        }
    }
    catch { }
}

function Should-RenderConsoleProgress {
    param(
        [Parameter(Mandatory=$true)] $Progress,
        [Parameter(Mandatory=$true)] $State
    )
    $isFirst = [int64]$State.LastRenderedMilliseconds -lt 0 -or [int64]$Progress.filesProcessed -eq 0
    $isFinal = [int]$Progress.totalTopLevel -ge 0 -and [int]$Progress.completedTopLevel -eq [int]$Progress.totalTopLevel
    $intervalElapsed = ([int64]$Progress.elapsedMilliseconds - [int64]$State.LastRenderedMilliseconds) -ge 1000
    if (-not ($isFirst -or $isFinal -or $intervalElapsed)) { return $false }
    $State.LastRenderedMilliseconds = [int64]$Progress.elapsedMilliseconds
    return $true
}

function Format-ScanProgressLine {
    param(
        [Parameter(Mandatory=$true)] $Progress,
        [int] $CompletedDrives = 0,
        [int] $TotalDrives = 1
    )
    $barWidth = 16
    $knownPercent = $Progress.percentComplete -ge 0 -and $TotalDrives -gt 0
    if ($knownPercent) {
        $driveFraction = [double]$Progress.percentComplete / 100
        $overallPercent = [math]::Max(0, [math]::Min(100, (($CompletedDrives + $driveFraction) / $TotalDrives) * 100))
        $filled = [math]::Min($barWidth, [math]::Floor($overallPercent * $barWidth / 100))
        $bar = (([string][char]0x2588) * $filled) + (([string][char]0x2591) * ($barWidth - $filled))
        $percentText = ('{0,3:N0}%' -f $overallPercent)
    }
    else {
        $bar = (([string][char]0x2591) * $barWidth)
        $percentText = '扫描中'
    }

    $prefix = '[{0}] {1} {2} | 文件 {3} | 目录 {4} | {5:N1} 秒 | ' -f $bar, $percentText, $Progress.drive,
        [int64]$Progress.filesProcessed, [int64]$Progress.directoriesProcessed, ([double]$Progress.elapsedMilliseconds / 1000)
    $path = [string]$Progress.currentPath
    $available = [math]::Max(0, 130 - $prefix.Length)
    if ($path.Length -gt $available) {
        if ($available -gt 1) { $path = ([string][char]0x2026) + $path.Substring($path.Length - ($available - 1)) }
        else { $path = '' }
    }
    return $prefix + $path
}
