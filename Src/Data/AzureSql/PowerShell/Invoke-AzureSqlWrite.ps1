function Invoke-AzureSqlWrite {
    param([object]$Session, [object]$Adapter, [object]$Config, [object]$NormalizedWrite, [object]$Transaction)
    $procedure = Get-AzureSqlObjectValue $Config 'Procedure'
    if ($procedure -isnot [string] -or [string]::IsNullOrWhiteSpace($procedure)) {
        throw 'Write requires Config.Procedure.'
    }
    if ($null -eq $NormalizedWrite -or $NormalizedWrite.Json -isnot [string]) {
        throw 'Write requires locally normalized JSON.'
    }
    $payloadName = Get-AzureSqlObjectValue $Config 'PayloadParameter' '@Payload'
    if ($payloadName -isnot [string] -or $payloadName -cnotmatch '^@[A-Za-z_][A-Za-z0-9_]*$') {
        throw 'Config.PayloadParameter is invalid.'
    }
    $command = New-AzureSqlCommand -Session $Session -Adapter $Adapter -Config $Config `
        -CommandType StoredProcedure -CommandText $procedure -Transaction $Transaction
    $operationFailure = $null
    try {
        foreach ($existing in $command.Parameters) {
            if ($existing.ParameterName -eq $payloadName) { throw 'Payload parameter conflicts with Config.Parameters.' }
        }
        $payload = [Microsoft.Data.SqlClient.SqlParameter]::new($payloadName, [System.Data.SqlDbType]::NVarChar, -1)
        $payload.Value = $NormalizedWrite.Json
        $null = $command.Parameters.Add($payload)
        return Invoke-AzureSqlReaderCommand -Command $command -Operation Write
    }
    catch { $operationFailure = $_; throw }
    finally { if ($command -is [System.IDisposable]) { try { $command.Dispose() } catch { if ($null -eq $operationFailure) { throw } } } }
}
