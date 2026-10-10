@{
    RootModule = 'Data_AzureSql.psm1'
    ModuleVersion = '1.1.0'
    CompatiblePSEditions = @('Core')
    GUID = '64270e37-29cb-47be-887f-62488436e69e'
    Author = 'Silicon Dream Artists'
    CompanyName = 'Silicon Dream Artists'
    Copyright = '(c) Silicon Dream Artists. Current copyright holder: BDDB LLC.'
    Description = 'Azure SQL mapped data adapter with packaged Microsoft.Data.SqlClient dependencies and Write, Query, and Delete operations.'
    PowerShellVersion = '7.4'
    RequiredModules = @('SignalGraph')
    FunctionsToExport = @('Resolve-Data_AzureSql', 'ConvertTo-AzureSqlJsonResult')
    CmdletsToExport = @()
    VariablesToExport = @()
    AliasesToExport = @()
    PrivateData = @{ DependencyPackage = @{
        Name = 'Microsoft.Data.SqlClient'
        Version = '6.1.7'
        TargetFramework = 'net8.0'
        RuntimeIdentifier = 'win-x64'
        Layout = 'dependencies/'
    }; PSData = @{
        Tags = @('Data_AzureSql', 'SovereignTrust', 'Adapters', 'AzureSql')
        LicenseUri = 'https://opensource.org/licenses/MIT'
        ProjectUri = 'https://github.com/B-D-D-B/SovereignTrust.Adapters'
    } }
}
