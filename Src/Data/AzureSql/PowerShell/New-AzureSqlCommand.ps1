function Get-AzureSqlCommandTimeout {
    param([object]$Adapter, [object]$Config)
    $source = $null
    if (Test-AzureSqlObjectMember $Config 'CommandTimeoutSeconds') {
        $source = Get-AzureSqlObjectValue $Config 'CommandTimeoutSeconds'
    }
    elseif (Test-AzureSqlObjectMember $Adapter.Configuration 'CommandTimeoutSeconds') {
        $source = Get-AzureSqlObjectValue $Adapter.Configuration 'CommandTimeoutSeconds'
    }
    else { return 30 }
    $seconds = 0
    if ($null -eq $source -or $source -is [bool] -or
        -not [int]::TryParse([string]$source, [ref]$seconds) -or
        $seconds -lt 1 -or $seconds -gt 86400) {
        throw 'CommandTimeoutSeconds must be an integer between 1 and 86400.'
    }
    return $seconds
}

function New-AzureSqlCommand {
    param([object]$Session, [object]$Adapter, [object]$Config,
        [System.Data.CommandType]$CommandType, [string]$CommandText, [object]$Transaction = $null)
    $command = $Session.CreateCommand()
    if ($null -eq $command) { throw 'Azure SQL session returned no command.' }
    try {
        if ($null -ne $Transaction) { $command.Transaction = $Transaction }
        $command.CommandType = $CommandType
        $command.CommandText = $CommandText
        $command.CommandTimeout = Get-AzureSqlCommandTimeout -Adapter $Adapter -Config $Config
        Add-AzureSqlParameters -Command $command -Parameters (Get-AzureSqlObjectValue $Config 'Parameters')
        return $command
    }
    catch {
        if ($command -is [System.IDisposable]) { try { $command.Dispose() } catch {} }
        throw
    }
}

function Get-AzureSqlOutputParameters {
    param([object]$Command)
    $values = [ordered]@{}
    foreach ($parameter in $Command.Parameters) {
        if ($parameter.Direction -ne [System.Data.ParameterDirection]::Input) {
            # PowerShell property syntax can turn a provider getter exception into
            # null. Calling the getter as a method makes retrieval failure fatal.
            if ($parameter.SqlDbType -eq [System.Data.SqlDbType]::Decimal) {
                $value = $parameter.get_SqlValue()
            }
            else { $value = $parameter.get_Value() }
            $values[$parameter.ParameterName] = ConvertTo-AzureSqlJsonValue $value
        }
    }
    return $values
}

function Read-AzureSqlResultSets {
    param([object]$Reader)
    $sets = [System.Collections.Generic.List[object]]::new()
    $index = 0
    do {
        $schema = $Reader.GetColumnSchema()
        $columns = [System.Collections.Generic.List[object]]::new()
        # Reserve every provider name first so a generated key cannot take a
        # name belonging to a later column in this result set.
        $sourceNames = [object[]]::new($Reader.FieldCount)
        $jsonNames = [string[]]::new($Reader.FieldCount)
        $reserved = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        $assigned = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        for ($ordinal = 0; $ordinal -lt $Reader.FieldCount; $ordinal++) {
            $sourceNames[$ordinal] = $Reader.GetName($ordinal)
            if (-not [string]::IsNullOrWhiteSpace($sourceNames[$ordinal])) {
                $null = $reserved.Add($sourceNames[$ordinal])
            }
        }
        for ($ordinal = 0; $ordinal -lt $Reader.FieldCount; $ordinal++) {
            $column = $schema[$ordinal]
            $sourceName = $sourceNames[$ordinal]
            if (-not [string]::IsNullOrWhiteSpace($sourceName) -and $assigned.Add($sourceName)) {
                $jsonName = $sourceName
            }
            else {
                $baseName = if ([string]::IsNullOrWhiteSpace($sourceName)) {
                    "Column$($ordinal + 1)"
                } else { $sourceName }
                $jsonName = $baseName
                $suffix = 2
                while ($reserved.Contains($jsonName) -or $assigned.Contains($jsonName)) {
                    $jsonName = "${baseName}_$suffix"
                    $suffix++
                }
                $null = $assigned.Add($jsonName)
            }
            $jsonNames[$ordinal] = $jsonName
            $typeName = $column.DataTypeName
            if ([string]::IsNullOrWhiteSpace($typeName)) {
                $typeName = Get-AzureSqlTypeName ($Reader.GetFieldType($ordinal))
            }
            $columns.Add([ordered]@{
                Name = $jsonName
                SourceName = $sourceName
                Type = [string]$typeName
                Ordinal = $ordinal
                AllowDBNull = $column.AllowDBNull
                Precision = $column.NumericPrecision
                Scale = $column.NumericScale
            })
        }
        $rows = [System.Collections.Generic.List[object]]::new()
        while ($Reader.Read()) {
            $row = [ordered]@{}
            for ($ordinal = 0; $ordinal -lt $Reader.FieldCount; $ordinal++) {
                $typeName = [string]$columns[$ordinal].Type
                if ($typeName -in @('decimal', 'numeric')) {
                    if ($Reader.IsDBNull($ordinal)) { $value = [DBNull]::Value }
                    else { $value = $Reader.GetSqlDecimal($ordinal) }
                }
                elseif ($typeName -eq 'sql_variant') {
                    if ($Reader.IsDBNull($ordinal)) { $value = [DBNull]::Value }
                    else {
                        $sqlValue = $Reader.GetSqlValue($ordinal)
                        if ($sqlValue -is [System.Data.SqlTypes.SqlDecimal]) { $value = $sqlValue }
                        else { $value = $Reader.GetValue($ordinal) }
                    }
                }
                else { $value = $Reader.GetValue($ordinal) }
                $row[$jsonNames[$ordinal]] = ConvertTo-AzureSqlJsonValue $value
            }
            $rows.Add([pscustomobject]$row)
        }
        $sets.Add([pscustomobject][ordered]@{
            Name = ($index -eq 0 ? 'Table' : "Table$($index + 1)")
            Columns = $columns.ToArray()
            Rows = $rows.ToArray()
        })
        $index++
    } while ($Reader.NextResult())
    return ,$sets.ToArray()
}

function Invoke-AzureSqlReaderCommand {
    param([object]$Command, [string]$Operation)
    $reader = $null
    $readFailure = $null
    try {
        $reader = $Command.ExecuteReader()
        if ($null -eq $reader) { throw 'Azure SQL command returned no reader.' }
        $sets = Read-AzureSqlResultSets -Reader $reader
        $affected = $reader.RecordsAffected
    }
    catch { $readFailure = $_; throw }
    finally {
        if ($reader -is [System.IDisposable]) {
            try { $reader.Dispose() } catch { if ($null -eq $readFailure) { throw } }
        }
    }
    # SqlClient populates output and return-value parameters only after the reader closes.
    $output = Get-AzureSqlOutputParameters -Command $Command
    $value = [pscustomobject]@{
        ResultSets = $sets
        RowsAffected = $affected -eq -1 ? $null : $affected
        OutputParameters = $output
    }
    return ConvertTo-AzureSqlJsonResult -Operation $Operation -Value $value
}
