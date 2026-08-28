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
