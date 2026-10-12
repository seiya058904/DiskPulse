$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'TestHelpers.ps1')
$canonical = New-DiskPulseCanonicalTestSource -Components @('Common','History','Persistence','AI','Migration')
. $canonical
$testRoot = Join-Path $env:TEMP ('DiskPulse-Initialization-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($testRoot) | Out-Null
function Assert($Condition,[string]$Message) { if (-not $Condition) { throw $Message } }
function Paths([string]$Name) {
    $root = Join-Path $testRoot $Name
    $runtime = Join-Path $root 'runtime'
    [IO.Directory]::CreateDirectory((Join-Path $runtime 'snapshots')) | Out-Null
    [pscustomobject]@{Root=$root;Runtime=$runtime;Snapshots=(Join-Path $runtime 'snapshots');Events=(Join-Path $runtime 'scans.jsonl');Lock=(Join-Path $runtime 'DiskPulse.lock')}
}
$original = ${function:Write-DiskPulseAtomicText}
try {
    foreach ($phase in @('ledger','marker','ledger-after','marker-after')) {
        $paths = Paths $phase
        $script:failureSuffix = if ($phase.StartsWith('ledger')) { 'migration-ledger.json' } else { 'migration-initialized.json' }
        $script:afterPublication = $phase.EndsWith('-after')
        function Write-DiskPulseAtomicText {
            param([string]$FinalPath,[string]$Content,[scriptblock]$Validate=$null)
            if ($FinalPath.EndsWith($script:failureSuffix) -and -not $script:afterPublication) { throw 'isolated initialization failure' }
            & $original -FinalPath $FinalPath -Content $Content -Validate $Validate
            if ($FinalPath.EndsWith($script:failureSuffix) -and $script:afterPublication) { throw 'isolated initialization failure' }
        }
        try { Invoke-DiskPulseMigration $paths @(); throw 'Expected failure missing' }
        catch { Assert ($_.Exception.Message -eq 'isolated initialization failure') 'Unexpected initialization outcome' }
        Assert ((Test-Path (Join-Path $paths.Root 'migration-initialized.json')) -eq ($phase -eq 'marker-after')) 'Marker published before valid ledger'
        Assert ((Test-Path (Join-Path $paths.Root 'migration-ledger.json')) -eq ($phase -ne 'ledger')) 'Ledger publication order incorrect'
        Set-Item function:Write-DiskPulseAtomicText $original
        Invoke-DiskPulseMigration $paths @()
        $ledger = Join-Path $paths.Root 'migration-ledger.json'
        $before = [IO.File]::ReadAllText($ledger)
        Invoke-DiskPulseMigration $paths @()
        Assert ([IO.File]::ReadAllText($ledger) -eq $before) 'Retry changed valid empty ledger'
        Assert ((Get-Content -Raw (Join-Path $paths.Root 'migration-initialized.json') | ConvertFrom-Json).schemaVersion -eq 1) 'Marker verification failed'
    }
    Write-Host 'PASS: isolated ledger/marker publication failure, retry and initialization idempotency.'
    Write-Host "Evidence fixtures: $testRoot"
} finally {
    Set-Item function:Write-DiskPulseAtomicText $original
}
