using module SignalGraph

$foundationModuleName = 'SovereignTrust.Foundation'
if (-not (Get-Module -Name $foundationModuleName)) {
    $foundationPath = Join-Path $PSScriptRoot '../../../../../SovereignTrust.Foundation/Src/PowerShell/SovereignTrust.Foundation.psd1'
    Import-Module (Resolve-Path $foundationPath).ProviderPath -Force
}

. "$PSScriptRoot/Resolve-CodexCLIRuntime.ps1"
. "$PSScriptRoot/Resolve-CodexCLIPrompt.ps1"
. "$PSScriptRoot/Resolve-CodexCLIMedia.ps1"
. "$PSScriptRoot/New-CodexCLIProcess.ps1"
. "$PSScriptRoot/Invoke-CodexCLIExecution.ps1"
. "$PSScriptRoot/ConvertTo-CodexCLIJsonResult.ps1"
. "$PSScriptRoot/Invoke-Intelligence_CodexCLI.ps1"
. "$PSScriptRoot/Intelligence_CodexCLI.ps1"

Export-ModuleMember -Function Resolve-Intelligence_CodexCLI
