using module SignalGraph

$ErrorActionPreference = 'Stop'
$foundationManifest = Join-Path $PSScriptRoot '../../../../../SovereignTrust.Foundation/Src/PowerShell/SovereignTrust.Foundation.psd1'
$adapterManifest = Join-Path $PSScriptRoot '../PowerShell/Data_AzureSql.psd1'
Import-Module (Resolve-Path $foundationManifest).ProviderPath -Force
Import-Module (Resolve-Path $adapterManifest).ProviderPath -Force

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

# Exercise the generic mapped data route with a synthetic jacket and an
# internal test execution seam. This test does not model SQL execution.
$module = Get-Module Data_AzureSql
& $module {
    Set-Item -Path Function:script:Invoke-AzureSqlExecution -Value {
        param($Adapter, $Slot, $Activity, $Config, $Plan, $ConductionSignal, $ItemSignal)
        if ($Slot -ne 'FusionDatabase' -or $Activity -ne 'Query' -or
            $Adapter.Configuration.Resource -ne 'synthetic-test-resource' -or
            $Adapter.Configuration.Addresses[0] -ne 'https://key-vault.example/' -or
            $Config.Parameters.'@Id' -ne 7 -or $Config.CommandTimeoutSeconds -ne 15) {
            throw 'Mapped route did not preserve slot, jacket, or plan configuration.'
        }
        return '{"Operation":"Query","RowsAffected":null,"OutputParameters":{},"ResultSets":[]}'
    }
}

$bootstrap = [Signal]::Start('AzureSqlRouting.Bootstrap') | Select-Object -Last 1
$bootstrap.SetResult([PSCustomObject]@{}) | Out-Null
$conductorSignal = New-Conductor -HostConductor $null -ConductionSignal $bootstrap | Select-Object -Last 1
Assert-True (-not $conductorSignal.Failure() -and $conductorSignal.HasResult()) 'Could not initialize the routing graph.'
$conductor = $conductorSignal.GetResult()

$conductorJacket = [Signal]::Start('AzureSqlRouting.Conductor') | Select-Object -Last 1
$conductorJacket.SetJacket($conductor.Signal) | Out-Null
$conductorJacket.SetPointer($conductor.Signal.GetPointer()) | Out-Null
$runSignal = [Signal]::Start('AzureSqlRouting.Run') | Select-Object -Last 1
$runSignal.SetControl($conductorJacket) | Out-Null
$runSignal.SetPointer($conductor.Signal.GetPointer()) | Out-Null
$itemSignal = [Signal]::Start('AzureSqlRouting.Item') | Select-Object -Last 1
$itemSignal.SetPointer($conductor.Signal.GetPointer()) | Out-Null

$azureSql = Resolve-Data_AzureSql
# Model the loader's deferred hydration handoff with a synthetic resource.
# The real Key Vault lookup belongs to the gated integration suite.
$jacket = [PSCustomObject]@{
    Name = 'SDAFusionDatabase'; Kind = 'Data'; Slot = 'FusionDatabase'
    VirtualPath = 'SovereignTrust.Adapters.Data.AzureSql.FusionDatabase.Persistent.Full'
    Resource = '[Storage.Secrets.Read.sdafusion-sqldatabase|]'
    Addresses = @('https://key-vault.example/')
}
$jacket.Resource = 'synthetic-test-resource'
$construct = $azureSql.Construct($jacket)
Assert-True (-not $construct.Failure()) 'Could not construct AzureSql adapter.'
$registration = Register-AdapterToMappedSlot -ConductorJacketSignal $conductor.Signal `
    -Signal $runSignal -ConductionContext $conductor.Signal -Adapter $azureSql | Select-Object -Last 1
Assert-True (-not $registration.Failure()) 'Could not bind FusionDatabase to MappedDataAdapter.'

$plan = [PSCustomObject]@{ Adapter = 'Data.FusionDatabase'; Activity = 'Query'; Config = [PSCustomObject]@{
    CommandText = 'select Id from dbo.Records where Id = @Id'; Parameters = @{ '@Id' = 7 }; CommandTimeoutSeconds = 15
} }
$before = $plan | ConvertTo-Json -Depth 100 -Compress
$result = Invoke-MappedAdapter -Adapter $plan.Adapter -Activity $plan.Activity -Signal $runSignal -Plan $plan -ItemSignal $itemSignal | Select-Object -Last 1
Assert-True (-not $result.Failure() -and $result.HasResult()) 'Data.FusionDatabase routing failed.'
Assert-True (($result.GetResult() | ConvertFrom-Json).Operation -eq 'Query') 'The JSON result was not forwarded.'
Assert-True (($plan | ConvertTo-Json -Depth 100 -Compress) -eq $before) 'Mapped routing changed the caller plan.'

Write-Output 'PASS: Data.FusionDatabase -> MappedDataAdapter -> FusionDatabase -> Data_AzureSql routing and signal propagation.'
