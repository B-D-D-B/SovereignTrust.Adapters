using module SignalGraph

$ErrorActionPreference = 'Stop'
$foundation = Join-Path $PSScriptRoot '../../../../../SovereignTrust.Foundation/Src/PowerShell/SovereignTrust.Foundation.psd1'
$manifest = Join-Path $PSScriptRoot '../PowerShell/Data_AzureSql.psd1'
Import-Module (Resolve-Path $foundation).ProviderPath -Force
Import-Module (Resolve-Path $manifest).ProviderPath -Force
$module = Get-Module Data_AzureSql
function Assert([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }

& $module {
    function CheckBuilder($resource, $valid) {
        $adapter = [pscustomobject]@{ Configuration = [pscustomobject]@{
            Resource = $resource; Addresses = @('https://key-vault.example/')
        } }
        $builder = $null
        try {
            $builder = New-AzureSqlConnectionBuilder $adapter
        }
        catch {
            if ($valid) { throw }
            if ($_.Exception.Message -match 'synthetic-password|synthetic-token') { throw 'Secret escaped through validation error.' }
            return $null
        }
        if (-not $valid) { throw 'Invalid connection resource was accepted.' }
        if ($builder.DataSource -ne 'sql.example.test' -or $builder.InitialCatalog -ne 'AppDb' -or
            $builder.DataSource -eq 'https://key-vault.example/' -or
            $builder.TrustServerCertificate -or [string]$builder.Encrypt -in @('False','Optional') -or
            $builder.ApplicationName -ne 'SovereignTrust.Adapters.Data.AzureSql') {
            throw 'Secure connection settings were not applied.'
        }
        return $builder
    }
    $default = CheckBuilder 'Server=sql.example.test;Database=AppDb;Authentication=Active Directory Default' $true
    if ($default.ConnectTimeout -ne 15 -or [string]$default.Authentication -ne 'ActiveDirectoryDefault') {
        throw 'Default authentication or timeout failed.'
    }
    $managed = CheckBuilder 'Server=sql.example.test;Database=AppDb;Authentication=Active Directory Managed Identity;User ID=11111111-1111-1111-1111-111111111111;Connect Timeout=27' $true
    if ($managed.ConnectTimeout -ne 27 -or [string]$managed.Authentication -ne 'ActiveDirectoryManagedIdentity' -or
        $managed.UserID -ne '11111111-1111-1111-1111-111111111111') {
        throw 'Managed identity configuration failed.'
    }
    $direct = New-AzureSqlConnectionBuilder ([pscustomobject]@{ Configuration = [pscustomobject]@{
        Resource = 'sda-fusion'; Addresses = @('sda-dev.database.windows.net')
    } })
    if ($direct.DataSource -cne 'sda-dev.database.windows.net' -or $direct.InitialCatalog -cne 'sda-fusion' -or
        [string]$direct.Authentication -cne 'ActiveDirectoryDefault' -or $direct.TrustServerCertificate -or
        [string]$direct.Encrypt -in @('False','Optional')) {
        throw 'Direct passwordless database configuration was not built securely.'
    }
    foreach ($invalidDirect in @(
        @{ Resource='sda-fusion'; Addresses=@('https://sda-dev.database.windows.net') },
        @{ Resource='sda-fusion'; Addresses=@('sda-dev.database.windows.net','other.database.windows.net') },
        @{ Resource='sda-fusion;Password=synthetic-password'; Addresses=@('sda-dev.database.windows.net') },
        @{ Resource='sda-fusion'; Addresses=@('sda-dev.database.windows.net;Trust Server Certificate=True') }
    )) {
        try {
            $null = New-AzureSqlConnectionBuilder ([pscustomobject]@{ Configuration = [pscustomobject]$invalidDirect })
            throw 'Invalid direct database configuration was accepted.'
        }
        catch {
            if ($_.Exception.Message -eq 'Invalid direct database configuration was accepted.' -or
                $_.Exception.Message -match 'synthetic-password') { throw }
        }
    }
    foreach ($invalid in @(
        $null, '', 'Server=sql.example.test;Database=AppDb',
        'Server=sql.example.test;Authentication=Active Directory Default',
        'Database=AppDb;Authentication=Active Directory Default',
        'Server=https://key-vault.example/;Database=AppDb;Authentication=Active Directory Default',
        'Server=sql.example.test;Database=AppDb;Authentication=Active Directory Default;Encrypt=False',
        'Server=sql.example.test;Database=AppDb;Authentication=Active Directory Default;Trust Server Certificate=True',
        'Server=sql.example.test;Database=AppDb;Authentication=Active Directory Default;Connect Timeout=0',
        'Server=sql.example.test;Database=AppDb;Authentication=Active Directory Default;Password=synthetic-password',
        'Server=sql.example.test;Database=AppDb;Authentication=Sql Password;User ID=u;Password=synthetic-password',
        'not a connection resource synthetic-token'
    )) { $null = CheckBuilder $invalid $false }

    $command = [Microsoft.Data.SqlClient.SqlCommand]::new('SELECT @Id, @Payload')
    try {
        $guid = [guid]'11111111-1111-1111-1111-111111111111'
        $binary = [byte[]](1,2,3)
        $date = [datetimeoffset]'2024-01-02T03:04:05+00:00'
        $descriptors = @(
            @{ Name='@Id'; SqlDbType='Int'; Value='42' },
            @{ Name='@Amount'; SqlDbType='Decimal'; Precision=18; Scale=4; Value=[decimal]'125.5000' },
            @{ Name='@Payload'; SqlDbType='VarBinary'; Size=-1; Value=$binary },
            @{ Name='@Guid'; SqlDbType='UniqueIdentifier'; Value=$guid },
            @{ Name='@When'; SqlDbType='DateTimeOffset'; Value=$date },
            @{ Name='@Created'; SqlDbType='DateTime2'; Value=[datetime]'2024-01-02T03:04:05' },
            @{ Name='@Missing'; SqlDbType='NVarChar'; Size=20; Value=$null },
            @{ Name='@Out'; SqlDbType='NVarChar'; Size=30; Direction='Output' },
            @{ Name='@InOut'; SqlDbType='BigInt'; Direction='InputOutput'; Value=[long]9007199254740992 },
            @{ Name='@Return'; SqlDbType='Int'; Direction='ReturnValue' }
        )
        Add-AzureSqlParameters $command $descriptors
        if ($command.Parameters.Count -ne 10 -or $command.Parameters['@Id'].Value -isnot [int] -or
            $command.Parameters['@Id'].Value -ne 42 -or
            $command.Parameters['@Amount'].Value -isnot [decimal] -or
            $command.Parameters['@Amount'].Precision -ne 18 -or $command.Parameters['@Amount'].Scale -ne 4 -or
            $command.Parameters['@Payload'].SqlDbType -ne [System.Data.SqlDbType]::VarBinary -or
            $command.Parameters['@Payload'].Size -ne -1 -or
            -not [object]::ReferenceEquals($command.Parameters['@Payload'].Value, $binary) -or
            $command.Parameters['@Guid'].Value -ne $guid -or $command.Parameters['@When'].Value -ne $date -or
            $command.Parameters['@Created'].Value -isnot [datetime] -or
            $command.Parameters['@Missing'].Value -isnot [DBNull] -or
            $command.Parameters['@Out'].Direction -ne [System.Data.ParameterDirection]::Output -or
            $command.Parameters['@InOut'].Value -isnot [long] -or
            $command.Parameters['@InOut'].Direction -ne [System.Data.ParameterDirection]::InputOutput -or
            $command.Parameters['@Return'].Direction -ne [System.Data.ParameterDirection]::ReturnValue -or
            $command.Parameters['@Return'].Value -isnot [DBNull] -or
            $command.CommandText -ne 'SELECT @Id, @Payload') {
            throw 'Typed parameter metadata, values, directions, or SQL separation failed.'
        }
        $compat = [Microsoft.Data.SqlClient.SqlCommand]::new()
        Add-AzureSqlParameters $compat @{ '@Count' = [int]3; '@Name' = 'Museum' }
        if ($compat.Parameters['@Count'].SqlDbType -ne [System.Data.SqlDbType]::Int -or
            $compat.Parameters['@Name'].SqlDbType -ne [System.Data.SqlDbType]::NVarChar) {
            throw 'Conservative dictionary inference failed.'
        }
        foreach ($bad in @(
            @{Name='@Bad';SqlDbType='Structured';Value=@()},
            @{Name='@Bad';SqlDbType='Unknown';Value=1},
            @{Name='@Bad';SqlDbType='Int';Direction='Sideways';Value=1},
            @{Name='@Bad';SqlDbType='Int';Value='secret-invalid-number'},
            @{Name='@Bad';SqlDbType='NVarChar';Value=[pscustomobject]@{Nested=1}},
            @{Name='@Bad';SqlDbType='NVarChar';Direction='Output'},
            @{Name='@Bad';SqlDbType='Decimal';Precision=2;Scale=3;Value=1},
            @{Name='@Bad';SqlDbType='Int'},
            @{Name='@Bad;DROP';SqlDbType='Int';Value=1}
        )) {
            try { $null = New-AzureSqlParameter $bad; throw 'Invalid parameter was accepted.' }
            catch {
                if ($_.Exception.Message -eq 'Invalid parameter was accepted.' -or
                    $_.Exception.Message -match 'secret-invalid-number') { throw }
            }
        }
        foreach ($badDictionary in @(@{'@Null'=$null}, @{'@Object'=@{Nested=1}})) {
            try { Add-AzureSqlParameters ([Microsoft.Data.SqlClient.SqlCommand]::new()) $badDictionary; throw 'Invalid dictionary was accepted.' }
            catch { if ($_.Exception.Message -eq 'Invalid dictionary was accepted.') { throw } }
        }
    }
    finally { $command.Dispose() }
}
$adapter = Resolve-Data_AzureSql
$null = $adapter.Construct([pscustomobject]@{ Resource = 'not a connection resource synthetic-token' })
$conduction = [Signal]::Start('AzureSqlSecurity.Conduction') | Select-Object -Last 1
$item = [Signal]::Start('AzureSqlSecurity.Item') | Select-Object -Last 1
$result = $adapter.Invoke('FusionDatabase', 'Query', $conduction,
    [pscustomobject]@{ Config = [pscustomobject]@{ CommandText = 'select 1' } }, $item)
Assert ($result.Failure()) 'Invalid resource did not produce a failed signal.'
Assert (($result.GetEntries() | Out-String) -notmatch 'synthetic-token') 'Secret escaped through signal entries.'
Write-Output 'PASS: secure connection resources and typed SQL parameters.'
