# The only production creation point for the provider session. Tests replace
# this private function in module scope with a connection double.
function New-AzureSqlSession {
    param([object]$Adapter)
    $builder = New-AzureSqlConnectionBuilder -Adapter $Adapter
    try {
        return [Microsoft.Data.SqlClient.SqlConnection]::new($builder.ConnectionString)
    }
    catch {
        # Provider failures may contain server names or authentication details.
        throw 'Azure SQL connection could not be created.'
    }
}
