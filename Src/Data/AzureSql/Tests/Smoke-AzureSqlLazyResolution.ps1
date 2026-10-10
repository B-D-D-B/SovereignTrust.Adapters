using module SignalGraph

$ErrorActionPreference = 'Stop'
$foundationManifest = Join-Path $PSScriptRoot '../../../../../SovereignTrust.Foundation/Src/PowerShell/SovereignTrust.Foundation.psd1'
$configPath = Join-Path $PSScriptRoot '../../../../../SDAFusion-Content/SDA/Config/SDAFusionApp.Json'
$moduleRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../../../..')).ProviderPath
Import-Module (Resolve-Path $foundationManifest).ProviderPath -Force
if (Get-Module Data_AzureSql) { throw 'AzureSql must be unloaded before lazy registration.' }

function Assert([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }

$config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json -Depth 100
$agent = @($config.Agents | Where-Object Name -eq 'sdadev01')[0]
$sourceJacket = @($agent.Roles.SDAWorkItems.Adapters | Where-Object Name -eq 'SDAFusionDatabase')[0]
Assert ($null -ne $sourceJacket -and $sourceJacket.Resource -ceq 'sda-fusion' -and $sourceJacket.Addresses[0] -ceq 'sda-dev.database.windows.net') 'The production configuration jacket was not selected.'

$bootstrap = [Signal]::Start('AzureSqlLazy.Bootstrap') | Select-Object -Last 1
$bootstrap.SetResult([pscustomobject]@{}) | Out-Null
$conductorSignal = New-Conductor -HostConductor $null -ConductionSignal $bootstrap | Select-Object -Last 1
Assert (-not $conductorSignal.Failure() -and $conductorSignal.HasResult()) 'Conductor bootstrap failed.'
$conductor = $conductorSignal.GetResult()
$conductorJacket = [Signal]::Start('AzureSqlLazy.Conductor') | Select-Object -Last 1
$conductorJacket.SetJacket($conductor.Signal) | Out-Null
$conductorJacket.SetPointer($conductor.Signal.GetPointer()) | Out-Null
$runSignal = [Signal]::Start('AzureSqlLazy.Run') | Select-Object -Last 1
$runSignal.SetJacket($conductor.Signal) | Out-Null
$runSignal.SetPointer($conductor.Signal.GetPointer()) | Out-Null
$runSignal.SetControl($conductorJacket) | Out-Null

# ModuleRoots is a bootstrap dependency. Register the Foundation file-system
# adapter, leaving the AzureSql implementation entirely to lazy resolution.
$rootAdapter = & (Get-Module SovereignTrust.Foundation) { [Storage_EmbeddedFileSystem]::new() }
$rootJacket = [pscustomobject]@{ Name = 'Modules'; VirtualPath = 'SovereignTrust.Adapters.Storage.EmbeddedFileSystem.ModuleRoots.Persistent.Read'; Addresses = @($moduleRoot) }
$rootAdapter.Construct($rootJacket) | Out-Null
$rootRegistration = Register-AdapterToMappedSlot -ConductorJacketSignal $conductor.Signal -Signal $runSignal -ConductionContext $conductor.Signal -Adapter $rootAdapter | Select-Object -Last 1
Assert (-not $rootRegistration.Failure()) 'ModuleRoots bootstrap registration failed.'

$global:AzureSqlLazyHydrationCalls = 0
$global:AzureSqlLazyFactoryCalls = 0
$foundation = Get-Module SovereignTrust.Foundation
& $foundation {
    $script:AzureSqlOriginalResolveModuleFromAdapter = (Get-Command Resolve-ModuleFromAdapter).ScriptBlock
    Set-Item Function:script:Resolve-ModuleFromAdapter -Value {
        param([Signal]$Signal, [string]$Slot, [string]$ModuleName, [string]$RelativePath)
        $resolved = & $script:AzureSqlOriginalResolveModuleFromAdapter -Signal $Signal -Slot $Slot -ModuleName $ModuleName -RelativePath $RelativePath | Select-Object -Last 1
        if (-not $resolved.Failure() -and $ModuleName -ceq 'Data_AzureSql.psd1') {
            Set-Item Function:script:Resolve-Data_AzureSql -Value {
                $global:AzureSqlLazyFactoryCalls++
                return & (Get-Module Data_AzureSql) { Resolve-Data_AzureSql }
            }
            & (Get-Module Data_AzureSql) {
                Set-Item Function:script:Invoke-AzureSqlExecution -Value {
                    param($Adapter, $Slot, $Activity, $Config, $Plan, $NormalizedWrite, $ConductionSignal, $ItemSignal)
                    if ($Slot -cne 'FusionDatabase' -or $Activity -cne 'Query' -or
                        $Adapter.Configuration.Resource -cne 'sda-fusion' -or $Adapter.Configuration.Addresses[0] -cne 'sda-dev.database.windows.net') {
                        throw 'Lazy route did not preserve the hydrated adapter.'
                    }
                    return '{"Operation":"Query","RowsAffected":null,"OutputParameters":{},"ResultSets":[]}'
                }
            }
        }
        return $resolved
    }
    Set-Item Function:script:Invoke-CondenserAdapter -Value {
        param($Slot, $Activity, $Plan, $Signal, $ItemSignal)
        if ($Slot -cne 'Hydration' -or $Activity -cne 'Invoke') { throw 'Unexpected hydration invocation.' }
        $global:AzureSqlLazyHydrationCalls++
        $merged = $ItemSignal.GetJacket().GetResult()
        if ($merged.Resource -cne 'sda-fusion') { throw 'The configured jacket was not passed to hydration.' }
        $hydrated = [pscustomobject]@{
            Name = $merged.Name; VirtualPath = $merged.VirtualPath; IsMapped = $merged.IsMapped
            Resource = $merged.Resource
            Addresses = @($merged.Addresses)
            HydrationMarker = 'synthetic-lazy-handoff'
        }
        $result = [Signal]::Start('AzureSqlLazy.Hydrated') | Select-Object -Last 1
        $result.SetResult($hydrated) | Out-Null
        return $result
    }
}

$sourceSignal = [Signal]::Start('AzureSqlLazy.Source') | Select-Object -Last 1
$sourceSignal.SetResult($sourceJacket) | Out-Null
$loaderItem = [Signal]::Start('AzureSqlLazy.LoaderItem') | Select-Object -Last 1
$loaderItem.SetJacket($sourceSignal) | Out-Null
$fab = & $foundation { [FabCondenser]::new() }
$registration = $fab.Invoke('Fab', 'Invoke', $runSignal, $null, $loaderItem) | Select-Object -Last 1
Assert (-not $registration.Failure()) 'Production lazy jacket registration failed.'
Assert (-not (Get-Module Data_AzureSql)) 'Registration loaded AzureSql before first use.'

$itemSignal = [Signal]::Start('AzureSqlLazy.Item') | Select-Object -Last 1
$itemSignal.SetPointer($conductor.Signal.GetPointer()) | Out-Null
$plan = [pscustomobject]@{ Adapter = 'Data.FusionDatabase'; Activity = 'Query'; Config = [pscustomobject]@{ CommandText = 'SELECT 1'; Parameters = @() } }
$result = Invoke-MappedAdapter -Adapter $plan.Adapter -Activity $plan.Activity -Signal $runSignal -Plan $plan -ItemSignal $itemSignal | Select-Object -Last 1
Assert (-not $result.Failure()) 'The first mapped invocation failed during lazy resolution.'
$loadedModule = & $foundation { Get-Module Data_AzureSql }
Assert ($null -ne $loadedModule -and $loadedModule.Path -eq (Resolve-Path (Join-Path $PSScriptRoot '../PowerShell/Data_AzureSql.psm1')).ProviderPath) 'Production resolution did not load the packaged AzureSql module.'
Assert ($global:AzureSqlLazyHydrationCalls -eq 1) 'Hydration did not run exactly once.'
Assert ($global:AzureSqlLazyFactoryCalls -eq 1) 'Production resolution did not invoke Resolve-Data_AzureSql exactly once.'
$resolved = $registration.GetResult()
Assert ($resolved.State -eq 'Resolved' -and $resolved.Instance.GetType().Name -ceq 'Data_AzureSql') 'The lazy registration did not construct Data_AzureSql.'
Assert ($resolved.Instance.Configuration.Resource -ceq 'sda-fusion' -and $resolved.Instance.Configuration.Addresses[0] -ceq 'sda-dev.database.windows.net' -and
    $resolved.Instance.Configuration.HydrationMarker -ceq 'synthetic-lazy-handoff') 'Construct did not receive the hydrated jacket.'
Write-Output 'PASS: initially unloaded, production lazy registration, packaged module import, hydration, Construct, and mapped route.'
