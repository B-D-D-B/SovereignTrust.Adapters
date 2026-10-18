function ConvertTo-CodexCLIJsonResult {
    param([Parameter(Mandatory)][string]$FinalText)
    return ConvertTo-Json -InputObject @{ choices = @(@{ message = @{ role = 'assistant'; content = $FinalText } }) } -Depth 8 -Compress
}
