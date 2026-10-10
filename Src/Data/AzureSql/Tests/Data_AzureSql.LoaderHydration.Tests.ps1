using module SignalGraph

$ErrorActionPreference = 'Stop'
$foundationManifest = Join-Path $PSScriptRoot '../../../../../SovereignTrust.Foundation/Src/PowerShell/SovereignTrust.Foundation.psd1'
$adapterManifest = Join-Path $PSScriptRoot '../PowerShell/Data_AzureSql.psd1'
$configPath = Join-Path $PSScriptRoot '../../../../../SDAFusion-Content/SDA/Config/SDAFusionApp.Json'
Import-Module (Resolve-Path $foundationManifest).ProviderPath -Force
Import-Module (Resolve-Path $adapterManifest).ProviderPath -Force

function Assert([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }

$config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json -Depth 100
$sourceJacket = @($config.Agents | Where-Object Name -eq 'sdadev01')[0].Roles.SDAWorkItems.Adapters |
    Where-Object Name -eq 'SDAFusionDatabase' | Select-Object -First 1
Assert ($null -ne $sourceJacket -and $sourceJacket.Resource -ceq 'sda-fusion') 'Selected jacket must name the configured database.'

$global:AzureSqlHydrationObserved = $false
$global:AzureSqlHydrationBoundaryCount = 0
$foundation = Get-Module SovereignTrust.Foundation
& $foundation {
    # Keep the production loader, merge, Construct, and registration logic.
    # Module discovery is isolated because Prompt H covers fresh-process loading.
    Set-Item -Path Function:script:Resolve-DependencyModuleFromGraph -Value {
        param([Signal]$Signal, [object]$ConductionContext, [string]$WirePath)
        if ($WirePath -cne 'SovereignTrust.Adapters.Data.AzureSql.FusionDatabase.Persistent.Full') {
            throw 'Loader received an unexpected virtual path.'
        }
        return Resolve-ModulePathSignal -WirePath $WirePath
    }
    Set-Item -Path Function:script:Invoke-CondenserAdapter -Value {
        param([string]$Slot, [string]$Activity, [object]$Plan, [Signal]$Signal, [object]$ItemSignal)
        if ($Slot -cne 'Hydration' -or $Activity -cne 'Invoke' -or
            $Plan.HydrationStyle -cne 'Deferred' -or $Plan.Path -cne '%.@') {
            throw 'Loader used an unexpected hydration boundary.'
        }
        $global:AzureSqlHydrationBoundaryCount++
        $merged = $ItemSignal.GetJacket().GetResult()
        if ($merged.Resource -cne 'sda-fusion' -or
            $merged.VirtualPath -cne 'SovereignTrust.Adapters.Data.AzureSql.FusionDatabase.Persistent.Full' -or
            $merged.Addresses[0] -cne 'sda-dev.database.windows.net') {
            throw 'Hydration boundary did not receive the selected jacket intact.'
        }
        $global:AzureSqlHydrationObserved = $true
        $hydrated = [PSCustomObject]@{
            Name = $merged.Name
            VirtualPath = $merged.VirtualPath
            IsMapped = $merged.IsMapped
            Resource = $merged.Resource
            Addresses = @($merged.Addresses)
            HydrationMarker = 'synthetic-loader-handoff'
        }
        $result = [Signal]::Start('AzureSqlHydration.Synthetic') | Select-Object -Last 1
        $result.SetResult($hydrated) | Out-Null
        return $result
    }
}

$bootstrap = [Signal]::Start('AzureSqlHydration.Bootstrap') | Select-Object -Last 1
$bootstrap.SetResult([PSCustomObject]@{}) | Out-Null
$conductorSignal = New-Conductor -HostConductor $null -ConductionSignal $bootstrap | Select-Object -Last 1
Assert (-not $conductorSignal.Failure() -and $conductorSignal.HasResult()) 'Could not create conductor for loader test.'
$conductor = $conductorSignal.GetResult()
$runSignal = [Signal]::Start('AzureSqlHydration.Run') | Select-Object -Last 1
$runSignal.SetJacket($conductor.Signal) | Out-Null
$runSignal.SetPointer($conductor.Signal.GetPointer()) | Out-Null
$conductorJacket = [Signal]::Start('AzureSqlHydration.Conductor') | Select-Object -Last 1
$conductorJacket.SetJacket($conductor.Signal) | Out-Null
$conductorJacket.SetPointer($conductor.Signal.GetPointer()) | Out-Null
$runSignal.SetControl($conductorJacket) | Out-Null
$sourceSignal = [Signal]::Start('AzureSqlHydration.SelectedJacket') | Select-Object -Last 1
$sourceSignal.SetResult($sourceJacket) | Out-Null

$resolution = & $foundation {
    param($loaderSignal, $context, $selectedJacket)
    Resolve-AdapterFromJacket -Signal $loaderSignal -ConductionContext $context -Jacket $selectedJacket | Select-Object -Last 1
} $runSignal $runSignal $sourceSignal
if ($resolution.Failure() -or -not $resolution.HasResult()) {
    $details = @($resolution.GetEntries() | ForEach-Object Message) -join ' | '
    throw "Production loader did not resolve the selected jacket. $details"
}
Assert ($global:AzureSqlHydrationObserved -and $global:AzureSqlHydrationBoundaryCount -eq 1) 'Loader hydration boundary did not run exactly once.'
$adapter = $resolution.GetResult()
Assert ($adapter.GetType().Name -ceq 'Data_AzureSql') 'Loader did not create Data_AzureSql.'
Assert ($adapter.Configuration.Resource -ceq 'sda-fusion' -and
    $adapter.Configuration.HydrationMarker -ceq 'synthetic-loader-handoff') 'Construct did not receive the hydrated jacket.'
Assert ($adapter.Configuration.VirtualPath -ceq $sourceJacket.VirtualPath -and
    $adapter.Configuration.Addresses[0] -ceq $sourceJacket.Addresses[0]) 'Construct lost virtual path or SQL address.'
Assert ($sourceJacket.Resource -ceq 'sda-fusion') 'Loader changed the selected source jacket.'

$registration = Register-AdapterToMappedSlot -ConductorJacketSignal $conductor.Signal `
    -Signal $runSignal -ConductionContext $conductor.Signal -Adapter $adapter | Select-Object -Last 1
Assert (-not $registration.Failure()) 'Real mapped registration failed.'
$adapterModule = Get-Module Data_AzureSql
& $adapterModule {
    Set-Item -Path Function:script:Invoke-AzureSqlExecution -Value {
        param($Adapter, $Slot, $Activity, $Config, $Plan, $ConductionSignal, $ItemSignal)
        if ($Slot -cne 'FusionDatabase' -or $Adapter.Configuration.Resource -cne 'sda-fusion') {
            throw 'Mapped route did not receive the loaded adapter.'
        }
        return '{"Operation":"Query","RowsAffected":null,"OutputParameters":{},"ResultSets":[]}'
    }
}
$itemSignal = [Signal]::Start('AzureSqlHydration.Item') | Select-Object -Last 1
$itemSignal.SetPointer($conductor.Signal.GetPointer()) | Out-Null
$plan = [PSCustomObject]@{ Adapter = 'Data.FusionDatabase'; Activity = 'Query'; Config = [PSCustomObject]@{
    CommandText = 'SELECT 1'; Parameters = @()
} }
$routed = Invoke-MappedAdapter -Adapter $plan.Adapter -Activity $plan.Activity `
    -Signal $runSignal -Plan $plan -ItemSignal $itemSignal | Select-Object -Last 1
Assert (-not $routed.Failure() -and $routed.HasResult()) 'Registered FusionDatabase slot did not route.'
Assert (($routed.GetResult() | ConvertFrom-Json).Operation -ceq 'Query') 'Mapped route did not return JSON.'

Write-Output 'PASS: production loader hydration handoff precedes Construct and real registration binds FusionDatabase.'
