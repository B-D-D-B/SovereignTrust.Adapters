# Offline test fixture for the pinned Microsoft.Data.SqlClient 6.1.7 package.
# This is deliberately the only place that touches SqlClient's private output
# buffer; production uses public SqlParameter getters.
function Set-TestSqlDecimalOutputBuffer {
    param(
        [Microsoft.Data.SqlClient.SqlParameter]$Parameter,
        [AllowNull()][string]$DecimalText
    )
    $parameterType = [Microsoft.Data.SqlClient.SqlParameter]
    if ($parameterType.Assembly.GetName().Version.ToString() -ne '6.0.0.0') {
        throw 'SqlClient decimal test fixture requires the pinned 6.1.7 assembly layout (assembly version 6.0.0.0).'
    }
    $flags = [Reflection.BindingFlags]'NonPublic,Instance'
    $bufferField = $parameterType.GetField('_sqlBufferReturnValue', $flags)
    if ($null -eq $bufferField -or $bufferField.FieldType.FullName -ne 'Microsoft.Data.SqlClient.SqlBuffer') {
        throw 'SqlClient decimal output-buffer layout changed.'
    }
    $buffer = [Activator]::CreateInstance($bufferField.FieldType, $true)
    if ([string]::IsNullOrEmpty($DecimalText)) {
        $setter = $bufferField.FieldType.GetMethod('SetToNullOfType', $flags)
        if ($null -eq $setter) { throw 'SqlClient null decimal buffer setter changed.' }
        $storageType = [Enum]::Parse($setter.GetParameters()[0].ParameterType, 'Decimal')
        $null = $setter.Invoke($buffer, @($storageType))
    }
    else {
        $setter = $bufferField.FieldType.GetMethod('SetToDecimal', $flags)
        if ($null -eq $setter) { throw 'SqlClient decimal output-buffer setter changed.' }
        $priorCulture = [Threading.Thread]::CurrentThread.CurrentCulture
        try {
            [Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::InvariantCulture
            $decimal = [System.Data.SqlTypes.SqlDecimal]::Parse($DecimalText)
        }
        finally { [Threading.Thread]::CurrentThread.CurrentCulture = $priorCulture }
        $null = $setter.Invoke($buffer, @($decimal.Precision, $decimal.Scale, $decimal.IsPositive, $decimal.Data))
    }
    $bufferField.SetValue($Parameter, $buffer)
    # SqlClient replaces the descriptor's input/default value when it receives
    # an output token. Mirror that state so the public getters read the buffer.
    foreach ($name in @('_value', '_coercedValue', '_valueAsINullable')) {
        $field = $parameterType.GetField($name, $flags)
        if ($null -eq $field) { throw "SqlClient decimal output-buffer field $name changed." }
        $field.SetValue($Parameter, $null)
    }
}
