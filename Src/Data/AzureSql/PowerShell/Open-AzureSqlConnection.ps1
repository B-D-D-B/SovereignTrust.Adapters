function New-AzureSqlConnectionBuilder {
    param([object]$Adapter)

    $configuration = Get-AzureSqlObjectValue $Adapter 'Configuration'
    $resource = Get-AzureSqlObjectValue $configuration 'Resource'
    if ($resource -isnot [string] -or [string]::IsNullOrWhiteSpace($resource)) {
        throw 'Azure SQL requires a database resource or hydrated connection resource.'
    }

    if ($resource -notmatch '[=;]') {
        # A plain Resource names the database. Addresses supplies one SQL host.
        # Assign typed builder properties so neither value can inject options.
        $addresses = @(Get-AzureSqlObjectValue $configuration 'Addresses')
        if ($resource -cnotmatch '^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$' -or
            $addresses.Count -ne 1 -or $addresses[0] -isnot [string] -or
            $addresses[0] -cnotmatch '^[A-Za-z0-9][A-Za-z0-9.-]*\.database\.windows\.net$') {
            throw 'Azure SQL database resource requires one valid Azure SQL server address.'
        }
        $builder = [Microsoft.Data.SqlClient.SqlConnectionStringBuilder]::new()
        $builder['Data Source'] = $addresses[0]
        $builder['Initial Catalog'] = $resource
        $builder['Authentication'] = 'Active Directory Default'
    }
    else {
        try {
            $builder = [Microsoft.Data.SqlClient.SqlConnectionStringBuilder]::new($resource)
        }
        catch {
            # SqlClient parse errors can quote the supplied resource. Never forward them.
            throw 'Azure SQL connection resource is invalid.'
        }
    }

    if ([string]::IsNullOrWhiteSpace($builder.DataSource) -or
        [string]::IsNullOrWhiteSpace($builder.InitialCatalog) -or
        $builder.DataSource -match '^https?://') {
        throw 'Azure SQL connection resource requires a SQL data source and initial catalog.'
    }
    $authentication = [string]$builder.Authentication
    if ($authentication -notin @('ActiveDirectoryDefault', 'ActiveDirectoryManagedIdentity')) {
        throw 'Azure SQL connection resource has an unsupported authentication mode.'
    }
    if ($builder.TrustServerCertificate -or [string]$builder.Encrypt -in @('False', 'Optional') -or
        $builder.IntegratedSecurity -or -not [string]::IsNullOrEmpty($builder.Password)) {
        throw 'Azure SQL connection resource contains an insecure or incompatible setting.'
    }
    if ($authentication -eq 'ActiveDirectoryDefault' -and -not [string]::IsNullOrEmpty($builder.UserID)) {
        throw 'Azure SQL Default authentication does not accept User ID.'
    }
    if ($builder.ConnectTimeout -lt 1 -or $builder.ConnectTimeout -gt 300) {
        throw 'Azure SQL connection timeout must be between 1 and 300 seconds.'
    }

    $builder.Encrypt = $true
    $builder.TrustServerCertificate = $false
    $builder.PersistSecurityInfo = $false
    $builder['Application Name'] = 'SovereignTrust.Adapters.Data.AzureSql'
    return $builder
}
