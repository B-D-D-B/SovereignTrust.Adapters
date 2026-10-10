function Get-AzureSqlWriteMember {
    param([object]$InputObject, [string]$Name)
    if ($InputObject -is [System.Collections.IDictionary]) { $value = $InputObject[$Name] }
    else { $value = $InputObject.PSObject.Properties[$Name].Value }
    return ,$value
}

function ConvertTo-AzureSqlColumnValue {
    param([object]$Value, [string]$Type)
    if ($null -eq $Value) { return $null }
    $culture = [Globalization.CultureInfo]::InvariantCulture
    $text = if ($Value -is [IFormattable]) { $Value.ToString($null, $culture) } else { [string]$Value }
    switch ($Type.ToLowerInvariant()) {
        { $_ -in 'string', 'nvarchar', 'varchar', 'text' } { return [string]$Value }
        { $_ -in 'int', 'int32' } { return [int]::Parse($text, [Globalization.NumberStyles]::Integer, $culture) }
        { $_ -in 'long', 'int64', 'bigint' } { return [long]::Parse($text, [Globalization.NumberStyles]::Integer, $culture) }
        { $_ -in 'decimal', 'numeric' } { return [decimal]::Parse($text, [Globalization.NumberStyles]::Number, $culture) }
        { $_ -in 'double', 'float' } { return [double]::Parse($text, [Globalization.NumberStyles]::Float, $culture) }
        { $_ -in 'bool', 'boolean', 'bit' } {
            if ($Value -is [bool]) { return $Value }
            if ([string]$Value -eq '1') { return $true }
            if ([string]$Value -eq '0') { return $false }
            return [bool]::Parse([string]$Value)
        }
        { $_ -in 'date', 'datetime', 'datetime2', 'datetimeoffset' } {
            if ($Value -is [datetimeoffset]) { return $Value }
            return [datetimeoffset]::Parse($text, $culture, [Globalization.DateTimeStyles]::None)
        }
        default { throw "Unsupported ColumnSchema type '$Type'." }
    }
}

function Get-AzureSqlColumnSchema {
    param([object]$Schema)
    $columns = @{}
    if ($null -eq $Schema) { return $columns }
    if ($Schema -is [System.Collections.IDictionary]) {
        foreach ($name in $Schema.Keys) { $columns[[string]$name] = $Schema[$name] }
    }
    elseif ($Schema -is [array] -or $Schema -is [System.Collections.IList]) {
        foreach ($descriptor in $Schema) {
            if (-not (Test-AzureSqlObjectMember $descriptor 'Name') -or -not (Test-AzureSqlObjectMember $descriptor 'Type')) {
                throw 'ColumnSchema descriptors require Name and Type.'
            }
            $name = [string](Get-AzureSqlObjectValue $descriptor 'Name')
            if ([string]::IsNullOrWhiteSpace($name) -or $columns.ContainsKey($name)) {
                throw 'ColumnSchema descriptor names must be nonblank and unique.'
            }
            $columns[$name] = Get-AzureSqlWriteMember $descriptor 'Type'
        }
    }
    else { throw 'ColumnSchema must be a dictionary or Name/Type descriptors.' }
    foreach ($name in @($columns.Keys)) {
        $typeName = $columns[$name]
        if ($typeName -isnot [string] -or [string]::IsNullOrWhiteSpace($typeName)) {
            throw "ColumnSchema '$name' requires a type name."
        }
        # Validate even when no rows contain the column.
        if ($typeName.ToLowerInvariant() -notin @(
            'string','nvarchar','varchar','text','int','int32','long','int64','bigint',
            'decimal','numeric','double','float','bool','boolean','bit',
            'date','datetime','datetime2','datetimeoffset')) {
            throw "Unsupported ColumnSchema type '$typeName'."
        }
        $columns[$name] = $typeName
    }
    return $columns
}

function Resolve-AzureSqlWriteInput {
    param([object]$Config, [Signal]$ItemSignal, [Signal]$OperationSignal)
    $hasContent = Test-AzureSqlObjectMember $Config 'Content'
    $hasPath = Test-AzureSqlObjectMember $Config 'ContentPath'
    if ($hasContent -eq $hasPath) { throw 'Write requires exactly one of Config.Content or Config.ContentPath.' }

    if ($hasPath) {
        $path = Get-AzureSqlWriteMember $Config 'ContentPath'
        if ($path -isnot [string] -or [string]::IsNullOrWhiteSpace($path)) {
            throw 'Config.ContentPath must be a nonblank signal path.'
        }
        $resolution = Resolve-PathFromDictionary -Dictionary $ItemSignal -Path $path | Select-Object -Last 1
        if ($resolution -isnot [Signal]) { throw 'ContentPath resolution returned no signal.' }
        if ($OperationSignal.MergeSignalAndVerifyFailure($resolution)) { throw 'ContentPath resolution failed.' }
        if (-not $resolution.HasResult()) { throw 'ContentPath did not resolve to a result.' }
        $content = $resolution.GetResult()
    }
    else { $content = Get-AzureSqlWriteMember $Config 'Content' }

    $format = 'Object'
    if (Test-AzureSqlObjectMember $Config 'InputFormat') { $format = Get-AzureSqlWriteMember $Config 'InputFormat' }
    $mode = 'Records'
    if (Test-AzureSqlObjectMember $Config 'PayloadMode') { $mode = Get-AzureSqlWriteMember $Config 'PayloadMode' }
    if ($format -isnot [string] -or $format -notin @('Object','Json','Csv')) { throw "Unsupported InputFormat '$format'." }
    if ($mode -isnot [string] -or $mode -notin @('Records','Document')) { throw "Unsupported PayloadMode '$mode'." }
    if ($format -eq 'Csv' -and $mode -eq 'Document') { throw 'CSV supports Records mode only.' }

    $delimiter = ','
    if (Test-AzureSqlObjectMember $Config 'Delimiter') {
        $delimiter = Get-AzureSqlWriteMember $Config 'Delimiter'
        if ($delimiter -isnot [string] -or $delimiter.Length -ne 1) { throw 'Delimiter must be exactly one character.' }
    }

    if ($format -eq 'Json' -and $content -is [string]) {
        $content = ConvertFrom-Json -InputObject $content -Depth 100 -NoEnumerate -ErrorAction Stop
    }
    elseif ($format -eq 'Csv') {
        if ($content -isnot [string]) { throw 'CSV Content must be text.' }
        $content = @(ConvertFrom-Csv -InputObject $content -Delimiter $delimiter[0] -ErrorAction Stop)
    }

    if ($mode -eq 'Document') {
        $json = ConvertTo-Json -InputObject $content -Depth 100 -Compress -ErrorAction Stop
    }
    else {
        if ($null -eq $content) { throw 'Records Content cannot be null.' }
        $schema = Get-AzureSqlColumnSchema (Get-AzureSqlWriteMember $Config 'ColumnSchema')
        if ($content -is [System.Collections.IEnumerable] -and
            $content -isnot [string] -and $content -isnot [System.Collections.IDictionary]) {
            $sourceRows = $content
        }
        else {
            $sourceRows = [object[]]::new(1)
            $sourceRows[0] = $content
        }
        $rows = [System.Collections.Generic.List[object]]::new()
        foreach ($row in $sourceRows) {
            if ($row -isnot [System.Collections.IDictionary] -and $row -isnot [pscustomobject]) {
                throw 'Records Content entries must be dictionaries or PSCustomObjects.'
            }
            $prepared = [ordered]@{}
            if ($row -is [System.Collections.IDictionary]) {
                foreach ($key in $row.Keys) { $prepared[[string]$key] = $row[$key] }
            }
            else {
                foreach ($property in $row.PSObject.Properties) {
                    if ($format -eq 'Csv' -and $null -eq $property.Value) {
                        $prepared[$property.Name] = ''
                    }
                    else { $prepared[$property.Name] = $property.Value }
                }
            }
            foreach ($name in $schema.Keys) {
                if ($prepared.Contains($name)) {
                    try { $prepared[$name] = ConvertTo-AzureSqlColumnValue $prepared[$name] $schema[$name] }
                    catch { throw "ColumnSchema conversion failed for '$name': $($_.Exception.Message)" }
                }
            }
            $rows.Add([pscustomobject]$prepared)
        }
        $json = ConvertTo-Json -InputObject $rows.ToArray() -Depth 100 -Compress -ErrorAction Stop
    }
    return [pscustomobject]@{ Json = $json; InputFormat = $format; PayloadMode = $mode }
}
