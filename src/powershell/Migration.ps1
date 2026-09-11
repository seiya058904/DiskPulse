# Migration runs under the same ownership and publication protocol as scans.
function Test-DiskPulseMigrationPath {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    $item = Get-Item -LiteralPath $Path -Force
    return (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0)
}

function Read-DiskPulseMigrationMarker {
    param([string]$Path)
    if (-not (Test-DiskPulseMigrationPath $Path)) { throw 'Invalid migration marker.' }
    $bytes = [IO.File]::ReadAllBytes($Path)
    $texts = @()
    if ($bytes.Length -ge 2 -and $bytes[0] -eq 255 -and $bytes[1] -eq 254) {
        $texts = @((New-Object Text.UnicodeEncoding $false,$true,$true).GetString($bytes,2,$bytes.Length-2))
    } elseif ($bytes.Length -ge 3 -and $bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191) {
        $texts = @((New-Object Text.UTF8Encoding $false,$true).GetString($bytes,3,$bytes.Length-3))
    } else {
        try { $texts += (New-Object Text.UTF8Encoding $false,$true).GetString($bytes) } catch {}
        $acp = [Globalization.CultureInfo]::CurrentCulture.TextInfo.ANSICodePage
        if ('DiskPulseCodePage' -as [type]) { $acp = [DiskPulseCodePage]::GetACP() }
        else {
            Add-Type -TypeDefinition 'using System.Runtime.InteropServices; public static class DiskPulseCodePage { [DllImport("kernel32.dll")] public static extern int GetACP(); }'
            $acp = [DiskPulseCodePage]::GetACP()
        }
        try { $texts += [Text.Encoding]::GetEncoding($acp,[Text.EncoderFallback]::ExceptionFallback,[Text.DecoderFallback]::ExceptionFallback).GetString($bytes) } catch {}
    }
    $valid = @($texts | Select-Object -Unique | Where-Object {
        $paths = @($_ -split '\r?\n' | Where-Object { $_.Trim() })
        $paths.Count -gt 0 -and @($paths | Where-Object { -not [IO.Path]::IsPathRooted($_) -or -not (Test-Path -LiteralPath $_ -PathType Container) }).Count -eq 0
    })
    if ($valid.Count -ne 1) { throw 'Migration marker is ambiguous or its source is unavailable.' }
    @($valid[0] -split '\r?\n' | Where-Object { $_.Trim() })
}

function Save-DiskPulseMigrationLedger {
    param([string]$Path,$Ledger)
    Write-DiskPulseAtomicText -FinalPath $Path -Content (ConvertTo-Json -InputObject $Ledger -Depth 20) -Validate {
        param($temporary)
        $value = Get-Content -Raw -LiteralPath $temporary -Encoding UTF8 | ConvertFrom-Json
        return $value.schemaVersion -eq 1 -and $value.sources -is [array]
    }
}

function Invoke-DiskPulseMigration {
    param($Paths,[string[]]$Sources,[string]$MarkerPath)
    Ensure-Directory $Paths.Runtime
    $owner = Acquire-DiskPulseLock $Paths ('migration-'+[guid]::NewGuid().ToString('N'))
    try {
        $data = Split-Path -Parent $Paths.Runtime
        $ledgerPath = Join-Path $data 'migration-ledger.json'
        $initialized = Join-Path $data 'migration-initialized.json'
        if (Test-Path -LiteralPath $ledgerPath) {
            try {
                if (-not (Test-DiskPulseMigrationPath $ledgerPath)) { throw 'Linked ledger.' }
                $ledger = Get-Content -Raw -LiteralPath $ledgerPath -Encoding UTF8 | ConvertFrom-Json
                if ($ledger.schemaVersion -ne 1 -or $ledger.sources -isnot [array]) { throw 'Invalid ledger.' }
                foreach($entry in $ledger.sources) {
                    if (-not [IO.Path]::IsPathRooted([string]$entry.path) -or $entry.complete -isnot [bool] -or $entry.items -isnot [array]) { throw 'Invalid source state.' }
                    foreach($item in $entry.items) { if (-not $item.key -or $item.state -notin @('done','conflict','invalid')) { throw 'Invalid item state.' } }
                }
            } catch { throw 'migration state unavailable; original ledger preserved.' }
        } else {
            if (Test-Path -LiteralPath $initialized) { throw 'migration state unavailable; ledger missing.' }
            Write-DiskPulseAtomicText -FinalPath $initialized -Content '{"schemaVersion":1}'
            $ledger = [pscustomobject]@{schemaVersion=1;sources=@()}
            Save-DiskPulseMigrationLedger $ledgerPath $ledger
        }
        $markerSources = @(); $markers=@{}
        $markerFiles=@(Get-ChildItem -LiteralPath $data -Filter '*.migration-source' -File | ForEach-Object FullName)
        if ($MarkerPath -and (Test-Path -LiteralPath $MarkerPath)) { $markerFiles+=@($MarkerPath) }
        foreach($markerFile in $markerFiles) {
            $markers[$markerFile]=@(Read-DiskPulseMigrationMarker $markerFile)
            $markerSources+=@($markers[$markerFile])
        }
        foreach ($source in @(@($Sources)+$markerSources | Where-Object { $_ } | ForEach-Object { [IO.Path]::GetFullPath($_).TrimEnd('\') } | Select-Object -Unique)) {
            $target = [IO.Path]::GetFullPath($Paths.Runtime).TrimEnd('\')
            if (Test-DiskPulseRelatedPath $source $target) { Write-Warning "Skipping overlapping migration source: $source"; continue }
            if (-not (Test-Path -LiteralPath $source)) { continue }
            if (-not (Test-DiskPulseMigrationPath $source)) { Write-Warning "Skipping linked migration source: $source"; continue }
            $entry = @($ledger.sources | Where-Object { $_.path -eq $source }) | Select-Object -First 1
            if ($entry -and $entry.complete) { continue }
            if (-not $entry) {
                $entry=[pscustomobject]@{path=$source;complete=$false;items=@()}
                $ledger.sources=@($ledger.sources)+@($entry)
                Save-DiskPulseMigrationLedger $ledgerPath $ledger
            }
            $journal = Join-Path $source 'scans.jsonl'
            $final=@{}
            if (Test-Path -LiteralPath $journal) {
                if (-not (Test-DiskPulseMigrationPath $journal)) { throw 'Linked source journal.' }
                Read-DiskPulseScanEvents $journal | ForEach-Object { $final[[string]$_.scanId]=$_ }
            }
            $snapshotDirectory=Join-Path $source 'snapshots'
            $files=@()
            if (Test-DiskPulseMigrationPath $snapshotDirectory) { $files=@(Get-ChildItem -LiteralPath $snapshotDirectory -Filter '*.json' -File) }
            foreach($file in $files) {
                $key='snapshot/'+$file.Name
                if (@($entry.items | Where-Object { $_.key -eq $key -and $_.state -eq 'done' }).Count) { continue }
                $state='invalid'
                if (Test-DiskPulseMigrationPath $file.FullName) {
                    try {
                        $content=[IO.File]::ReadAllText($file.FullName,[Text.Encoding]::UTF8)
                        $snapshot=$content | ConvertFrom-Json
                        $id=[string]$snapshot.scanId
                        if (-not $id -or $id -ne $file.BaseName -or $snapshot.drives -isnot [array] -or -not $snapshot.completedAt -or
                            -not $final.ContainsKey($id) -or $final[$id].status -notin @('complete','partial')) { throw 'Untrusted snapshot.' }
                        [datetime]$snapshot.completedAt | Out-Null
                        Ensure-Directory $Paths.Snapshots
                        $destination=Join-Path $Paths.Snapshots $file.Name
                        $state=Invoke-DiskPulsePublication $Paths.Runtime {
                            $events=@(Read-DiskPulseScanEvents $Paths.Events)
                            $existing=@($events | Where-Object { $_.scanId -eq $id }) | Select-Object -Last 1
                            if (Test-Path -LiteralPath $destination) {
                                if (-not (Test-DiskPulseMigrationPath $destination) -or [IO.File]::ReadAllText($destination,[Text.Encoding]::UTF8) -ne $content) { return 'conflict' }
                            } elseif ($existing) { return 'conflict' }
                            if ($existing -and $existing.status -ne $final[$id].status) { return 'conflict' }
                            if (-not (Test-Path -LiteralPath $destination)) { Write-DiskPulseAtomicText -FinalPath $destination -Content $content }
                            if (-not $existing) {
                                # Imported history precedes the current journal; it must not become the current scan.
                                $lines=@(@($final[$id])+@($events) | ForEach-Object { ConvertTo-Json -InputObject $_ -Depth 12 -Compress })
                                Write-DiskPulseAtomicText $Paths.Events (($lines -join [Environment]::NewLine)+[Environment]::NewLine)
                            }
                            return 'done'
                        }
                    } catch { Write-Warning "Migration snapshot unavailable: $($file.Name)" }
                }
                $entry.items=@($entry.items | Where-Object { $_.key -ne $key })+@([pscustomobject]@{key=$key;state=$state})
                if ($state -eq 'conflict') { Write-Warning "Migration conflict preserved: $($file.Name)" }
                Save-DiskPulseMigrationLedger $ledgerPath $ledger
            }
            foreach($name in @('DiskPulse.csv','ai-config.local.json')) {
                if (@($entry.items | Where-Object { $_.key -eq $name -and $_.state -eq 'done' }).Count) { continue }
                $file=Join-Path $source $name
                if (-not (Test-Path -LiteralPath $file)) { continue }
                $state='invalid'
                if (Test-DiskPulseMigrationPath $file) {
                    try {
                        $destination=Join-Path $Paths.Runtime $name
                        if ($name -eq 'DiskPulse.csv') {
                            $import=@(Import-Csv -LiteralPath $file)
                            foreach($row in $import) {
                                foreach($field in @('Timestamp','ID','Total','Free','Used','Percent')) { if ($row.PSObject.Properties.Name -notcontains $field) { throw 'Invalid CSV.' } }
                                [datetime]$row.Timestamp | Out-Null
                                foreach($field in @('Total','Free','Used','Percent')) { [double]::Parse($row.$field,[Globalization.CultureInfo]::InvariantCulture) | Out-Null }
                            }
                            Invoke-DiskPulsePublication $Paths.Runtime {
                                $current=if(Test-Path -LiteralPath $destination){@(Import-Csv -LiteralPath $destination)}else{@()}
                                $seen=@{}; $merged=@($current)+@($import) | Where-Object { $k=$_.Timestamp+'|'+$_.ID; if(-not $seen.ContainsKey($k)){$seen[$k]=$true;$true} }
                                Write-DiskPulseAtomicCsv -FinalPath $destination -Rows @($merged)
                            }
                        } else {
                            $config=Get-Content -Raw -LiteralPath $file -Encoding UTF8 | ConvertFrom-Json
                            $config.enabled=$false
                            Invoke-DiskPulsePublication $Paths.Runtime {
                                if (-not (Test-Path -LiteralPath $destination) -and -not (Test-Path -LiteralPath ($destination+'.deleted'))) {
                                    Save-DiskPulseAIConfig -ConfigPath $destination -Config $config
                                }
                            }
                        }
                        $state='done'
                    } catch { Write-Warning "Migration item unavailable: $name" }
                }
                $entry.items=@($entry.items | Where-Object { $_.key -ne $name })+@([pscustomobject]@{key=$name;state=$state})
                Save-DiskPulseMigrationLedger $ledgerPath $ledger
            }
            $entry.complete=@($entry.items | Where-Object { $_.state -ne 'done' }).Count -eq 0
            Save-DiskPulseMigrationLedger $ledgerPath $ledger
        }
        foreach($markerFile in $markers.Keys) {
            $pending=@($markers[$markerFile] | Where-Object { $p=[IO.Path]::GetFullPath($_).TrimEnd('\'); -not @($ledger.sources | Where-Object { $_.path -eq $p -and $_.complete }).Count })
            if (-not $pending.Count) { Remove-Item -LiteralPath $markerFile -Force }
        }
    } finally { Release-DiskPulseLock $Paths $owner }
}
