using module SignalGraph

$ErrorActionPreference = 'Stop'
$foundation = Join-Path $PSScriptRoot '../../../../../SovereignTrust.Foundation/Src/PowerShell/SovereignTrust.Foundation.psd1'
$manifest = Join-Path $PSScriptRoot '../PowerShell/Data_AzureSql.psd1'
Import-Module (Resolve-Path $foundation).ProviderPath -Force
Import-Module (Resolve-Path $manifest).ProviderPath -Force
. "$PSScriptRoot/SqlClientDecimalFixture.ps1"

class AzureSqlTestReader : System.IDisposable {
    [object[]]$Sets
    [int]$SetIndex = 0
    [int]$RowIndex = -1
    [int]$FieldCount
    [int]$RecordsAffected = -1
    [object]$Command
    [bool]$Disposed
    [bool]$ThrowOnRead
    [bool]$ThrowOnDispose
    [bool]$ThrowOnGetSqlDecimal
    [bool]$ThrowOnGetSqlValue
    [int]$SqlDecimalCalls
    [int]$SqlValueCalls
    AzureSqlTestReader([object[]]$sets, [int]$affected) {
        $this.Sets = $sets
        $this.FieldCount = $sets[0].Columns.Count
        $this.RecordsAffected = $affected
    }
    [object[]] GetColumnSchema() { return $this.Sets[$this.SetIndex].Columns }
    [string] GetName([int]$ordinal) { return $this.Sets[$this.SetIndex].Columns[$ordinal].ColumnName }
    [Type] GetFieldType([int]$ordinal) { return [int] }
    [object] GetValue([int]$ordinal) {
        $value = $this.Sets[$this.SetIndex].Rows[$this.RowIndex].Values[$ordinal]
        if ($value -is [System.Data.SqlTypes.SqlDecimal]) {
            throw 'synthetic CLR decimal overflow: use the SQL-specific getter'
        }
        # A typed method return is one cell even when that cell is a byte array.
        return $value
    }
    [bool] IsDBNull([int]$ordinal) {
        $value = $this.Sets[$this.SetIndex].Rows[$this.RowIndex].Values[$ordinal]
        return $null -eq $value -or $value -is [DBNull] -or
            ($value -is [System.Data.SqlTypes.INullable] -and $value.IsNull)
    }
    [System.Data.SqlTypes.SqlDecimal] GetSqlDecimal([int]$ordinal) {
        $this.SqlDecimalCalls++
        if ($this.ThrowOnGetSqlDecimal) { throw 'synthetic secret decimal getter failure' }
        return $this.Sets[$this.SetIndex].Rows[$this.RowIndex].Values[$ordinal]
    }
    [object] GetSqlValue([int]$ordinal) {
        $this.SqlValueCalls++
        if ($this.ThrowOnGetSqlValue) { throw 'synthetic secret sql variant getter failure' }
        $value = $this.Sets[$this.SetIndex].Rows[$this.RowIndex].Values[$ordinal]
        if ($value -is [byte[]]) { return [System.Data.SqlTypes.SqlBinary]::new($value) }
        return $value
    }
    [bool] Read() {
        if ($this.ThrowOnRead) { throw 'synthetic secret reader failure' }
        $this.RowIndex++
        return $this.RowIndex -lt $this.Sets[$this.SetIndex].Rows.Count
    }
    [bool] NextResult() {
        $this.SetIndex++
        if ($this.SetIndex -ge $this.Sets.Count) { return $false }
        $this.RowIndex = -1
        $this.FieldCount = $this.Sets[$this.SetIndex].Columns.Count
        return $true
    }
    [void] Dispose() {
        $this.Disposed = $true
        $null = $this.Command.Session.Events.Add('reader dispose')
        foreach ($parameter in $this.Command.Parameters) {
            if ($this.Command.OutputOnClose.Contains($parameter.ParameterName)) {
                $parameter.Value = $this.Command.OutputOnClose[$parameter.ParameterName]
            }
        }
        if ($null -ne $this.Command.AfterReaderClose) { & $this.Command.AfterReaderClose $this.Command }
        if ($this.ThrowOnDispose) { throw 'synthetic secret reader cleanup failure' }
    }
}
class AzureSqlTestCommand : System.IDisposable {
    [object]$Transaction
    [System.Data.CommandType]$CommandType
    [string]$CommandText
    [int]$CommandTimeout
    [System.Collections.ArrayList]$Parameters = [System.Collections.ArrayList]::new()
    [object]$Reader
    [object]$Session
    [int]$NonQueryResult
    [int]$ReaderCalls
    [int]$NonQueryCalls
    [bool]$Disposed
    [bool]$ThrowOnNonQuery
    [bool]$ThrowOnDispose
    [scriptblock]$AfterExecute
    [scriptblock]$AfterReaderClose
    [object]$BrokenParameter
    [hashtable]$OutputOnClose = @{}
    [object] ExecuteReader() { $this.ReaderCalls++; $null = $this.Session.Events.Add('execute reader'); $this.Reader.Command = $this; return $this.Reader }
    [int] ExecuteNonQuery() {
        $this.NonQueryCalls++
        $null = $this.Session.Events.Add('execute nonquery')
        if ($this.ThrowOnNonQuery) { throw 'synthetic provider failure' }
        if ($null -ne $this.AfterExecute) { & $this.AfterExecute $this }
        return $this.NonQueryResult
    }
    [void] Dispose() { $this.Disposed = $true; $null = $this.Session.Events.Add('command dispose'); if ($this.ThrowOnDispose) { throw 'synthetic secret cleanup failure' } }
}
class AzureSqlTestTransaction : System.IDisposable {
    [bool]$Committed
    [bool]$RolledBack
    [bool]$Disposed
    [bool]$ThrowOnCommit
    [bool]$ThrowOnRollback
    [object]$Session
    AzureSqlTestTransaction([object]$session) { $this.Session = $session }
    [void] Commit() {
        $null = $this.Session.Events.Add('commit')
        if ($this.ThrowOnCommit) { throw 'synthetic secret commit failure' }
        $this.Committed = $true
    }
    [void] Rollback() {
        $null = $this.Session.Events.Add('rollback')
        $this.RolledBack = $true
        if ($this.ThrowOnRollback) { throw 'synthetic secret rollback failure' }
    }
    [void] Dispose() { $this.Disposed = $true; $null = $this.Session.Events.Add('transaction dispose') }
}
class AzureSqlTestSession : System.IDisposable {
    [object]$Command
    [object]$Transaction
    [System.Collections.ArrayList]$Events = [System.Collections.ArrayList]::new()
    [bool]$Opened
    [bool]$Disposed
    [bool]$ThrowOnDispose
    [bool]$ThrowOnOpen
    [bool]$ThrowOnBegin
    AzureSqlTestSession([object]$command) { $this.Command = $command; $this.Command.Session = $this; $this.Transaction = [AzureSqlTestTransaction]::new($this) }
    [void] Open() { $this.Opened = $true; $null = $this.Events.Add('open'); if ($this.ThrowOnOpen) { throw 'synthetic secret open failure' } }
    [object] BeginTransaction() { $null = $this.Events.Add('begin'); if ($this.ThrowOnBegin) { throw 'synthetic secret begin failure' }; return $this.Transaction }
    [object] CreateCommand() { return $this.Command }
    [void] Dispose() { $this.Disposed = $true; $null = $this.Events.Add('session dispose'); if ($this.ThrowOnDispose) { throw 'synthetic secret session cleanup failure' } }
}
class AzureSqlBrokenDecimalParameter {
    [string]$ParameterName = '@Out'
    [System.Data.ParameterDirection]$Direction = [System.Data.ParameterDirection]::Output
    [System.Data.SqlDbType]$SqlDbType = [System.Data.SqlDbType]::Decimal
    [int]$SqlValueCalls
    [object] get_SqlValue() { $this.SqlValueCalls++; throw 'synthetic secret output getter failure' }
}

function Assert([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function New-Column([string]$name, [string]$type) {
    return [pscustomobject]@{ ColumnName=$name; DataTypeName=$type; AllowDBNull=$false; NumericPrecision=$null; NumericScale=$null }
}
function New-TestCase([object[]]$sets, [int]$affected = -1) {
    $command = [AzureSqlTestCommand]::new()
    if ($null -ne $sets) { $command.Reader = [AzureSqlTestReader]::new($sets, $affected) }
    return [AzureSqlTestSession]::new($command)
}
function New-NamedSet([string[]]$names, [object[]]$values = $null) {
    $columns = [System.Collections.Generic.List[object]]::new()
    for ($ordinal = 0; $ordinal -lt $names.Count; $ordinal++) {
        $column = New-Column $names[$ordinal] 'int'
        $column.AllowDBNull = ($ordinal % 2 -eq 0)
        $column.NumericPrecision = 18
        $column.NumericScale = 2
        $columns.Add($column)
    }
    $rows = @()
    if ($null -ne $values) { $rows = @([pscustomobject]@{ Values=$values }) }
    return [pscustomobject]@{ Columns=$columns.ToArray(); Rows=$rows }
}
function Assert-MappedSet([object]$set, [string[]]$names, [string[]]$sources, [object[]]$values = $null) {
    Assert ($set.Columns.Count -eq $names.Count) 'Result-set column count changed.'
    for ($ordinal = 0; $ordinal -lt $names.Count; $ordinal++) {
        $column = $set.Columns[$ordinal]
        Assert ([string]::Equals($column.Name, $names[$ordinal], [StringComparison]::Ordinal) -and
            [string]::Equals($column.SourceName, $sources[$ordinal], [StringComparison]::Ordinal) -and
            $column.Ordinal -eq $ordinal -and $column.Type -eq 'int' -and
            $column.AllowDBNull -eq ($ordinal % 2 -eq 0) -and
            $column.Precision -eq 18 -and $column.Scale -eq 2) "Column metadata mismatch at ordinal $ordinal."
    }
    if ($null -eq $values) {
        Assert ($set.Rows.Count -eq 0) 'Empty result set gained rows.'
        return
    }
    Assert ($set.Rows.Count -eq 1) 'Populated result set lost its row.'
    $keys = @($set.Rows[0].PSObject.Properties.Name)
    Assert ($keys.Count -eq $names.Count) 'Row property count changed.'
    for ($ordinal = 0; $ordinal -lt $names.Count; $ordinal++) {
        Assert ([string]::Equals($keys[$ordinal], $names[$ordinal], [StringComparison]::Ordinal) -and
            $set.Rows[0].PSObject.Properties[$names[$ordinal]].Value -eq $values[$ordinal]) "Row value mismatch at ordinal $ordinal."
    }
}

$module = Get-Module Data_AzureSql
& $module {
    $script:TestSessions = [System.Collections.Generic.Queue[object]]::new()
    Set-Item Function:script:New-AzureSqlSession -Value {
        param($Adapter)
        if ($Adapter.Configuration.Resource -ne 'synthetic-resource') { throw 'Hydrated jacket did not reach factory.' }
        return $script:TestSessions.Dequeue()
    }
}
function Invoke-Case([string]$activity, [object]$config, [object]$session) {
    & $module { $script:TestSessions.Enqueue($args[0]) } $session
    $plan = [pscustomobject]@{ Config = $config }
    $before = ConvertTo-Json -InputObject $plan -Depth 100 -Compress
    $result = $adapter.Invoke('FusionDatabase', $activity, $conduction, $plan, $item)
    Assert ((ConvertTo-Json -InputObject $plan -Depth 100 -Compress) -ceq $before) 'Invocation mutated Plan.Config.'
    Assert ($session.Disposed) 'Connection was not disposed.'
    return $result
}

$adapter = Resolve-Data_AzureSql
$null = $adapter.Construct([pscustomobject]@{ Resource='synthetic-resource'; CommandTimeoutSeconds=41 })
$conduction = [Signal]::Start('AzureSqlBoundary.Conduction') | Select-Object -Last 1
$item = [Signal]::Start('AzureSqlBoundary.Item') | Select-Object -Last 1
$empty = [pscustomobject]@{ Columns=@((New-Column 'Id' 'int')); Rows=@() }
$populated = [pscustomobject]@{ Columns=@((New-Column 'Name' 'nvarchar')); Rows=@([pscustomobject]@{ Values=@('Museum') }) }

$writeSession = New-TestCase @($empty, $populated) 2
$writeSession.Command.OutputOnClose = @{ '@Out'=7; '@Return'=0 }
$writeConfig = [pscustomobject]@{
    Procedure='dbo.Ingest'; Content=@([pscustomobject]@{ Id='1' }); ColumnSchema=@{ Id='int' }
    PayloadParameter='@Json'; Parameters=@(
        @{ Name='@Out'; SqlDbType='Int'; Direction='Output' },
        @{ Name='@Return'; SqlDbType='Int'; Direction='ReturnValue' }
    ); CommandTimeoutSeconds=12
}
$write = Invoke-Case Write $writeConfig $writeSession
Assert (-not $write.Failure()) 'Write failed.'
$written = $write.GetResult() | ConvertFrom-Json -Depth 100
Assert ($writeSession.Command.CommandType -eq [System.Data.CommandType]::StoredProcedure -and
    $writeSession.Command.CommandText -eq 'dbo.Ingest' -and $writeSession.Command.CommandTimeout -eq 12) 'Write command selection or timeout failed.'
$payload = @($writeSession.Command.Parameters | Where-Object ParameterName -eq '@Json')[0]
Assert ($payload.SqlDbType -eq [System.Data.SqlDbType]::NVarChar -and $payload.Size -eq -1 -and
    $payload.Value -eq '[{"Id":1}]' -and $writeConfig.Content[0].Id -eq '1') 'Write payload binding or input immutability failed.'
Assert ($written.RowsAffected -eq 2 -and $written.ResultSets.Count -eq 2 -and
    $written.OutputParameters.'@Out' -eq 7 -and $written.OutputParameters.'@Return' -eq 0) 'Write results or output values failed.'
Assert ($writeSession.Command.Reader.Disposed -and $writeSession.Command.Disposed) 'Write resources were not disposed.'
Assert ($writeSession.Opened -and $writeSession.Transaction.Committed -and
    $writeSession.Command.Transaction -eq $writeSession.Transaction -and
    ($writeSession.Events -join ',') -eq 'open,begin,execute reader,reader dispose,command dispose,commit,transaction dispose,session dispose') 'Write transaction ordering or enlistment failed.'

# Reproduce the packaged provider's decimal output buffer rather than supplying
# a preconverted string or CLR Decimal. Its Value getter overflows at 38 digits.
$decimalColumns = @((New-Column 'Amount' 'decimal'))
$decimalValues = @(
    [System.Data.SqlTypes.SqlDecimal]::Parse('12345678901234567890123456789012345678'),
    [System.Data.SqlTypes.SqlDecimal]::Parse('-12345678901234567890123456789012345678'),
    [System.Data.SqlTypes.SqlDecimal]::Parse('0.1234567890123456789012345678901234567'),
    [System.Data.SqlTypes.SqlDecimal]::Parse('123.4500'),
    [DBNull]::Value
)
$decimalRows = @($decimalValues | ForEach-Object { [pscustomobject]@{ Values=@($_) } })
$decimalSet = [pscustomobject]@{ Columns=$decimalColumns; Rows=$decimalRows }
$variantSet = [pscustomobject]@{
    Columns=@((New-Column 'VariantAmount' 'sql_variant'))
    Rows=@(
        [pscustomobject]@{ Values=@([System.Data.SqlTypes.SqlDecimal]::Parse('987654321098765432109876543210.1200')) },
        [pscustomobject]@{ Values=@([int]7) }
    )
}
$decimalSession = New-TestCase @($decimalSet, $variantSet) 1
$decimalSession.Command.AfterReaderClose = {
    param($command)
    foreach ($parameter in $command.Parameters) {
        switch ($parameter.ParameterName) {
            '@OutPositive' { Set-TestSqlDecimalOutputBuffer $parameter '12345678901234567890123456789012345678' }
            '@OutNegative' { Set-TestSqlDecimalOutputBuffer $parameter '-12345678901234567890123456789012345678' }
            '@InOut' { Set-TestSqlDecimalOutputBuffer $parameter '123.4500' }
            '@InOutHigh' { Set-TestSqlDecimalOutputBuffer $parameter '0.1234567890123456789012345678901234567' }
            '@Null' { Set-TestSqlDecimalOutputBuffer $parameter $null }
            '@Return' { $parameter.Value = 17 }
        }
    }
}
$decimalPlan = [pscustomobject]@{ Procedure='dbo.DecimalResults'; Content=@(); Parameters=@(
    @{ Name='@OutPositive'; SqlDbType='Decimal'; Direction='Output'; Precision=38; Scale=0 },
    @{ Name='@OutNegative'; SqlDbType='Decimal'; Direction='Output'; Precision=38; Scale=0 },
    @{ Name='@InOut'; SqlDbType='Decimal'; Direction='InputOutput'; Precision=9; Scale=4; Value=[decimal]1 },
    @{ Name='@InOutHigh'; SqlDbType='Decimal'; Direction='InputOutput'; Precision=38; Scale=37; Value=[decimal]1 },
    @{ Name='@Null'; SqlDbType='Decimal'; Direction='Output'; Precision=38; Scale=0 },
    @{ Name='@Return'; SqlDbType='Int'; Direction='ReturnValue' }
) }
$previousCulture = [Threading.Thread]::CurrentThread.CurrentCulture
try {
    [Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::GetCultureInfo('fr-FR')
    $decimalResult = Invoke-Case Write $decimalPlan $decimalSession
}
finally { [Threading.Thread]::CurrentThread.CurrentCulture = $previousCulture }
Assert (-not $decimalResult.Failure() -and $decimalSession.Transaction.Committed -and
    $decimalSession.Command.Reader.Disposed -and $decimalSession.Command.Reader.SqlDecimalCalls -eq 4 -and
    $decimalSession.Command.Reader.SqlValueCalls -eq 2) 'Decimal reader selection or transaction commit failed.'
$decimalEnvelope = ConvertFrom-Json -InputObject $decimalResult.GetResult() -Depth 100 -DateKind String
Assert ($decimalEnvelope.ResultSets[0].Rows[0].Amount -ceq '12345678901234567890123456789012345678' -and
    $decimalEnvelope.ResultSets[0].Rows[1].Amount -ceq '-12345678901234567890123456789012345678' -and
    $decimalEnvelope.ResultSets[0].Rows[2].Amount -ceq '0.1234567890123456789012345678901234567' -and
    $decimalEnvelope.ResultSets[0].Rows[3].Amount -ceq '123.4500' -and
    $null -eq $decimalEnvelope.ResultSets[0].Rows[4].Amount -and
    $decimalEnvelope.ResultSets[1].Rows[0].VariantAmount -ceq '987654321098765432109876543210.1200' -and
    $decimalEnvelope.ResultSets[1].Rows[1].VariantAmount -eq 7) 'Decimal and sql_variant rows lost value or scale.'
Assert ($decimalEnvelope.OutputParameters.'@OutPositive' -ceq '12345678901234567890123456789012345678' -and
    $decimalEnvelope.OutputParameters.'@OutNegative' -ceq '-12345678901234567890123456789012345678' -and
    $decimalEnvelope.OutputParameters.'@InOut' -ceq '123.4500' -and
    $decimalEnvelope.OutputParameters.'@InOutHigh' -ceq '0.1234567890123456789012345678901234567' -and
    $null -eq $decimalEnvelope.OutputParameters.'@Null' -and
    $decimalEnvelope.OutputParameters.'@Return' -eq 17) 'Provider-backed output or InputOutput decimal was corrupted.'
$bufferedOutput = @($decimalSession.Command.Parameters | Where-Object ParameterName -eq '@OutPositive')[0]
$overflowObserved = $false
try { $null = $bufferedOutput.get_Value() } catch { $overflowObserved = $_.Exception.Message -match 'overflow' }
Assert ($overflowObserved -and $bufferedOutput.get_SqlValue() -is [System.Data.SqlTypes.SqlDecimal] -and
    ($decimalSession.Events -join ',') -match 'reader dispose,command dispose,commit') 'Packaged-provider output-buffer reproduction was not exercised.'

$binaryRows = @(
    [pscustomobject]@{ Values=,([byte[]]@()) },
    [pscustomobject]@{ Values=,([byte[]]@(1)) },
    [pscustomobject]@{ Values=,([byte[]]@(1,2,3)) },
    [pscustomobject]@{ Values=@([DBNull]::Value) }
)
$binarySet = [pscustomobject]@{ Columns=@((New-Column 'Payload' 'varbinary')); Rows=$binaryRows }
$binaryVariantSet = [pscustomobject]@{ Columns=@((New-Column 'VariantPayload' 'sql_variant')); Rows=$binaryRows }
$binarySession = New-TestCase @($binarySet, $binaryVariantSet) 1
$binarySession.Command.OutputOnClose = @{
    '@OutEmpty'=[byte[]]@(); '@OutOne'=[byte[]]@(1); '@OutMany'=[byte[]]@(1,2,3); '@OutNull'=[DBNull]::Value
    '@InOutEmpty'=[byte[]]@(); '@InOutOne'=[byte[]]@(1); '@InOutMany'=[byte[]]@(1,2,3); '@InOutNull'=[DBNull]::Value
    '@Return'=0
}
$binaryParameters = @(
    @{ Name='@OutEmpty'; SqlDbType='VarBinary'; Direction='Output'; Size=8 },
    @{ Name='@OutOne'; SqlDbType='VarBinary'; Direction='Output'; Size=8 },
    @{ Name='@OutMany'; SqlDbType='VarBinary'; Direction='Output'; Size=8 },
    @{ Name='@OutNull'; SqlDbType='VarBinary'; Direction='Output'; Size=8 },
    @{ Name='@InOutEmpty'; SqlDbType='VarBinary'; Direction='InputOutput'; Size=8; Value=[byte[]]@(9) },
    @{ Name='@InOutOne'; SqlDbType='VarBinary'; Direction='InputOutput'; Size=8; Value=[byte[]]@(9) },
    @{ Name='@InOutMany'; SqlDbType='VarBinary'; Direction='InputOutput'; Size=8; Value=[byte[]]@(9) },
    @{ Name='@InOutNull'; SqlDbType='VarBinary'; Direction='InputOutput'; Size=8; Value=[DBNull]::Value },
    @{ Name='@Return'; SqlDbType='Int'; Direction='ReturnValue' }
)
& $module {
    param($session)
    $script:BinaryOriginalConverter = (Get-Command ConvertTo-AzureSqlJsonResult -CommandType Function).ScriptBlock
    $script:BinarySession = $session
    $script:BinarySerializedJson = $null
    Set-Item Function:script:ConvertTo-AzureSqlJsonResult -Value {
        [CmdletBinding()]
        param([string]$Operation, [object]$Value, [Nullable[int]]$DefaultRowsAffected = $null, [object]$OutputParameters = $null)
        $json = & $script:BinaryOriginalConverter @PSBoundParameters
        $script:BinarySerializedJson = $json
        $null = $script:BinarySession.Events.Add('serialized')
        return $json
    }
} $binarySession
try {
    $binaryResult = Invoke-Case Write ([pscustomobject]@{ Procedure='dbo.BinaryResults'; Content=@(); Parameters=$binaryParameters }) $binarySession
    $serializedBinaryJson = & $module { $script:BinarySerializedJson }
}
finally {
    & $module {
        Set-Item Function:script:ConvertTo-AzureSqlJsonResult -Value $script:BinaryOriginalConverter
        $script:BinaryOriginalConverter = $null
        $script:BinarySession = $null
        $script:BinarySerializedJson = $null
    }
}
Assert (-not $binaryResult.Failure() -and $binarySession.Transaction.Committed -and
    $serializedBinaryJson -ceq $binaryResult.GetResult() -and
    ($binarySession.Events -join ',') -match 'reader dispose,serialized,command dispose,commit') 'Binary envelope was not fully serialized before commit.'
$binaryEnvelope = ConvertFrom-Json -InputObject $serializedBinaryJson -Depth 100 -DateKind String
foreach ($columnName in @('Payload', 'VariantPayload')) {
    $set = if ($columnName -eq 'Payload') { $binaryEnvelope.ResultSets[0] } else { $binaryEnvelope.ResultSets[1] }
    Assert ($set.Rows[0].$columnName -is [string] -and $set.Rows[0].$columnName -ceq '' -and
        $set.Rows[1].$columnName -is [string] -and $set.Rows[1].$columnName -ceq 'AQ==' -and
        $set.Rows[2].$columnName -is [string] -and $set.Rows[2].$columnName -ceq 'AQID' -and
        $null -ne $set.Rows[3].PSObject.Properties[$columnName] -and
        $null -eq $set.Rows[3].$columnName) "Binary $columnName rows lost type or cardinality."
}
foreach ($prefix in @('Out', 'InOut')) {
    $outputs = $binaryEnvelope.OutputParameters
    Assert ($outputs."@$($prefix)Empty" -is [string] -and $outputs."@$($prefix)Empty" -ceq '' -and
        $outputs."@$($prefix)One" -is [string] -and $outputs."@$($prefix)One" -ceq 'AQ==' -and
        $outputs."@$($prefix)Many" -is [string] -and $outputs."@$($prefix)Many" -ceq 'AQID' -and
        $null -ne $outputs.PSObject.Properties["@$($prefix)Null"] -and
        $null -eq $outputs."@$($prefix)Null") "Binary $prefix parameters lost type or cardinality."
}
Assert ($binaryEnvelope.OutputParameters.'@Return' -eq 0 -and
    @($binarySession.Command.Parameters | Where-Object { $_.SqlDbType -eq [System.Data.SqlDbType]::VarBinary }).Count -eq 8 -and
    @($binarySession.Command.Parameters | Where-Object { $_.SqlDbType -eq [System.Data.SqlDbType]::VarBinary -and $_.Size -ne 8 }).Count -eq 0) 'Binary parameter metadata or return code changed.'

$querySession = New-TestCase @($empty, $populated) -1
$query = Invoke-Case Query ([pscustomobject]@{
    CommandText='select @Id'; Parameters=@(@{Name='@Id';SqlDbType='Int';Value=3})
}) $querySession
Assert (-not $query.Failure()) 'Query failed.'
$queried = $query.GetResult() | ConvertFrom-Json -Depth 100
Assert ($querySession.Command.CommandType -eq [System.Data.CommandType]::Text -and
    $querySession.Command.CommandText -eq 'select @Id' -and $querySession.Command.CommandTimeout -eq 41 -and
    $querySession.Command.Parameters[0].Value -eq 3) 'Query text, parameters, or adapter timeout failed.'
Assert ($queried.ResultSets.Count -eq 2 -and $queried.ResultSets[0].Rows.Count -eq 0 -and
    $queried.ResultSets[0].Columns[0].Name -eq 'Id' -and
    $queried.ResultSets[0].Columns[0].Ordinal -eq 0 -and
    $queried.ResultSets[0].Columns[0].AllowDBNull -eq $false -and
    $queried.ResultSets[1].Rows[0].Name -eq 'Museum' -and $null -eq $queried.RowsAffected) 'Query traversal or empty metadata failed.'
Assert ($querySession.Command.Reader.Disposed -and $querySession.Command.Disposed) 'Query resources were not disposed.'
Assert ($querySession.Opened -and ($querySession.Events -join ',') -eq 'open,execute reader,reader dispose,command dispose,session dispose') 'Query acquired an explicit transaction.'

foreach ($count in @(0,-1)) {
    $deleteSession = New-TestCase $null
    $deleteSession.Command.NonQueryResult = $count
    $deleted = Invoke-Case Delete ([pscustomobject]@{ CommandText='delete from dbo.Items where Id=@Id'; Parameters=@{ '@Id'=[int]9 } }) $deleteSession
    Assert (-not $deleted.Failure()) 'Delete failed.'
    $envelope = $deleted.GetResult() | ConvertFrom-Json -Depth 100
    Assert ($deleteSession.Command.CommandType -eq [System.Data.CommandType]::Text -and
        $deleteSession.Command.NonQueryCalls -eq 1 -and $deleteSession.Command.ReaderCalls -eq 0 -and
        $deleteSession.Command.Disposed) 'Delete command path or disposal failed.'
    Assert (($count -eq 0 -and $envelope.RowsAffected -eq 0) -or
        ($count -eq -1 -and $null -eq $envelope.RowsAffected)) 'Delete affected-row semantics failed.'
    Assert ($deleteSession.Transaction.Committed -and $deleteSession.Command.Transaction -eq $deleteSession.Transaction -and
        ($deleteSession.Events -join ',') -eq 'open,begin,execute nonquery,command dispose,commit,transaction dispose,session dispose') 'Delete transaction ordering or enlistment failed.'
}
$defaultPayloadSession = New-TestCase @($empty)
$defaultPayload = Invoke-Case Write ([pscustomobject]@{ Procedure='dbo.Ingest'; Content=@() }) $defaultPayloadSession
Assert (-not $defaultPayload.Failure() -and
    @($defaultPayloadSession.Command.Parameters | Where-Object ParameterName -eq '@Payload').Count -eq 1 -and
    $defaultPayloadSession.Command.Parameters[0].Value -eq '[]') 'Default payload parameter or empty Records binding failed.'

$deleteReaderSession = New-TestCase @($empty, $populated)
$deleteReader = Invoke-Case Delete ([pscustomobject]@{ CommandText='delete output deleted.Id from dbo.Items'; ExpectResultSets=$true }) $deleteReaderSession
Assert (-not $deleteReader.Failure() -and $deleteReaderSession.Command.ReaderCalls -eq 1 -and
    $deleteReaderSession.Command.NonQueryCalls -eq 0 -and
    ($deleteReader.GetResult() | ConvertFrom-Json).ResultSets.Count -eq 2) 'Delete result-set path failed.'

# Provider names are not unique. The double stores row cells by ordinal so it
# cannot hide overwritten values before the production materializer sees them.
$duplicateSources = @('Id','Id','id','Id_2')
$duplicateNames = @('Id','Id_3','id_4','Id_2')
$duplicateValues = @(11,22,33,44)
$unnamedSources = @('', ' ', 'Column1', 'Column1_2', '', 'Column5')
$unnamedNames = @('Column1_3','Column2','Column1','Column1_2','Column5_2','Column5')
$unnamedValues = @(101,102,103,104,105,106)
$duplicates = New-NamedSet $duplicateSources $duplicateValues
$unnamedEmpty = New-NamedSet $unnamedSources
$unnamedFilled = New-NamedSet $unnamedSources $unnamedValues
$singleUnnamed = New-NamedSet @('') @(9)

$namingQuerySession = New-TestCase @($duplicates, $unnamedEmpty, $unnamedFilled, $singleUnnamed)
$namingQuery = Invoke-Case Query ([pscustomobject]@{ CommandText='select duplicate and unnamed columns' }) $namingQuerySession
Assert (-not $namingQuery.Failure() -and $namingQuery.HasResult()) 'Query naming regression returned a failed signal.'
$namingQueryJson = $namingQuery.GetResult()
$namingQueryEnvelope = $namingQueryJson | ConvertFrom-Json -Depth 100
Assert ($namingQueryEnvelope.Operation -eq 'Query' -and $namingQueryEnvelope.ResultSets.Count -eq 4) 'Query naming result lost the common JSON envelope.'
Assert-MappedSet $namingQueryEnvelope.ResultSets[0] $duplicateNames $duplicateSources $duplicateValues
Assert-MappedSet $namingQueryEnvelope.ResultSets[1] $unnamedNames $unnamedSources
Assert-MappedSet $namingQueryEnvelope.ResultSets[2] $unnamedNames $unnamedSources $unnamedValues
Assert-MappedSet $namingQueryEnvelope.ResultSets[3] @('Column1') @('') @(9)
Assert ($namingQuerySession.Command.Reader.Disposed -and $namingQuerySession.Command.Disposed) 'Query naming resources were not disposed.'

$namingWriteSession = New-TestCase @($unnamedFilled, $duplicates, $unnamedEmpty) 1
$namingWrite = Invoke-Case Write ([pscustomobject]@{ Procedure='dbo.Ingest'; Content=@([pscustomobject]@{Id=1}) }) $namingWriteSession
Assert (-not $namingWrite.Failure() -and $namingWrite.HasResult()) 'Write naming regression returned a failed signal.'
$namingWriteEnvelope = $namingWrite.GetResult() | ConvertFrom-Json -Depth 100
Assert ($namingWriteEnvelope.Operation -eq 'Write' -and $namingWriteEnvelope.RowsAffected -eq 1 -and
    $namingWriteEnvelope.ResultSets.Count -eq 3) 'Write naming result lost the common JSON envelope.'
Assert-MappedSet $namingWriteEnvelope.ResultSets[0] $unnamedNames $unnamedSources $unnamedValues
Assert-MappedSet $namingWriteEnvelope.ResultSets[1] $duplicateNames $duplicateSources $duplicateValues
Assert-MappedSet $namingWriteEnvelope.ResultSets[2] $unnamedNames $unnamedSources

$namingDeleteSession = New-TestCase @($duplicates, $unnamedFilled)
$namingDelete = Invoke-Case Delete ([pscustomobject]@{ CommandText='delete output columns'; ExpectResultSets=$true }) $namingDeleteSession
Assert (-not $namingDelete.Failure() -and $namingDelete.HasResult()) 'Delete reader naming regression returned a failed signal.'
$namingDeleteEnvelope = $namingDelete.GetResult() | ConvertFrom-Json -Depth 100
Assert ($namingDeleteEnvelope.Operation -eq 'Delete' -and $namingDeleteEnvelope.ResultSets.Count -eq 2) 'Delete naming result lost the common JSON envelope.'
Assert-MappedSet $namingDeleteEnvelope.ResultSets[0] $duplicateNames $duplicateSources $duplicateValues
Assert-MappedSet $namingDeleteEnvelope.ResultSets[1] $unnamedNames $unnamedSources $unnamedValues

$failureSession = New-TestCase $null
$failureSession.Command.ThrowOnNonQuery = $true
$failed = Invoke-Case Delete ([pscustomobject]@{ CommandText='delete from dbo.Items' }) $failureSession
Assert ($failed.Failure() -and $failureSession.Command.NonQueryCalls -eq 1 -and
    $failureSession.Command.Disposed -and
    ($failed.GetEntries() | Out-String) -notmatch 'synthetic provider failure') 'Failed Delete retried, leaked resources, or exposed provider details.'
Assert ($failureSession.Transaction.RolledBack -and -not $failureSession.Transaction.Committed -and
    $failureSession.Transaction.Disposed -and
    ($failureSession.Events -join ',') -match 'rollback,transaction dispose,session dispose$') 'Failed Delete did not roll back and dispose.'

$conversionSession = New-TestCase @((New-NamedSet @('Unsafe') @([System.IO.MemoryStream]::new())))
$conversion = Invoke-Case Write ([pscustomobject]@{ Procedure='dbo.Ingest'; Content=@() }) $conversionSession
Assert ($conversion.Failure() -and $conversionSession.Transaction.RolledBack -and
    -not $conversionSession.Transaction.Committed -and $conversionSession.Command.Reader.Disposed -and
    $conversionSession.Command.Disposed -and
    ($conversion.GetEntries() | Out-String) -notmatch 'synthetic secret') 'Row conversion failure did not roll back or leaked details.'

$decimalGetterSession = New-TestCase @($decimalSet)
$decimalGetterSession.Command.Reader.ThrowOnGetSqlDecimal = $true
$decimalGetter = Invoke-Case Write ([pscustomobject]@{ Procedure='dbo.DecimalResults'; Content=@() }) $decimalGetterSession
Assert ($decimalGetter.Failure() -and $decimalGetterSession.Command.Reader.SqlDecimalCalls -eq 1 -and
    $decimalGetterSession.Transaction.RolledBack -and -not $decimalGetterSession.Transaction.Committed -and
    $decimalGetterSession.Command.Reader.Disposed -and $decimalGetterSession.Command.Disposed -and
    ($decimalGetter.GetEntries() | Out-String) -notmatch 'synthetic secret') 'Decimal reader getter failure did not roll back safely.'

$variantGetterSession = New-TestCase @($variantSet)
$variantGetterSession.Command.Reader.ThrowOnGetSqlValue = $true
$variantGetter = Invoke-Case Write ([pscustomobject]@{ Procedure='dbo.DecimalResults'; Content=@() }) $variantGetterSession
Assert ($variantGetter.Failure() -and $variantGetterSession.Command.Reader.SqlValueCalls -eq 1 -and
    $variantGetterSession.Transaction.RolledBack -and -not $variantGetterSession.Transaction.Committed -and
    ($variantGetter.GetEntries() | Out-String) -notmatch 'synthetic secret') 'sql_variant decimal retrieval failure did not roll back safely.'

$outputGetterSession = New-TestCase @($empty)
$outputGetterSession.Command.AfterReaderClose = {
    param($command)
    $command.Parameters.Clear()
    $command.BrokenParameter = [AzureSqlBrokenDecimalParameter]::new()
    $null = $command.Parameters.Add($command.BrokenParameter)
}
$outputGetter = Invoke-Case Write ([pscustomobject]@{ Procedure='dbo.DecimalResults'; Content=@() }) $outputGetterSession
Assert ($outputGetter.Failure() -and $outputGetterSession.Transaction.RolledBack -and
    -not $outputGetterSession.Transaction.Committed -and $outputGetterSession.Command.Reader.Disposed -and
    $outputGetterSession.Command.BrokenParameter.SqlValueCalls -eq 1 -and
    ($outputGetter.GetEntries() | Out-String) -notmatch 'synthetic secret') 'Decimal output getter failure became a successful null.'

$outputSession = New-TestCase @($empty)
$outputSession.Command.OutputOnClose = @{ '@Out'=[System.IO.MemoryStream]::new() }
$output = Invoke-Case Write ([pscustomobject]@{
    Procedure='dbo.Ingest'; Content=@(); Parameters=@(@{ Name='@Out'; SqlDbType='Int'; Direction='Output' })
}) $outputSession
Assert ($output.Failure() -and $outputSession.Transaction.RolledBack -and
    -not $outputSession.Transaction.Committed -and
    ($output.GetEntries() | Out-String) -notmatch 'synthetic secret') 'Output conversion failure did not roll back or leaked details.'

$commitSession = New-TestCase $null
$commitSession.Command.NonQueryResult = 1
$commitSession.Transaction.ThrowOnCommit = $true
$commitSession.Transaction.ThrowOnRollback = $true
$commitFailure = Invoke-Case Delete ([pscustomobject]@{ CommandText='delete from dbo.Items' }) $commitSession
Assert ($commitFailure.Failure() -and -not $commitSession.Transaction.Committed -and
    $commitSession.Transaction.RolledBack -and $commitSession.Transaction.Disposed -and
    ($commitFailure.GetEntries() | Out-String) -match 'outcome is uncertain' -and
    ($commitFailure.GetEntries() | Out-String) -notmatch 'synthetic secret') 'Commit and rollback failure handling is unsafe.'

$cleanupSession = New-TestCase $null
$cleanupSession.Command.ThrowOnDispose = $true
$cleanupFailure = Invoke-Case Delete ([pscustomobject]@{ CommandText='delete from dbo.Items' }) $cleanupSession
Assert ($cleanupFailure.Failure() -and $cleanupSession.Transaction.RolledBack -and
    -not $cleanupSession.Transaction.Committed -and $cleanupSession.Disposed -and
    ($cleanupFailure.GetEntries() | Out-String) -notmatch 'synthetic secret') 'Command cleanup failure did not roll back safely.'

$readerFailureSession = New-TestCase @($empty)
$readerFailureSession.Command.Reader.ThrowOnRead = $true
$readerFailureSession.Command.Reader.ThrowOnDispose = $true
$readerFailure = Invoke-Case Write ([pscustomobject]@{ Procedure='dbo.Ingest'; Content=@() }) $readerFailureSession
Assert ($readerFailure.Failure() -and $readerFailureSession.Transaction.RolledBack -and
    $readerFailureSession.Command.Reader.Disposed -and $readerFailureSession.Command.Disposed -and
    ($readerFailure.GetEntries() | Out-String) -notmatch 'synthetic secret') 'Reader failure and cleanup did not preserve rollback.'

$openFailureSession = New-TestCase $null
$openFailureSession.ThrowOnOpen = $true
$openFailure = Invoke-Case Delete ([pscustomobject]@{ CommandText='delete from dbo.Items' }) $openFailureSession
Assert ($openFailure.Failure() -and $openFailureSession.Disposed -and
    -not $openFailureSession.Transaction.Committed -and
    ($openFailure.GetEntries() | Out-String) -notmatch 'synthetic secret') 'Open failure did not dispose safely.'

$beginFailureSession = New-TestCase $null
$beginFailureSession.ThrowOnBegin = $true
$beginFailure = Invoke-Case Delete ([pscustomobject]@{ CommandText='delete from dbo.Items' }) $beginFailureSession
Assert ($beginFailure.Failure() -and $beginFailureSession.Disposed -and
    -not $beginFailureSession.Transaction.Committed -and
    ($beginFailure.GetEntries() | Out-String) -notmatch 'synthetic secret') 'Begin failure did not dispose safely.'

$serializationSession = New-TestCase $null
& $module { Set-Item Function:script:ConvertTo-Json -Value { throw 'synthetic secret serialization failure' } }
try {
    $serializationFailure = Invoke-Case Delete ([pscustomobject]@{ CommandText='delete from dbo.Items' }) $serializationSession
}
finally {
    & $module {
        Set-Item Function:script:ConvertTo-Json -Value {
            param($InputObject, $Depth, [switch]$Compress)
            Microsoft.PowerShell.Utility\ConvertTo-Json -InputObject $InputObject -Depth $Depth -Compress:$Compress
        }
    }
}
Assert ($serializationFailure.Failure() -and $serializationSession.Transaction.RolledBack -and
    -not $serializationSession.Transaction.Committed -and
    ($serializationFailure.GetEntries() | Out-String) -notmatch 'synthetic secret') 'Serialization failure did not roll back safely.'

$postCommitCleanupSession = New-TestCase $null
$postCommitCleanupSession.ThrowOnDispose = $true
$postCommitCleanup = Invoke-Case Delete ([pscustomobject]@{ CommandText='delete from dbo.Items' }) $postCommitCleanupSession
Assert ($postCommitCleanup.Failure() -and $postCommitCleanupSession.Transaction.Committed -and
    ($postCommitCleanup.GetEntries() | Out-String) -match 'committed, but cleanup failed' -and
    ($postCommitCleanup.GetEntries() | Out-String) -notmatch 'synthetic secret') 'Committed cleanup failure was reported inaccurately.'

$optOutSession = New-TestCase @($empty)
$optOut = Invoke-Case Write ([pscustomobject]@{ Procedure='dbo.ExternalTransaction'; Content=@(); TransactionMode='None' }) $optOutSession
Assert (-not $optOut.Failure() -and $null -eq $optOutSession.Command.Transaction -and
    ($optOutSession.Events -join ',') -notmatch 'begin|commit|rollback') 'Stored-procedure transaction opt-out failed.'
$invalidOptOutPlan = [pscustomobject]@{ Config=[pscustomobject]@{ CommandText='delete from dbo.Items'; TransactionMode='None' } }
$invalidOptOut = $adapter.Invoke('FusionDatabase', 'Delete', $conduction, $invalidOptOutPlan, $item)
Assert ($invalidOptOut.Failure()) 'Delete accepted the transaction opt-out.'

$timeoutSession = New-TestCase @($empty)
$invalidTimeout = Invoke-Case Query ([pscustomobject]@{ CommandText='select 1'; CommandTimeoutSeconds=0 }) $timeoutSession
Assert ($invalidTimeout.Failure() -and $timeoutSession.Command.Disposed) 'Invalid timeout was accepted or command leaked.'

Assert ((Get-Command New-AzureSqlSession -ErrorAction SilentlyContinue) -eq $null) 'Internal factory was exported.'
Write-Output 'PASS: Write, Query, Delete paths; schema, transaction ordering, rollback, opt-out, sanitized failures, and disposal.'
