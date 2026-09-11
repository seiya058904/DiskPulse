$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$nsis=$env:DISKPULSE_NSIS_PATH
if(-not $nsis -or -not (Test-Path -LiteralPath $nsis)) { Write-Host 'SKIP: set DISKPULSE_NSIS_PATH for isolated NSIS-to-launcher encoding QA.'; exit 0 }
$fixture=Join-Path $env:TEMP ('DiskPulse-Encoding-'+[guid]::NewGuid().ToString('N'))
$unicode=Join-Path $fixture '旧版-é-日本-😀'
$legacy=Join-Path $unicode 'runtime'
[IO.Directory]::CreateDirectory((Join-Path $legacy 'snapshots')) | Out-Null
try {
    [IO.File]::WriteAllText((Join-Path $legacy 'snapshots\unicode.json'),'{"scanId":"unicode","completedAt":"2026-01-01T00:00:00Z","drives":[]}',[Text.Encoding]::UTF8)
    [IO.File]::WriteAllText((Join-Path $legacy 'scans.jsonl'),'{"scanId":"unicode","status":"complete"}',[Text.Encoding]::UTF8)
    [IO.File]::WriteAllText((Join-Path $legacy 'DiskPulse.csv'),"Timestamp,ID,Total,Free,Used,Percent`r`n2026-01-01,T:,100,90,10,10`r`n",[Text.Encoding]::UTF8)
    # Compile the exact production marker-writing block, substituting only its isolated data directory.
    $source=Get-Content -Raw -LiteralPath (Join-Path $root 'installer/DiskPulse.nsi') -Encoding UTF8
    $block=[regex]::Match($source,'(?s)    CreateDirectory "\$LOCALAPPDATA\\DiskPulse\\data\\runtime".*?\$\{EndIf\}').Value
    if(-not $block){throw 'Production NSIS migration block missing.'}
    $block=$block.Replace('$LOCALAPPDATA\DiskPulse\data','$EXEDIR\data')
    $script="Unicode True`r`nRequestExecutionLevel user`r`n!include `"LogicLib.nsh`"`r`nOutFile `"$unicode\Marker.exe`"`r`nSection`r`n$block`r`nSectionEnd`r`n"
    $scriptPath=Join-Path $fixture 'marker.nsi';[IO.File]::WriteAllText($scriptPath,$script,[Text.Encoding]::UTF8)
    & $nsis /V2 $scriptPath
    if($LASTEXITCODE -ne 0){throw 'Marker harness compilation failed.'}
    $process=Start-Process -FilePath (Join-Path $unicode 'Marker.exe') -ArgumentList '/S' -WindowStyle Hidden -Wait -PassThru
    if($process.ExitCode -ne 0){throw 'NSIS marker writer failed.'}
    $marker=@(Get-ChildItem -LiteralPath (Join-Path $unicode 'data') -Filter '*.migration-source' -File)
    if($marker.Count -ne 1){throw 'NSIS did not produce exactly one marker.'}
    $bytes=[IO.File]::ReadAllBytes($marker[0].FullName)
    if($bytes[0] -ne 255 -or $bytes[1] -ne 254 -or [Text.Encoding]::Unicode.GetString($bytes,2,$bytes.Length-2).Trim() -cne $legacy){throw 'NSIS Unicode marker mismatch.'}
    $build=Join-Path $fixture 'build'
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'build-release.ps1') -OutputPath $build
    if($LASTEXITCODE -ne 0){throw 'Launcher build failed.'}
    $assembly=[Reflection.Assembly]::Load([IO.File]::ReadAllBytes((Join-Path $build 'DiskPulse.exe')))
    $payloadRoot=Join-Path $fixture 'payload'
    $extract=$assembly.GetType('Payload').GetMethod('EnsureExtracted',[Reflection.BindingFlags]'NonPublic,Static',$null,[Type[]]@([string]),$null)
    $extract.Invoke($null,[object[]]@([string]$payloadRoot)) | Out-Null
    $migrate=$assembly.GetType('DataPaths').GetMethod('RunMigration',[Reflection.BindingFlags]'NonPublic,Static')
    $diagnostic=$migrate.Invoke($null,[object[]]@([string]$payloadRoot,[string](Join-Path $unicode 'data'),[string[]]@()))
    if($diagnostic){throw "Launcher migration failed: $diagnostic"}
    $runtime=Join-Path $unicode 'data\runtime'
    if(-not (Test-Path (Join-Path $runtime 'snapshots\unicode.json')) -or -not (Test-Path (Join-Path $runtime 'scans.jsonl')) -or (Import-Csv (Join-Path $runtime 'DiskPulse.csv')).ID -ne 'T:'){throw 'NSIS-to-launcher data import failed.'}
    Write-Host 'PASS: production NSIS Unicode marker -> packaged launcher -> canonical migration, isolated from shortcuts/registry.'
} finally {
    foreach($file in @(Get-ChildItem -LiteralPath $fixture -Recurse -File -Force)){[IO.File]::Delete($file.FullName)}
    foreach($dir in @(Get-ChildItem -LiteralPath $fixture -Recurse -Directory -Force | Sort-Object { $_.FullName.Length } -Descending)){[IO.Directory]::Delete($dir.FullName)}
    [IO.Directory]::Delete($fixture)
}
