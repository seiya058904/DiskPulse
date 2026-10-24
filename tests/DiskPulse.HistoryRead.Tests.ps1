param([string]$EvidenceRoot = (Join-Path ([IO.Path]::GetTempPath()) ('DiskPulse-HistoryRead-' + [guid]::NewGuid().ToString('N'))))
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$Repo = Split-Path -Parent $PSScriptRoot
if (Test-Path -LiteralPath $EvidenceRoot) { throw 'EvidenceRoot must be a new directory.' }
$env:DISKPULSE_TEST_MODE='1'; $env:DISKPULSE_SILENT='1'; $env:DISKPULSE_NO_OPEN='1'
$env:DISKPULSE_ROOT=$Repo; $env:DISKPULSE_SCRIPT_PATH=Join-Path $Repo 'check.bat'
$env:SystemDrive='T:'
$source=Get-Content -Raw -LiteralPath $env:DISKPULSE_SCRIPT_PATH -Encoding UTF8
Invoke-Expression $source.Substring($source.IndexOf('#>')+2)
function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}
# Synthetic disk only; production scan orchestration, CSV IO and publication.
function Get-CimInstance {
    param($ClassName)
    [pscustomobject]@{DeviceID='T:'; DriveType=3; Size=100GB; FreeSpace=60GB; VolumeSerialNumber='AUDIT'}
}
function Get-DiskPulseDriveVolumeGuid { param($Drive) '\\?\Volume{11111111-1111-1111-1111-111111111111}\' }
function Get-DiskPulseDosDeviceTarget { param($Drive) '\Device\HarddiskVolume1' }
function Invoke-DirectoryScan {
    param($Drive,$RootPath,$ProgressCallback,$VolumeGuid)
    [pscustomobject]@{
        drive=$Drive; volumeGuid=$VolumeGuid; rootPath=$RootPath; status='complete';
        scopeSignature='diskpulse-scope-v1:fixed;depth=2;reparse=exclude;names=$recycle.bin,system volume information';scopeVersion=1;
        enumerationComplete=$true;childrenEnumerationComplete=$true;
        records=@([pscustomobject]@{key='T:\audit';displayPath='T:\audit';kind='directory';level=1;sizeBytes=[int64]1024;enumerationComplete=$true;childrenEnumerationComplete=$true});
        excluded=@();unavailable=@();errors=@()
    }
}
$script:historyLock=$null
$rows=@(
    [pscustomobject]@{Timestamp='2026-10-01 10:00:00';ID='T:';VolumeGuid='\\?\Volume{11111111-1111-1111-1111-111111111111}\';Total=100;Free=80;Used=20;Percent=20},
    [pscustomobject]@{Timestamp='2026-10-02 10:00:00';ID='T:';VolumeGuid='\\?\Volume{11111111-1111-1111-1111-111111111111}\';Total=100;Free=70;Used=30;Percent=30}
)

# The transient case unlocks immediately after the real CSV read fails,
# so subsequent publication would succeed if the scan incorrectly continued.
function Import-Csv {
    [CmdletBinding()]
    param([string]$LiteralPath)
    try { Microsoft.PowerShell.Utility\Import-Csv -LiteralPath $LiteralPath -ErrorAction Stop }
    finally {
        if ($script:releaseAfterRead -and $script:historyLock) {
            $script:historyLock.Dispose(); $script:historyLock=$null
        }
    }
}
foreach ($case in @('normal', 'transient', 'persistent', 'new')) {
    $env:DISKPULSE_DATA_ROOT=Join-Path $EvidenceRoot $case
    $runtime=Join-Path $env:DISKPULSE_DATA_ROOT 'runtime'
    [IO.Directory]::CreateDirectory($runtime) | Out-Null
    $history=Join-Path $runtime 'DiskPulse.csv'
    $html=Join-Path $runtime 'DiskPulse.html'
    $script:releaseAfterRead=$case -eq 'transient'
    $locked=$case -in @('transient','persistent')
    if ($case -ne 'new') { $rows | Export-Csv -LiteralPath $history -NoTypeInformation -Encoding UTF8 }
    if ($locked) {
        $before=[Convert]::ToBase64String([IO.File]::ReadAllBytes($history))
        [IO.File]::WriteAllText($html, '<html>previous report</html>')
        $script:historyLock=[IO.File]::Open($history,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    }
    $failure=$null
    try { Invoke-DiskPulse } catch { $failure=$_.Exception.Message }
    finally { if ($script:historyLock) { $script:historyLock.Dispose(); $script:historyLock=$null } }
    if ($locked) {
        Assert-True ($null -ne $failure) "$case must fail instead of publishing incomplete history."
        Assert-True ($failure -match 'History unreadable') "$case must explain the history read failure."
        Assert-True ([Convert]::ToBase64String([IO.File]::ReadAllBytes($history)) -eq $before) "$case must preserve exact CSV bytes."
        Assert-True ([IO.File]::ReadAllText($html) -eq '<html>previous report</html>') "$case must preserve the previous report."
        $events=@(Get-Content -LiteralPath (Join-Path $runtime 'scans.jsonl') -Encoding UTF8 | ForEach-Object { $_ | ConvertFrom-Json })
        Assert-True ($events[-1].status -eq 'failed') "$case must record a failed scan."
        $progress=Get-Content -Raw -LiteralPath (Join-Path $runtime 'scan-progress.json') -Encoding UTF8 | ConvertFrom-Json
        Assert-True ($progress.status -eq 'failed') "$case must report failed progress."
        Assert-True (@(Get-ChildItem -LiteralPath (Join-Path $runtime 'snapshots') -Filter '*.json').Count -eq 0) "$case must not publish a successful snapshot."
        # Retry uses the same data root and proves the run lock was released.
        Invoke-DiskPulse
    } else { Assert-True ($null -eq $failure) "$case must scan successfully: $failure" }
    $after=@(Import-Csv -LiteralPath $history)
    $expected=if ($case -eq 'new') { 1 } else { 3 }
    Assert-True ($after.Count -eq $expected) "$case must append exactly one row (including after retry)."
    if ($case -ne 'new') {
        Assert-True (@($after | Where-Object Timestamp -like '2026-10-0*').Count -eq 2) "$case must preserve both historical rows."
    }
    Assert-True (Test-Path -LiteralPath $html) "$case must generate a report after a successful scan."
    Write-Output "PASS: $case history read and publication"
}
Write-Output "History read regression passed; isolated evidence: $EvidenceRoot"
