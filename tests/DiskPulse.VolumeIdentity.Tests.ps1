$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'src/powershell/Common.ps1')
. (Join-Path $root 'src/powershell/History.ps1')

function Assert-Identity([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}
function Identity-Drive([string]$Guid, [int64]$Size) {
    [pscustomobject]@{
        drive='T:'; rootPath='T:\'; volumeGuid=$Guid; status='complete';
        totalBytes=2000; usedBytes=$Size; freeBytes=(2000-$Size);
        scopeSignature='same-scope'; enumerationComplete=$true; childrenEnumerationComplete=$true;
        unavailable=@(); excluded=@(); errors=@(); records=@([pscustomobject]@{
            key='t:\data'; displayPath='T:\Data'; kind='directory'; level=1; sizeBytes=$Size;
            enumerationComplete=$true; childrenEnumerationComplete=$true
        })
    }
}
function Identity-Snapshot([string]$Id, [int]$Day, $Drive) {
    [pscustomobject]@{scanId=$Id; startedAt=('2026-01-{0:00}T00:00:00Z' -f $Day); completedAt=('2026-01-{0:00}T00:01:00Z' -f $Day); status='complete'; drives=@($Drive)}
}
$guidA='\\?\Volume{11111111-1111-1111-1111-111111111111}'
$guidB='\\?\Volume{22222222-2222-2222-2222-222222222222}'
$a=Identity-Snapshot 'a' 1 (Identity-Drive $guidA 1000)
$b=Identity-Snapshot 'b' 2 (Identity-Drive $guidB 10)
$wrong=Find-DriveBaseline @($a) 'T:' $b
$rows=@(Compare-DriveRecords $b.drives[0] $a.drives[0])
Write-Host ('CROSS_VOLUME baseline={0} rows={1}' -f $(if($wrong){$wrong.scanId}else{'none'}),($rows|ConvertTo-Json -Compress))
Assert-Identity ($null -eq $wrong) 'ISSUE21_CROSS_VOLUME_BASELINE: a different fixed volume must not be a baseline.'
Assert-Identity (@($rows|Where-Object state -in @('created','changed','removed','unchanged')).Count -eq 0) 'Different volumes must not produce reliable rows.'
Write-Host 'PASS: volume identity rejects cross-volume baselines and comparisons.'
