function Get-AzureSqlParameterMember {
    param([object]$Descriptor, [string]$Name)
    if ($Descriptor -is [System.Collections.IDictionary]) { $value = $Descriptor[$Name] }
    else { $value = $Descriptor.PSObject.Properties[$Name].Value }
    return ,$value
}

function ConvertTo-AzureSqlParameterValue {
    param([object]$Value, [System.Data.SqlDbType]$SqlDbType)
    if ($null -eq $Value -or $Value -is [DBNull]) { return [DBNull]::Value }
    $culture = [Globalization.CultureInfo]::InvariantCulture
    try {
        if ($SqlDbType -in @([System.Data.SqlDbType]::Binary, [System.Data.SqlDbType]::VarBinary,
                [System.Data.SqlDbType]::Image, [System.Data.SqlDbType]::Timestamp)) {
            if ($Value -is [byte[]]) { return ,$Value }
            if ($Value -is [string]) { return ,([Convert]::FromBase64String($Value)) }
            throw 'Binary value required.'
        }
        if ($Value -is [pscustomobject] -or $Value -is [System.Collections.IDictionary] -or
            ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string])) {
            throw 'Scalar value required.'
        }
        $text = if ($Value -is [IFormattable]) { $Value.ToString($null, $culture) } else { [string]$Value }
        switch ($SqlDbType.ToString()) {
            { $_ -in 'NVarChar','VarChar','NChar','Char','Text','NText','Xml' } { return [string]$Value }
            'Bit' {
                if ($Value -is [bool]) { return $Value }
                if ($text -eq '1') { return $true }
                if ($text -eq '0') { return $false }
                return [bool]::Parse($text)
            }
            'TinyInt' { return [byte]::Parse($text, [Globalization.NumberStyles]::Integer, $culture) }
            'SmallInt' { return [short]::Parse($text, [Globalization.NumberStyles]::Integer, $culture) }
            'Int' { return [int]::Parse($text, [Globalization.NumberStyles]::Integer, $culture) }
            'BigInt' { return [long]::Parse($text, [Globalization.NumberStyles]::Integer, $culture) }
            { $_ -in 'Decimal','Money','SmallMoney' } { return [decimal]::Parse($text, [Globalization.NumberStyles]::Number, $culture) }
            'Real' { return [single]::Parse($text, [Globalization.NumberStyles]::Float, $culture) }
            'Float' { return [double]::Parse($text, [Globalization.NumberStyles]::Float, $culture) }
            'UniqueIdentifier' { return [guid]::Parse($text) }
            { $_ -in 'Date','DateTime','DateTime2','SmallDateTime' } {
                if ($Value -is [datetime]) { return $Value }
                return [datetime]::Parse($text, $culture, [Globalization.DateTimeStyles]::RoundtripKind)
            }
            'DateTimeOffset' {
                if ($Value -is [datetimeoffset]) { return $Value }
                return [datetimeoffset]::Parse($text, $culture, [Globalization.DateTimeStyles]::RoundtripKind)
            }
            'Time' {
                if ($Value -is [timespan]) { return $Value }
                return [timespan]::Parse($text, $culture)
            }
            default { throw 'Unsupported value type.' }
        }
    }
    catch {
        # Parse exceptions can quote the supplied value.
        throw "Azure SQL parameter value cannot be converted to $SqlDbType."
    }
}

function New-AzureSqlParameter {
    param([object]$Descriptor)
    if ($null -eq $Descriptor -or -not (Test-AzureSqlObjectMember $Descriptor 'Name') -or
        -not (Test-AzureSqlObjectMember $Descriptor 'SqlDbType')) {
        throw 'Azure SQL parameter descriptors require Name and SqlDbType.'
    }
    $name = Get-AzureSqlParameterMember $Descriptor 'Name'
    if ($name -isnot [string] -or $name -cnotmatch '^@[A-Za-z_][A-Za-z0-9_]*$') {
        throw 'Azure SQL parameter name is invalid.'
    }
    $typeName = Get-AzureSqlParameterMember $Descriptor 'SqlDbType'
    $supportedTypes = @('BigInt','Binary','Bit','Char','Date','DateTime','DateTime2','DateTimeOffset',
        'Decimal','Float','Image','Int','Money','NChar','NText','NVarChar','Real','SmallDateTime',
        'SmallInt','SmallMoney','Text','Time','Timestamp','TinyInt','UniqueIdentifier','VarBinary',
        'VarChar','Xml')
    if ($typeName -isnot [string] -or $typeName -notin $supportedTypes) {
        throw "Azure SQL parameter '$name' has an unsupported SqlDbType."
    }
    $sqlType = [System.Data.SqlDbType][Enum]::Parse([System.Data.SqlDbType], $typeName, $true)
    $directionName = 'Input'
    if (Test-AzureSqlObjectMember $Descriptor 'Direction') {
        $directionName = Get-AzureSqlParameterMember $Descriptor 'Direction'
    }
    if ($directionName -isnot [string] -or $directionName -notin @('Input','Output','InputOutput','ReturnValue')) {
        throw "Azure SQL parameter '$name' has an invalid Direction."
    }
    $direction = [System.Data.ParameterDirection][Enum]::Parse([System.Data.ParameterDirection], $directionName, $true)
    if ($direction -in @([System.Data.ParameterDirection]::Input, [System.Data.ParameterDirection]::InputOutput) -and
        -not (Test-AzureSqlObjectMember $Descriptor 'Value')) {
        throw "Azure SQL parameter '$name' requires Value."
    }

    $parameter = [Microsoft.Data.SqlClient.SqlParameter]::new($name, $sqlType)
    $parameter.Direction = $direction
    foreach ($property in @('Size','Precision','Scale')) {
        if (-not (Test-AzureSqlObjectMember $Descriptor $property)) { continue }
        $raw = Get-AzureSqlParameterMember $Descriptor $property
        $number = 0
        if ($null -eq $raw -or $raw -is [bool] -or
            -not [int]::TryParse([string]$raw, [ref]$number)) {
            throw "Azure SQL parameter '$name' has invalid $property."
        }
        if ($property -eq 'Size') {
            if ($number -lt -1 -or $number -eq 0) { throw "Azure SQL parameter '$name' has invalid Size." }
            if ($number -eq -1 -and $sqlType -notin @([System.Data.SqlDbType]::NVarChar,
                    [System.Data.SqlDbType]::VarChar, [System.Data.SqlDbType]::VarBinary)) {
                throw "Azure SQL parameter '$name' cannot use Size -1."
            }
            $parameter.Size = $number
        }
        else {
            if ($number -lt 0 -or $number -gt 38 -or ($property -eq 'Precision' -and $number -eq 0)) {
                throw "Azure SQL parameter '$name' has invalid $property."
            }
            $parameter.$property = [byte]$number
        }
    }
    if ($parameter.Scale -gt $parameter.Precision -and $parameter.Precision -ne 0) {
        throw "Azure SQL parameter '$name' has Scale greater than Precision."
    }
    if ($direction -ne [System.Data.ParameterDirection]::Input -and
        $sqlType -in @([System.Data.SqlDbType]::NVarChar,[System.Data.SqlDbType]::VarChar,
            [System.Data.SqlDbType]::VarBinary,[System.Data.SqlDbType]::NChar,
            [System.Data.SqlDbType]::Char,[System.Data.SqlDbType]::Binary) -and
        $parameter.Size -eq 0) {
        throw "Azure SQL output parameter '$name' requires Size."
    }
    $value = if (Test-AzureSqlObjectMember $Descriptor 'Value') {
        Get-AzureSqlParameterMember $Descriptor 'Value'
    } else { $null }
    $parameter.Value = ConvertTo-AzureSqlParameterValue -Value $value -SqlDbType $sqlType
    return $parameter
}

function Add-AzureSqlParameters {
    param([object]$Command, [object]$Parameters)
    if ($null -eq $Parameters) { return }
    $descriptors = [System.Collections.Generic.List[object]]::new()
    if ($Parameters -is [System.Collections.IDictionary] -and
        -not ((Test-AzureSqlObjectMember $Parameters 'Name') -and (Test-AzureSqlObjectMember $Parameters 'SqlDbType'))) {
        foreach ($key in $Parameters.Keys) {
            $value = $Parameters[$key]
            if ($null -eq $value) {
                throw 'Azure SQL dictionary parameter requires a supported nonnull scalar value; use a descriptor.'
            }
            $type = switch ($value.GetType().FullName) {
                'System.String' { 'NVarChar' }
                'System.Boolean' { 'Bit' }
                'System.Byte' { 'TinyInt' }
                'System.Int16' { 'SmallInt' }
                'System.Int32' { 'Int' }
                'System.Int64' { 'BigInt' }
                'System.Decimal' { 'Decimal' }
                'System.Single' { 'Real' }
                'System.Double' { 'Float' }
                'System.Guid' { 'UniqueIdentifier' }
                'System.DateTime' { 'DateTime2' }
                'System.DateTimeOffset' { 'DateTimeOffset' }
                'System.TimeSpan' { 'Time' }
                'System.Byte[]' { 'VarBinary' }
                default { $null }
            }
            if ($null -eq $type) { throw 'Azure SQL dictionary parameter requires a supported nonnull scalar value; use a descriptor.' }
            $descriptors.Add([pscustomobject]@{ Name = [string]$key; SqlDbType = $type; Value = $value })
        }
    }
    elseif ($Parameters -is [System.Collections.IDictionary] -or $Parameters -is [pscustomobject]) {
        $descriptors.Add($Parameters)
    }
    elseif ($Parameters -is [System.Collections.IEnumerable] -and $Parameters -isnot [string]) {
        foreach ($descriptor in $Parameters) { $descriptors.Add($descriptor) }
    }
    else { throw 'Azure SQL Parameters must be descriptors or a scalar dictionary.' }
    $names = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($descriptor in $descriptors) {
        $parameter = New-AzureSqlParameter -Descriptor $descriptor
        if (-not $names.Add($parameter.ParameterName)) { throw 'Azure SQL parameter names must be unique.' }
        $null = $Command.Parameters.Add($parameter)
    }
}
