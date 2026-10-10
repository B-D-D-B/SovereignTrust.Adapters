function Invoke-AzureSqlQuery {
    param([object]$Session, [object]$Adapter, [object]$Config)
    $text = Get-AzureSqlObjectValue $Config 'CommandText'
    if ($text -isnot [string] -or [string]::IsNullOrWhiteSpace($text)) {
        throw 'Query requires Config.CommandText.'
    }
    $command = New-AzureSqlCommand -Session $Session -Adapter $Adapter -Config $Config `
        -CommandType Text -CommandText $text
    $operationFailure = $null
    try { return Invoke-AzureSqlReaderCommand -Command $command -Operation Query }
    catch { $operationFailure = $_; throw }
    finally { if ($command -is [System.IDisposable]) { try { $command.Dispose() } catch { if ($null -eq $operationFailure) { throw } } } }
}
