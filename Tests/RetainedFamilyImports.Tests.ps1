using module SignalGraph

$ErrorActionPreference = 'Stop'
$foundationPath = Join-Path $PSScriptRoot '../../SovereignTrust.Foundation/Src/PowerShell/SovereignTrust.Foundation.psd1'
Import-Module $foundationPath -Force
Import-Module (Join-Path $PSScriptRoot '../Src/Network/DiscordBot/PowerShell/Network_DiscordBot.psd1') -Force
Import-Module (Join-Path $PSScriptRoot '../Src/Queue/AzureStorageQueue/PowerShell/Queue_AzureStorageQueue.psd1') -Force
function Assert([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }

$foundation = Get-Module SovereignTrust.Foundation
$network = & $foundation { [MappedNetworkAdapter]::new() }
$queue = & $foundation { [MappedQueueAdapter]::new() }
$discordModule = Get-Module Network_DiscordBot
$queueModule = Get-Module Queue_AzureStorageQueue
$discord = & $discordModule { param($mapped) [Network_DiscordBot]::new($mapped) } $network
$queueProvider = & $queueModule { param($mapped) [Queue_AzureStorageQueue]::new($mapped) } $queue
Assert ([object]::ReferenceEquals($discord.MappedAdapter,$network)) 'Discord typed constructor lost Network instance.'
Assert ([object]::ReferenceEquals($queueProvider.MappedAdapter,$queue)) 'Queue typed constructor lost Queue instance.'
foreach ($case in @(
    [pscustomobject]@{ Module=$discordModule; Class='Network_DiscordBot'; Opaque=$queue },
    [pscustomobject]@{ Module=$queueModule; Class='Queue_AzureStorageQueue'; Opaque=$network }
)) {
    foreach ($opaque in @($case.Opaque,[pscustomobject]@{ Kind='other' })) {
        if ($case.Class -eq 'Network_DiscordBot') { $carried = & $case.Module { param($mapped) [Network_DiscordBot]::new($mapped) } $opaque }
        else { $carried = & $case.Module { param($mapped) [Queue_AzureStorageQueue]::new($mapped) } $opaque }
        Assert ([object]::ReferenceEquals($carried.MappedAdapter,$opaque)) "$($case.Class) lost opaque mapped object."
    }
}
Assert ($null -ne (Get-Command Resolve-Network_DiscordBot) -and $null -ne (Get-Command Resolve-Queue_AzureStorageQueue)) 'Retained resolver export missing.'
$satelliteManifest = Join-Path $PSScriptRoot '../Src/Satellite/AzureApplicationInsights/PowerShell/Satellite_AzureApplicationInsights.psd1'
Assert (-not (Get-Module Satellite_AzureApplicationInsights)) 'Satellite provider was loaded before dynamic manifest resolution.'
$loaded = & $foundation {
    param($manifest)
    $originalDictionary = (Get-Item Function:script:Resolve-PathFromDictionary).ScriptBlock
    $originalModulePath = (Get-Item Function:script:Resolve-ModulePathFromAdapter).ScriptBlock
    $script:AdapterIoCManifestPath = $manifest
    try {
        Set-Item Function:script:Resolve-PathFromDictionary -Value {
            $result = [Signal]::Start('IoC.Loader.AdapterLookup') | Select-Object -Last 1
            $result.SetResult([pscustomobject]@{ Name='FixtureStorage' }) | Out-Null
            return $result
        }
        Set-Item Function:script:Resolve-ModulePathFromAdapter -Value {
            $result = [Signal]::Start('IoC.Loader.PathLookup') | Select-Object -Last 1
            $result.SetResult($script:AdapterIoCManifestPath) | Out-Null
            return $result
        }
        $request = [Signal]::Start('IoC.Loader.Request') | Select-Object -Last 1
        $response = Resolve-ModuleFromAdapter -Signal $request -Slot 'ModuleRoots' -ModuleName 'Satellite_AzureApplicationInsights.psd1' -RelativePath 'SovereignTrust.Adapters/Src/Satellite/AzureApplicationInsights/PowerShell/Satellite_AzureApplicationInsights.psd1' | Select-Object -Last 1
        if ($response.Failure() -or -not $response.HasResult()) { throw 'Foundation manifest loader returned a failed Signal.' }
        return [pscustomobject]@{ Path=$response.GetResult().Path; ModuleLoaded=[bool](Get-Module Satellite_AzureApplicationInsights); ResolverLoaded=[bool](Get-Command Resolve-Satellite_AzureApplicationInsights -ErrorAction SilentlyContinue) }
    }
    finally {
        Set-Item Function:script:Resolve-PathFromDictionary -Value $originalDictionary
        Set-Item Function:script:Resolve-ModulePathFromAdapter -Value $originalModulePath
        Remove-Variable -Scope Script -Name AdapterIoCManifestPath -ErrorAction SilentlyContinue
    }
} $satelliteManifest
Assert ([IO.Path]::GetFullPath($loaded.Path) -ceq [IO.Path]::GetFullPath($satelliteManifest)) 'Foundation loader selected a different manifest.'
Assert ($loaded.ModuleLoaded -and $loaded.ResolverLoaded) 'Dynamic manifest import did not load the provider RootModule and resolver.'
Write-Output 'PASS: opaque provider constructors, retained resolver exports, and real Foundation manifest loading.'
