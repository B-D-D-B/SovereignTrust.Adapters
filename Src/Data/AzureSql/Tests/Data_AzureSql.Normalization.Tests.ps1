using module SignalGraph

$ErrorActionPreference = 'Stop'
$foundation = Join-Path $PSScriptRoot '../../../../../SovereignTrust.Foundation/Src/PowerShell/SovereignTrust.Foundation.psd1'
$manifest = Join-Path $PSScriptRoot '../PowerShell/Data_AzureSql.psd1'
Import-Module (Resolve-Path $foundation).ProviderPath -Force
Import-Module (Resolve-Path $manifest).ProviderPath -Force

function Assert([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
$module = Get-Module Data_AzureSql
& $module {
    Set-Item Function:script:Invoke-AzureSqlExecution -Value {
        param($Adapter, $Slot, $Activity, $Config, $Plan, $NormalizedWrite, $ConductionSignal, $ItemSignal)
        $script:Observed = [pscustomobject]@{ Normalized = $NormalizedWrite; Config = $Config; Plan = $Plan }
        return '{"Operation":"Write","RowsAffected":null,"OutputParameters":{},"ResultSets":[]}'
    }
}
$adapter = Resolve-Data_AzureSql
$null = $adapter.Construct([pscustomobject]@{ Resource = 'synthetic' })
$conduction = [Signal]::Start('AzureSqlNormalization.Conduction') | Select-Object -Last 1
$item = [Signal]::Start('AzureSqlNormalization.Item') | Select-Object -Last 1

function Invoke-Case([object]$Config, [bool]$ShouldFail = $false) {
    $plan = [pscustomobject]@{ Config = $Config }
    $before = ConvertTo-Json -InputObject $plan -Depth 100 -Compress
    $result = $adapter.Invoke('FusionDatabase', 'Write', $conduction, $plan, $item)
    Assert ($result.Failure() -eq $ShouldFail) "Unexpected Write outcome for $before : $($result.GetEntries() | Out-String)"
    Assert ((ConvertTo-Json -InputObject $plan -Depth 100 -Compress) -ceq $before) 'Write changed the caller plan.'
    return $result
}
function ObservedJson { return (& $module { $script:Observed.Normalized.Json }) }

$row = [pscustomobject]@{ Id = '1'; Name = 'Museum' }
$config = [pscustomobject]@{ Procedure = 'dbo.Ingest'; Content = @($row); ColumnSchema = @{ Id = 'int' } }
$null = Invoke-Case $config
$records = ConvertFrom-Json -InputObject (ObservedJson) -NoEnumerate
Assert ($records -is [array] -and $records.Count -eq 1 -and $records[0].Id -eq 1 -and $row.Id -ceq '1') 'Object Records/defaults or schema failed.'
Assert ((& $module { $script:Observed.Normalized.InputFormat }) -eq 'Object') 'InputFormat default failed.'
Assert ((& $module { $script:Observed.Normalized.PayloadMode }) -eq 'Records') 'PayloadMode default failed.'
$null = Invoke-Case ([pscustomobject]@{ Procedure='p'; Content=@() })
Assert ((ObservedJson) -ceq '[]') 'Empty Records must serialize as an array.'

$null = Invoke-Case ([pscustomobject]@{ Procedure='p'; Content='[{"Id":"4"}]'; InputFormat='Json'; ColumnSchema=@(@{Name='Id';Type='long'}) })
Assert ((ObservedJson | ConvertFrom-Json)[0].Id -eq 4) 'JSON Records/descriptors failed.'
$null = Invoke-Case ([pscustomobject]@{ Procedure='p'; Content='Id;Name;Empty' + "`r`n" + '2;"Gallery' + "`r`n" + 'Archive";'; InputFormat='Csv'; Delimiter=';'; ColumnSchema=@{Id='int'} })
$csv = ConvertFrom-Json -InputObject (ObservedJson) -NoEnumerate
Assert ($csv.Count -eq 1 -and $csv[0].Id -eq 2 -and $csv[0].Name -eq "Gallery`r`nArchive" -and $csv[0].Empty -eq '') "CSV quoted/newline/empty/delimiter failed: $(ObservedJson)"
$null = Invoke-Case ([pscustomobject]@{ Procedure='p'; Content='Id,Name' + "`n" + '3,Museum'; InputFormat='Csv' })
Assert ((ObservedJson | ConvertFrom-Json)[0].Id -eq '3') 'CSV comma default failed.'

foreach ($document in @('[]','[{"Id":1}]','{"Metadata":{"Name":"WeatherVault"}}')) {
    $null = Invoke-Case ([pscustomobject]@{ Procedure='p'; Content=$document; InputFormat='Json'; PayloadMode='Document' })
    $expected = $document | ConvertFrom-Json -NoEnumerate
    $actual = (ObservedJson) | ConvertFrom-Json -NoEnumerate
    if ($document.StartsWith('[')) { Assert ($actual -is [array] -and $actual.Count -eq $expected.Count) 'Document array cardinality changed.' }
    else { Assert ($actual.Metadata.Name -eq 'WeatherVault') 'Nested document failed.' }
}
$null = Invoke-Case ([pscustomobject]@{ Procedure='p'; Content=@(); PayloadMode='Document' })
Assert ((ObservedJson) -ceq '[]') 'Empty Object Document array changed.'
$null = Invoke-Case ([pscustomobject]@{ Procedure='p'; Content=@([pscustomobject]@{ Id=1 }); PayloadMode='Document' })
Assert ((ObservedJson) -match '^\[') 'One-element Object Document array changed.'
foreach ($falseLike in @($false, 0, '', $null)) {
    $null = Invoke-Case ([pscustomobject]@{ Procedure='p'; Content=$falseLike; PayloadMode='Document' })
    Assert ($null -ne (ObservedJson)) 'A present false-like Content member was treated as missing.'
}

$conversionRow = [pscustomobject]@{ Text=7; Big='9007199254740992'; Amount='12.50'; Float='1.25'; Flag='1'; When='2024-01-02T03:04:05Z'; Missing=$null; Extra='kept' }
$conversionSchema = @{Text='nvarchar'; Big='bigint'; Amount='numeric'; Float='float'; Flag='bit'; When='datetimeoffset'; Missing='int'}
$null = Invoke-Case ([pscustomobject]@{ Procedure='p'; Content=@($conversionRow); ColumnSchema=$conversionSchema })
$converted = (ObservedJson | ConvertFrom-Json)[0]
Assert ($converted.Text -eq '7' -and $converted.Big -eq 9007199254740992 -and $converted.Amount -eq 12.50 -and $converted.Float -eq 1.25 -and $converted.Flag -eq $true -and $converted.When -and $null -eq $converted.Missing -and $converted.Extra -eq 'kept') 'ColumnSchema type conversions failed.'
Assert ($conversionRow.Text -is [int] -and $conversionRow.Flag -ceq '1') 'ColumnSchema changed input row.'

$item.SetResult([pscustomobject]@{ Payload = [pscustomobject]@{ Metadata = [pscustomobject]@{ Name='WeatherVault'; Version=1 } } }) | Out-Null
$null = Invoke-Case ([pscustomobject]@{ Procedure='p'; ContentPath='@.Payload'; PayloadMode='Document' })
Assert (((ObservedJson | ConvertFrom-Json).Metadata.Name) -eq 'WeatherVault') 'Signal-relative ContentPath failed.'
$null = Invoke-Case ([pscustomobject]@{ Procedure='p'; ContentPath='@.Missing'; PayloadMode='Document' }) $true

foreach ($bad in @(
    [pscustomobject]@{ Procedure='p' },
    [pscustomobject]@{ Procedure='p'; Content=$null; ContentPath='@.Payload' },
    [pscustomobject]@{ Procedure='p'; ContentPath='' },
    [pscustomobject]@{ Procedure='p'; Content=$null },
    [pscustomobject]@{ Procedure='p'; Content=$false },
    [pscustomobject]@{ Procedure='p'; Content='bad'; InputFormat='Json' },
    [pscustomobject]@{ Procedure='p'; Content=@(); InputFormat='Wrong' },
    [pscustomobject]@{ Procedure='p'; Content=@(); PayloadMode='Wrong' },
    [pscustomobject]@{ Procedure='p'; Content='Id,Name'; InputFormat='Csv'; PayloadMode='Document' },
    [pscustomobject]@{ Procedure='p'; Content='Id,Name'; InputFormat='Csv'; Delimiter=';;' },
    [pscustomobject]@{ Procedure='p'; Content=@([pscustomobject]@{ Id='x' }); ColumnSchema=@{Id='int'} },
    [pscustomobject]@{ Procedure='p'; Content=@([pscustomobject]@{ Id=1 }); ColumnSchema=@{Id='unsupported'} },
    [pscustomobject]@{ Procedure='p'; Content=@([pscustomobject]@{ Flag='maybe' }); ColumnSchema=@{Flag='bit'} },
    [pscustomobject]@{ Procedure='p'; Content=@(1) }
)) { $null = Invoke-Case $bad $true }

$values = [object[]]::new(9)
$values[0] = [int]7
$values[1] = [long]9007199254740992
$values[2] = [decimal]'1.25'
$values[3] = [guid]'11111111-1111-1111-1111-111111111111'
$values[4] = [datetime]'2024-01-02'
$values[5] = [byte[]](1,2,3)
$values[6] = $null
$values[7] = @{ Nested = @(1,2) }
$values[8] = @(3,4)
$parameters = [pscustomobject]@{ Values = $values }
$typed = [pscustomobject]@{ Procedure='p'; Content=@([pscustomobject]@{ Id='1' }); ColumnSchema=@{Id='int'}; Parameters=$parameters }
$snapshot = [object[]]$values.Clone()
$null = Invoke-Case $typed
Assert ([object]::ReferenceEquals($typed.Parameters, $parameters)) 'Parameter object was replaced.'
for ($i=0; $i -lt $values.Count; $i++) {
    Assert (($null -eq $values[$i] -and $null -eq $snapshot[$i]) -or ($values[$i].GetType() -eq $snapshot[$i].GetType() -and [object]::ReferenceEquals($values[$i], $snapshot[$i]))) "Parameter value $i changed on success."
}
$typed.ColumnSchema = @{Id='int'; Bad='unsupported'}
$null = Invoke-Case $typed $true
for ($i=0; $i -lt $values.Count; $i++) {
    Assert (($null -eq $values[$i] -and $null -eq $snapshot[$i]) -or ($values[$i].GetType() -eq $snapshot[$i].GetType() -and [object]::ReferenceEquals($values[$i], $snapshot[$i]))) "Parameter value $i changed on failure."
}

# Regression checks deliberately collect failures so a pre-fix run reports all
# three reviewed defects, rather than stopping at the first mismatch.
$regressions = [System.Collections.Generic.List[string]]::new()
function Check-Regression([bool]$Condition, [string]$Message) {
    if (-not $Condition) { $regressions.Add($Message) }
}
function Invoke-Regression([object]$Config) {
    $plan = [pscustomobject]@{ Config = $Config }
    $before = ConvertTo-Json -InputObject $plan -Depth 100 -Compress
    $result = $adapter.Invoke('FusionDatabase', 'Write', $conduction, $plan, $item)
    Check-Regression ((ConvertTo-Json -InputObject $plan -Depth 100 -Compress) -ceq $before) 'Regression case mutated caller plan.'
    return $result
}
function Check-RecordArrays([string]$Label) {
    $actual = ConvertFrom-Json -InputObject (ObservedJson) -AsHashtable -NoEnumerate
    $row = $actual[0]
    Check-Regression ($actual -is [array] -and $actual.Count -eq 1 -and
        $row.Empty -is [array] -and $row.Empty.Count -eq 0 -and
        $row.One -is [array] -and $row.One.Count -eq 1 -and $row.One[0] -is [ValueType] -and $row.One[0] -eq 1 -and
        $row.Nested -is [array] -and $row.Nested.Count -eq 2 -and
        $row.Nested[0] -is [array] -and $row.Nested[0].Count -eq 2 -and
        $row.Nested[1] -is [array] -and $row.Nested[1].Count -eq 1) "$Label lost Records property arrays: $(ObservedJson)"
}
$nested = [object[]]::new(2)
$nested[0] = @(1, 2)
$nested[1] = @(3)
$objectArrays = [pscustomobject]@{ Empty = @(); One = @(1); Nested = $nested }
$dictionaryArrays = @{ Empty = @(); One = @(1); Nested = $nested }
foreach ($case in @(
    @{ Label='PSCustomObject'; Config=[pscustomobject]@{ Procedure='p'; Content=@($objectArrays) } },
    @{ Label='Dictionary'; Config=[pscustomobject]@{ Procedure='p'; Content=@($dictionaryArrays) } },
    @{ Label='JSON'; Config=[pscustomobject]@{ Procedure='p'; InputFormat='Json'; Content='[{"Empty":[],"One":[1],"Nested":[[1,2],[3]]}]' } }
)) {
    $outcome = Invoke-Regression $case.Config
    Check-Regression (-not $outcome.Failure()) "$($case.Label) Records array case failed."
    if (-not $outcome.Failure()) { Check-RecordArrays $case.Label }
}

foreach ($jsonInput in @('[null]', '[[]]', '[[{"Id":1}]]')) {
    $outcome = Invoke-Regression ([pscustomobject]@{ Procedure='p'; InputFormat='Json'; Content=$jsonInput })
    Check-Regression ($outcome.Failure()) "Invalid Records entry was accepted: $jsonInput"
}
$validRecordCases = [object[]]::new(3)
$validRecordCases[0] = $objectArrays
$validRecordCases[1] = @($objectArrays)
$validRecordCases[2] = @($objectArrays, $objectArrays)
for ($i = 0; $i -lt $validRecordCases.Count; $i++) {
    $outcome = Invoke-Regression ([pscustomobject]@{ Procedure='p'; Content=$validRecordCases[$i] })
    Check-Regression (-not $outcome.Failure()) 'Valid single or multiple Records rows were rejected.'
    if (-not $outcome.Failure()) {
        $actual = ConvertFrom-Json -InputObject (ObservedJson) -AsHashtable -NoEnumerate
        $expectedCount = if ($i -eq 2) { 2 } else { 1 }
        Check-Regression ($actual -is [array] -and $actual.Count -eq $expectedCount) 'Valid Records row cardinality changed.'
    }
}

foreach ($badOption in @(
    [pscustomobject]@{ Procedure='p'; Content=@($objectArrays); InputFormat=@('Object') },
    [pscustomobject]@{ Procedure='p'; Content=@($objectArrays); PayloadMode=@('Document') },
    [pscustomobject]@{ Procedure='p'; Content='Id,Name'; InputFormat='Csv'; Delimiter=@(',') },
    [pscustomobject]@{ Procedure='p'; Content=@([pscustomobject]@{ Id='1' }); ColumnSchema=@(@{ Name='Id'; Type=@('int') }) }
)) {
    $outcome = Invoke-Regression $badOption
    Check-Regression ($outcome.Failure()) "Array-valued option was accepted: $(ConvertTo-Json -InputObject $badOption -Compress -Depth 20)"
}
Assert ($regressions.Count -eq 0) ($regressions -join [Environment]::NewLine)
Write-Output 'PASS: AzureSql Write normalization, signal paths, validation, cardinality, CSV, schema, and immutable typed parameters.'
