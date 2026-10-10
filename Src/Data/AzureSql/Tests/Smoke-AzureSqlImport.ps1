using module SignalGraph

param([Parameter(Mandatory)][string]$Manifest, [string]$MissingDependency)
$ErrorActionPreference = 'Stop'
$foundation = Join-Path $PSScriptRoot '../../../../../SovereignTrust.Foundation/Src/PowerShell/SovereignTrust.Foundation.psd1'
Import-Module (Resolve-Path $foundation).ProviderPath -Force

if ($MissingDependency) {
    try { Import-Module -Name $Manifest -ErrorAction Stop }
    catch {
        if ($_.Exception.Message -notmatch ('AzureSql packaged dependency is missing: ' + [regex]::Escape($MissingDependency))) { throw }
        Write-Output "PASS: isolated missing-dependency import failed clearly for $MissingDependency."
        exit 0
    }
    throw 'Import succeeded despite a missing managed dependency.'
}

Import-Module -Name $Manifest -ErrorAction Stop
$moduleRoot = Split-Path -Parent ([IO.Path]::GetFullPath($Manifest))
$provider = [Microsoft.Data.SqlClient.SqlConnection].Assembly
if (-not $provider.Location.StartsWith((Join-Path $moduleRoot 'dependencies'), [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Provider was not loaded from the module artifact.'
}
if (-not ([Microsoft.Data.SqlClient.SqlConnectionStringBuilder]::new() -is [Microsoft.Data.SqlClient.SqlConnectionStringBuilder])) {
    throw 'Packaged SqlConnectionStringBuilder could not be constructed.'
}
$native = Join-Path $moduleRoot 'dependencies/Microsoft.Data.SqlClient.SNI.dll'
$handle = [System.Runtime.InteropServices.NativeLibrary]::Load($native)
[System.Runtime.InteropServices.NativeLibrary]::Free($handle)
$adapter = Resolve-Data_AzureSql
if ($null -eq $adapter) { throw 'AzureSql factory did not return an adapter.' }
$jacket = [pscustomobject]@{
    Resource = 'Server=sql.example.test;Database=AppDb;Authentication=Active Directory Default'
    Name = 'Smoke'
}
$builder = & (Get-Module Data_AzureSql) {
    param($adapterJacket)
    New-AzureSqlConnectionBuilder -Adapter ([pscustomobject]@{ Configuration = $adapterJacket })
} $jacket
if ($builder.DataSource -ne 'sql.example.test' -or $builder.InitialCatalog -ne 'AppDb' -or
    $builder.TrustServerCertificate -or $builder.ApplicationName -ne 'SovereignTrust.Adapters.Data.AzureSql') {
    throw 'Production connection builder did not apply the secure resource contract.'
}
$constructed = $adapter.Construct($jacket)
if ($constructed.Failure() -or -not [object]::ReferenceEquals($adapter.Signal.GetJacket().GetResult(), $jacket)) {
    throw 'AzureSql construction did not retain the hydrated jacket.'
}
Write-Output 'PASS: fresh import, local SqlClient package 6.1.7, native SNI, connection builder, adapter factory, and construction.'
