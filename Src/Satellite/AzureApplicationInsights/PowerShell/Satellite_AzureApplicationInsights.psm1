using module SignalGraph
$stModuleName = 'SovereignTrust.Foundation'
if (-not (Get-Module -Name $stModuleName)) {
    $stPath = Join-Path $PSScriptRoot "../../../../../SovereignTrust.Foundation/Src/PowerShell/SovereignTrust.Foundation.psd1"
    Import-Module (Resolve-Path $stPath).ProviderPath -Force
}

# ---- Load Network functions (your existing REST surface) ----
# Use your existing implementations here
# . "$PSScriptRoot/Read-StorageNetworkApi.ps1"
# Optional if you have them:
# . "$PSScriptRoot/Delete-StorageNetworkMessageApi.ps1"
# . "$PSScriptRoot/Update-StorageNetworkVisibilityApi.ps1"
# . "$PSScriptRoot/Write-StorageNetworkApi.ps1"

class Satellite_AzureApplicationInsights {
    [object]$MappedAdapter
    [Signal]$Signal

    Satellite_AzureApplicationInsights() { }

    Satellite_AzureApplicationInsights([object]$mappedAdapter) {
        $this.MappedAdapter = $mappedAdapter
    }

    [Signal] Construct([object]$dictionary) {
        $opSignal = [Signal]::Start("Satellite_AzureApplicationInsights.Construct") | Select-Object -Last 1

        try {
            if ($null -eq $dictionary) {
                $opSignal.LogCritical("Cannot construct Satellite_AzureApplicationInsights — provided dictionary is null.")
                return $opSignal
            }

            $this.Signal = [Signal]::Start("Satellite_AzureApplicationInsights") | Select-Object -Last 1

            $jacket = [Signal]::Start("Satellite_AzureApplicationInsights.Jacket") | Select-Object -Last 1
            $jacket.SetResult($dictionary)

            $this.Signal.SetJacket($jacket)
            $opSignal.LogInformation("Satellite_AzureApplicationInsights constructed successfully with provided jacket.")
        }
        catch {
            $opSignal.LogCritical("Error constructing Satellite_AzureApplicationInsights: $_")
        }

        return $opSignal
    }

    # ---------------------------------------------------------------------
    # Universal Invoke entry 
    # Activity uses canonical verb set: ReadBatch, PeekBatch, AckItem, DeferItem, WriteItem
    # ---------------------------------------------------------------------
    [Signal] Invoke(
        [string]$Slot,
        [string]$Activity,
        [Signal]$ConductionSignal,
        [object]$Plan,
        [Signal]$ItemSignal
    ) {
        $opSignal = [Signal]::Start("Satellite_AzureApplicationInsights.Invoke:$Slot.$Activity", $ConductionSignal) | Select-Object -Last 1

        try {
            if (-not $ConductionSignal) {
                $opSignal.LogCritical("Null ConductionSignal passed to Satellite_AzureApplicationInsights.Invoke()")
                return $opSignal
            }

            if (-not $Activity) {
                $opSignal.LogWarning("No Activity provided to Satellite_AzureApplicationInsights.Invoke()")
                return $opSignal
            }

            # Resolve Config from Plan (or from Environment if you prefer)
            # Convention: Plan contains everything needed to hit the service for this step
            $configSignal = Resolve-PathFromDictionary -Dictionary $Plan -Path "Config" -SignalLevel "Warning" | Select-Object -Last 1
            $config = $configSignal.HasResult() ? $configSignal.GetResult() : $null

            if (-not $config) {
                # Optional fallback: pull config from Environment/Jacket
                # $env = $ConductionSignal.GetJacket().GetResult()
                # $configSignal = Resolve-PathFromDictionary -Dictionary $env -Path "Network.StorageNetwork.Config" -SignalLevel "Warning" | Select-Object -Last 1
                $opSignal.LogWarning("StorageNetwork Config not found on Plan.Config (no fallback enabled).")
            }

            $resultSignal = $null

            switch ($Activity) {
                # Review pattern, this is too specific to telemetry or could it be the same for signalr, etc?
                "EmitSignalFull" {

#                    $this.Invoke($Slot, "EmitEntries", $ConductionSignal, $Plan, $ItemSignal)
#                    $this.Invoke($Slot, "EmitSignal", $ConductionSignal, $Plan, $ItemSignal)

#                    $entriesSignal = Resolve-PathFromDictionary -Dictionary $ItemSignal -Path "*.#.Entries.@" | Select-Object -Last 1
                    foreach ($entry in $ItemSignal.Entries)
                    {
                        $entry.AddTag("Skip")
                    }
#>
#                    $ItemSignal.AddTag("Skip")

<#
                    foreach ($entry in $EmitSignal.Entries)
                    {
                        $entry.AddTag("Skip")
                    }
#>
                    break
                }
                { $_ -in @("EmitEntries", "EmitSignal") } {
                    # The App Insights Network Adapter prepares a custom plan to pass to its body. 
                    # Use the plan to run a conduction that will grab the plan from the cache and run it passing through the signal in ItemSignal which will generate the content and send it to App Insights       
# PlanTokens provide routes to plans held in conductor cache (or elsewhere, example: "EmitEntries":"Memory.Cache.TelemetryPlans.Telemetry.EmitEntries")
                    $PlanTokenSignal = Resolve-PathFromDictionary -Dictionary $this.Signal -Path "%.@.PlanTokens.$($Activity)" | Select-Object -Last 1

                    $TokenPlan = [PSCustomObject]@{
                        Key = $PlanTokenSignal.GetResult()
                    }

                    $planLookupSignal = [Signal]::Start("Satellite_AzureApplicationInsights.HandleItem.$($ItemSignal.Name)", $ItemSignal) | Select-Object -Last 1
                    $planLookupSignal.SetResult($PlanTokenSignal.GetResult());
                    $cachedPlanSignal = Invoke-CondenserAdapter -Slot "Token" -Signal $ConductionSignal -ItemSignal $PlanTokenSignal -Activity "Parse" -Plan $TokenPlan | Select-Object -Last 1
                    if ($opSignal.MergeSignalAndVerifyFailure($cachedPlanSignal)) {return $opSignal}

                    $clonedCachePlan = $cachedPlanSignal.GetResult() | ConvertTo-Json -Depth 10 | ConvertFrom-Json -Depth 10
                    $conductionSignal = Invoke-CondenserAdapter -Slot "Conduction" -Signal $ConductionSignal -ItemSignal $ItemSignal -Activity "ST" -Plan $clonedCachePlan | Select-Object -Last 1
                    if ($opSignal.MergeSignalAndVerifyFailure($conductionSignal)) {return $opSignal}
                    
                    break
                }
                "SendMessage" {
                    # The App Insights Network Adapter prepares a custom plan to pass to its body. 
                     $bodyPathSignal = Resolve-PathFromDictionary -Dictionary $Plan -Path "Path" | Select-Object -Last 1

                    $ContentPlan = [PSCustomObject]@{
                        Path = $bodyPathSignal.GetResult()
#                                HydrationPlan = "@"
                    }

                    $SourceContentResultSignal = Invoke-MappedAdapter -Adapter "Token.Memory"  -Activity "Get" -Plan $ContentPlan -ItemSignal $ItemSignal -Signal $ConductionSignal | Select-Object -Last 1

                    $uriSignal= Resolve-PathFromDictionary -Dictionary $this.Signal -Path "%.@.Addresses" | Select-Object -Last 1
#                    $resourceSignal= Resolve-PathFromDictionary -Dictionary $this.Signal -Path "%.@.Resource" | Select-Object -Last 1
                    
                    $RestPlan = [PSCustomObject]@{
                        Config = [PSCustomObject]@{
                            Body = $SourceContentResultSignal.GetResult()
                            Method = "Post"
                            SkipBearerToken = $true
                            Uri = $uriSignal.GetResult()
                        }
                    }

                    # Call Rest Endpoint
                    $responseSignal = Invoke-MappedAdapter -Adapter "Condenser.Rest" -Activity "Post" -Signal $ConductionSignal -Plan $RestPlan -ItemSignal $ItemSignal
                    if ($opSignal.MergeSignalAndVerifyFailure($responseSignal)) { return $opSignal }
                    #$responseJacketSignal.SetJacket($responseSignal)

                    $opSignal.SetResult($responseSignal.GetResult())
                    break   
                }


                default {
                    $opSignal.LogWarning("Unsupported Activity: $Activity")
                    $resultSignal = [Signal]::Start("StorageNetwork.UnsupportedActivity", $ItemSignal) | Select-Object -Last 1
                    break
                }
            }

            if ($resultSignal) {
                $opSignal.MergeSignal($resultSignal)
                if ($resultSignal.Success()) {
                    $opSignal.SetResult($resultSignal.GetResult($true))
                    $opSignal.LogInformation("✅ $Slot.$Activity succeeded.")
                } else {
                    $opSignal.LogWarning("$Slot.$Activity did not succeed.")
                }
            }

        }
        catch {
            $opSignal.LogCritical("🔥 Exception in Satellite_AzureApplicationInsights.Invoke: $($_.Exception.Message)", $null, $_)
        }

        return $opSignal
    }
}

function Resolve-Satellite_AzureApplicationInsights {
    $object = [Satellite_AzureApplicationInsights]::new()
    return $object
}

Export-ModuleMember -Function Resolve-Satellite_AzureApplicationInsights
