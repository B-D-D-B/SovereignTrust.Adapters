function Invoke-AzureSqlDelete {
    param([object]$Session, [object]$Adapter, [object]$Config, [object]$Transaction)
    $text = Get-AzureSqlObjectValue $Config 'CommandText'
    if ($text -isnot [string] -or [string]::IsNullOrWhiteSpace($text)) {
        throw 'Delete requires Config.CommandText.'
    }
    $command = New-AzureSqlCommand -Session $Session -Adapter $Adapter -Config $Config `
        -CommandType Text -CommandText $text -Transaction $Transaction
    $operationFailure = $null
    try {
        if (Get-AzureSqlObjectValue $Config 'ExpectResultSets' $false) {
            return Invoke-AzureSqlReaderCommand -Command $command -Operation Delete
        }
        $affected = $command.ExecuteNonQuery()
        $output = Get-AzureSqlOutputParameters -Command $command
        return ConvertTo-AzureSqlJsonResult -Operation Delete -Value ([pscustomobject]@{
            ResultSets = @()
            RowsAffected = $affected -eq -1 ? $null : $affected
            OutputParameters = $output
        })
    }
    catch { $operationFailure = $_; throw }
    finally { if ($command -is [System.IDisposable]) { try { $command.Dispose() } catch { if ($null -eq $operationFailure) { throw } } } }
}
