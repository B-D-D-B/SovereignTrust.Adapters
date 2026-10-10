using module SignalGraph

. "$PSScriptRoot/Import-AzureSqlProvider.ps1"

$foundationModuleName = 'SovereignTrust.Foundation'
if (-not (Get-Module -Name $foundationModuleName)) {
    $foundationPath = Join-Path $PSScriptRoot '../../../../../SovereignTrust.Foundation/Src/PowerShell/SovereignTrust.Foundation.psd1'
    Import-Module (Resolve-Path $foundationPath).ProviderPath -Force
}

. "$PSScriptRoot/ConvertTo-AzureSqlJsonResult.ps1"
. "$PSScriptRoot/Resolve-AzureSqlWriteInput.ps1"
. "$PSScriptRoot/Open-AzureSqlConnection.ps1"
. "$PSScriptRoot/Add-AzureSqlParameters.ps1"
. "$PSScriptRoot/New-AzureSqlCommand.ps1"
. "$PSScriptRoot/New-AzureSqlSession.ps1"
. "$PSScriptRoot/Invoke-AzureSqlWrite.ps1"
. "$PSScriptRoot/Invoke-AzureSqlQuery.ps1"
. "$PSScriptRoot/Invoke-AzureSqlDelete.ps1"
. "$PSScriptRoot/Invoke-Data_AzureSql.ps1"
. "$PSScriptRoot/Data_AzureSql.ps1"

Export-ModuleMember -Function Resolve-Data_AzureSql, ConvertTo-AzureSqlJsonResult
