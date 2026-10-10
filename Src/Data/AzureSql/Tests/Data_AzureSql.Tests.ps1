using module SignalGraph

$ErrorActionPreference = 'Stop'
$foundationManifest = Join-Path $PSScriptRoot '../../../../../SovereignTrust.Foundation/Src/PowerShell/SovereignTrust.Foundation.psd1'
$adapterManifest = Join-Path $PSScriptRoot '../PowerShell/Data_AzureSql.psd1'
Import-Module (Resolve-Path $foundationManifest).ProviderPath -Force
Import-Module (Resolve-Path $adapterManifest).ProviderPath -Force

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

$adapter = Resolve-Data_AzureSql
$jacket = [PSCustomObject]@{
    Name = 'SDAFusionDatabase'
    VirtualPath = 'SovereignTrust.Adapters.Data.AzureSql.FusionDatabase.Persistent.Full'
    Resource = 'synthetic-test-resource'
}
$construct = $adapter.Construct($jacket)
Assert-True (-not $construct.Failure() -and $adapter.Configuration -eq $jacket) 'Construct did not retain the hydrated jacket.'
Assert-True ($adapter.Signal.GetJacket().GetResult() -eq $jacket) 'Adapter signal lost the jacket.'

$conduction = [Signal]::Start('AzureSqlTest.Conduction') | Select-Object -Last 1
$item = [Signal]::Start('AzureSqlTest.Item') | Select-Object -Last 1
$queryPlan = [PSCustomObject]@{ Config = [PSCustomObject]@{ CommandText = 'select 1'; Parameters = @{ '@Id' = 1 }; CommandTimeoutSeconds = 15 } }
$queryBefore = $queryPlan | ConvertTo-Json -Depth 100 -Compress

$unsupported = $adapter.Invoke('FusionDatabase', 'Other', $conduction, $queryPlan, $item)
Assert-True ($unsupported.Failure()) 'Unsupported activity should return a failed signal.'
$missingConfig = $adapter.Invoke('FusionDatabase', 'Query', $conduction, [PSCustomObject]@{}, $item)
Assert-True ($missingConfig.Failure()) 'Missing Config should return a failed signal.'
$missingCommand = $adapter.Invoke('FusionDatabase', 'Query', $conduction, [PSCustomObject]@{ Config = @{} }, $item)
Assert-True ($missingCommand.Failure()) 'Missing CommandText should return a failed signal.'
$missingProcedure = $adapter.Invoke('FusionDatabase', 'Write', $conduction, [PSCustomObject]@{ Config = @{} }, $item)
Assert-True ($missingProcedure.Failure()) 'Missing Procedure should return a failed signal.'
$missingDeleteCommand = $adapter.Invoke('FusionDatabase', 'Delete', $conduction, [PSCustomObject]@{ Config = @{} }, $item)
Assert-True ($missingDeleteCommand.Failure()) 'Delete without CommandText should return a failed signal.'
$invalidResource = $adapter.Invoke('FusionDatabase', 'Query', $conduction, $queryPlan, $item)
Assert-True ($invalidResource.Failure()) 'Invalid connection resource should return a failed signal.'
Assert-True (($queryPlan | ConvertTo-Json -Depth 100 -Compress) -eq $queryBefore) 'Invocation changed the caller plan.'

$emptyTable = [System.Data.DataTable]::new('EmptyRecords')
$emptyId = $emptyTable.Columns.Add('Id', [int])
$emptyId.AllowDBNull = $false
$binaryTable = [System.Data.DataTable]::new('Values')
$null = $binaryTable.Columns.Add('Payload', [byte[]])
$null = $binaryTable.Columns.Add('Amount', [decimal])
$null = $binaryTable.Columns.Add('Missing', [string])
$null = $binaryTable.Columns.Add('When', [datetime])
$null = $binaryTable.Columns.Add('LargeId', [long])
$utcDate = [datetime]::SpecifyKind([datetime]'2024-12-01T12:34:56', [DateTimeKind]::Utc)
$null = $binaryTable.Rows.Add([byte[]](1, 2, 3), [decimal]'123.4500', [DBNull]::Value, $utcDate, [long]9007199254740992)
$dataSet = [System.Data.DataSet]::new()
$null = $dataSet.Tables.Add($emptyTable)
$null = $dataSet.Tables.Add($binaryTable)
$json = ConvertTo-AzureSqlJsonResult -Operation Query -Value $dataSet
$result = $json | ConvertFrom-Json -Depth 100
Assert-True ($result.ResultSets.Count -eq 2) 'Multiple result sets were not preserved.'
Assert-True ($result.ResultSets[0].Rows.Count -eq 0 -and $result.ResultSets[0].Columns[0].Name -eq 'Id') 'Empty result-set metadata was lost.'
$emptyMetadata = $result.ResultSets[0].Columns[0]
Assert-True ($emptyMetadata.SourceName -ceq 'Id' -and $emptyMetadata.Type -ceq 'int' -and
    $emptyMetadata.Ordinal -eq 0 -and $emptyMetadata.AllowDBNull -eq $false -and
    $null -eq $emptyMetadata.Precision -and $null -eq $emptyMetadata.Scale) 'Empty DataTable schema fields are incomplete.'
$tableMetadata = $result.ResultSets[1].Columns[1]
Assert-True ($tableMetadata.Name -ceq 'Amount' -and $tableMetadata.SourceName -ceq 'Amount' -and
    $tableMetadata.Type -ceq 'decimal' -and $tableMetadata.Ordinal -eq 1 -and
    $tableMetadata.AllowDBNull -eq $true -and $null -eq $tableMetadata.Precision -and
    $null -eq $tableMetadata.Scale) 'Populated DataTable schema fields are incomplete.'
Assert-True ($result.ResultSets[1].Rows[0].Payload -eq 'AQID') 'Binary value was not base64 encoded.'
Assert-True ($result.ResultSets[1].Rows[0].Amount -is [string] -and [decimal]$result.ResultSets[1].Rows[0].Amount -eq [decimal]'123.4500') 'Decimal precision was not preserved.'
Assert-True ($null -eq $result.ResultSets[1].Rows[0].Missing) 'DBNull was not serialized as null.'
Assert-True ($result.ResultSets[1].Rows[0].When.ToUniversalTime().ToString('o') -eq '2024-12-01T12:34:56.0000000Z') 'Date was not serialized as UTC ISO 8601.'
Assert-True ($result.ResultSets[1].Rows[0].LargeId -is [string] -and $result.ResultSets[1].Rows[0].LargeId -eq '9007199254740992') 'Large integer was not serialized as text.'
Assert-True ($json -notmatch 'DataSet|DataTable|DataRow') 'A database-specific type escaped in JSON.'
$rowResult = ConvertTo-AzureSqlJsonResult -Operation Query -Value $binaryTable.Rows[0] | ConvertFrom-Json -Depth 100
$rowMetadata = $rowResult.ResultSets[0].Columns[1]
Assert-True ($rowResult.ResultSets[0].Name -ceq 'Values' -and $rowMetadata.SourceName -ceq 'Amount' -and
    $rowMetadata.Ordinal -eq 1 -and $rowMetadata.AllowDBNull -eq $true -and
    $null -eq $rowMetadata.Precision -and $null -eq $rowMetadata.Scale -and
    $rowResult.ResultSets[0].Rows[0].Payload -ceq 'AQID') 'DataRow compatibility schema or values changed.'
$plain = ConvertTo-AzureSqlJsonResult -Operation Query -Value @([pscustomobject][ordered]@{ Id=1; Label='Museum' }) | ConvertFrom-Json -Depth 100
Assert-True ($plain.ResultSets[0].Columns.Count -eq 2 -and
    $plain.ResultSets[0].Columns[0].Name -ceq 'Id' -and $plain.ResultSets[0].Columns[0].SourceName -ceq 'Id' -and
    $plain.ResultSets[0].Columns[0].Type -ceq 'int' -and $plain.ResultSets[0].Columns[0].Ordinal -eq 0 -and
    $null -eq $plain.ResultSets[0].Columns[0].AllowDBNull -and $null -eq $plain.ResultSets[0].Columns[0].Precision -and
    $null -eq $plain.ResultSets[0].Columns[0].Scale -and $plain.ResultSets[0].Columns[1].Ordinal -eq 1 -and
    $plain.ResultSets[0].Rows[0].Label -ceq 'Museum') 'Plain-object compatibility schema or values changed.'
$unknown = ConvertTo-AzureSqlJsonResult -Operation Query -Value ([pscustomobject]@{ ResultSets=@(@()) }) | ConvertFrom-Json -Depth 100
Assert-True ($unknown.ResultSets[0].Columns.Count -eq 0) 'Schema-less empty rows gained invented columns.'
$sqlDecimal = [System.Data.SqlTypes.SqlDecimal]::Parse('123456789012345678901234567890.1200')
$sqlDecimalJson = ConvertTo-AzureSqlJsonResult -Operation Query -Value ([pscustomobject]@{
    ResultSets=@(); OutputParameters=[ordered]@{ '@Amount'=$sqlDecimal; '@Null'=[System.Data.SqlTypes.SqlDecimal]::Null }
})
$sqlDecimalEnvelope = ConvertFrom-Json -InputObject $sqlDecimalJson -Depth 100
Assert-True ($sqlDecimalEnvelope.OutputParameters.'@Amount' -ceq '123456789012345678901234567890.1200' -and
    $null -eq $sqlDecimalEnvelope.OutputParameters.'@Null') 'Invariant SqlDecimal conversion lost precision, scale, or null.'

$previousCulture = [System.Threading.Thread]::CurrentThread.CurrentCulture
try {
    [System.Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::GetCultureInfo('fr-FR')
    $guid = [guid]'AABBCCDD-EEFF-0011-2233-445566778899'
    $values = [ordered]@{
        Null = [DBNull]::Value
        Binary = [byte[]](0, 1, 255)
        Guid = $guid
        Date = [datetimeoffset]::Parse('2024-12-01T14:34:56+02:00')
        Time = [timespan]::Parse('12:34:56.1234567')
        Decimal = [decimal]::Parse('12345678901234567890.123456789', [Globalization.CultureInfo]::InvariantCulture)
        PositiveSafe = [long]9007199254740991
        NegativeSafe = [long]-9007199254740991
        PositiveUnsafe = [long]9007199254740992
        NegativeUnsafe = [long]-9007199254740992
        UnsignedUnsafe = [uint64]::MaxValue
        BigIntegerSafe = [System.Numerics.BigInteger]9007199254740991
        BigIntegerUnsafe = [System.Numerics.BigInteger]9007199254740992
        Floating = [double]1234.5
    }
    $precisionJson = ConvertTo-AzureSqlJsonResult -Operation Query -Value ([pscustomobject]@{
        ResultSets = @([pscustomobject]@{
            Columns = @([pscustomobject]@{ Name='Value'; SourceName='Value'; Type='sql_variant'; Ordinal=0; AllowDBNull=$true; Precision=$null; Scale=$null })
            Rows = @([pscustomobject]$values)
        })
        OutputParameters = [ordered]@{ '@Return'=[long]-9007199254740992; '@Amount'=[decimal]::Parse('123.4500', [Globalization.CultureInfo]::InvariantCulture); '@Guid'=$guid; '@Bytes'=[byte[]](0,1,255) }
    })
    $precision = ConvertFrom-Json -InputObject $precisionJson -Depth 100 -DateKind String
    $row = $precision.ResultSets[0].Rows[0]
    Assert-True ($null -eq $row.Null -and $row.Binary -eq 'AAH/' -and
        $row.Guid -ceq 'aabbccdd-eeff-0011-2233-445566778899' -and
        $row.Date -ceq '2024-12-01T12:34:56.0000000+00:00' -and
        $row.Time -ceq 'PT12H34M56.1234567S') 'Null, binary, GUID, or invariant date/time conversion failed.'
    Assert-True ($row.Decimal -ceq '12345678901234567890.123456789' -and
        $row.PositiveSafe -isnot [string] -and $row.NegativeSafe -isnot [string] -and
        $row.PositiveUnsafe -ceq '9007199254740992' -and
        $row.NegativeUnsafe -ceq '-9007199254740992' -and
        $row.UnsignedUnsafe -ceq '18446744073709551615' -and
        $row.BigIntegerSafe -isnot [string] -and $row.BigIntegerUnsafe -ceq '9007199254740992' -and
        $row.Floating -isnot [string] -and $row.Floating -eq 1234.5) 'Numeric precision or JSON number conversion failed.'
    Assert-True ($precision.OutputParameters.'@Return' -ceq '-9007199254740992' -and
        $precision.OutputParameters.'@Amount' -ceq '123.4500' -and
        $precision.OutputParameters.'@Guid' -ceq 'aabbccdd-eeff-0011-2233-445566778899' -and
        $precision.OutputParameters.'@Bytes' -ceq 'AAH/') 'Output and return values did not use shared conversion.'
}
finally { [System.Threading.Thread]::CurrentThread.CurrentCulture = $previousCulture }

Write-Output 'PASS: AzureSql construction, failed-signal validation, immutable plan, and JSON precision contracts.'
