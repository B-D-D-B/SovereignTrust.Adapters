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
    # Activities: EmitEntries, EmitSignal, SendMessage, HandleResponse, EmitSignalFull
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
                    $handledKey = "TelemetryHandled_$Activity"
                    if ($null -eq $ItemSignal.GetPointer()) {
                        $opSignal.LogCritical('Telemetry emission requires an item graph.')
                        return $opSignal
                    }
                    if ($ItemSignal.GetPointer().Grid.Contains($handledKey)) {
                        $clear = $ItemSignal.GetPointer().UnregisterSignal($handledKey) | Select-Object -Last 1
                        if ($opSignal.MergeSignalAndVerifyFailure($clear)) { return $opSignal }
                    }
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
                    $conductionFailed = $opSignal.MergeSignalAndVerifyFailure($conductionSignal)
                    $handledSignal = Resolve-PathFromDictionary -Dictionary $ItemSignal -Path "*.#.$handledKey.@" | Select-Object -Last 1
                    if ($handledSignal.HasResult() -and $null -ne $handledSignal.GetResult()) {
                        $handled = $handledSignal.GetResult()
                        if ($null -ne $handled.PSObject.Properties['Result'] -and $handled.Result -is [bool]) {
                            $opSignal.SetResult($handled)
                        }
                    }
                    if (-not $opSignal.HasResult() -and -not $conductionFailed) {
                        $opSignal.LogCritical("Missing handled telemetry result at $handledKey.")
                    }
                    if ($conductionFailed) { return $opSignal }
                    
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
                    if ($opSignal.MergeSignalAndVerifyFailure($SourceContentResultSignal) -or -not $SourceContentResultSignal.HasResult()) {
                        if (-not $opSignal.Failure()) { $opSignal.LogCritical('Telemetry body is missing.') }
                        return $opSignal
                    }
                    $body = $SourceContentResultSignal.GetResult()
                    if ($body -isnot [string] -or [string]::IsNullOrWhiteSpace($body)) {
                        $opSignal.LogCritical('Telemetry body must be nonempty JSON text.')
                        return $opSignal
                    }
                    $itemsSent = 0
                    try {
                        $json = [System.Text.Json.JsonDocument]::Parse($body)
                        try {
                            $root = $json.RootElement
                            if ($root.ValueKind -eq [System.Text.Json.JsonValueKind]::Object) { $itemsSent = 1 }
                            elseif ($root.ValueKind -eq [System.Text.Json.JsonValueKind]::Array) {
                                $itemsSent = $root.GetArrayLength()
                                foreach ($element in $root.EnumerateArray()) {
                                    if ($element.ValueKind -ne [System.Text.Json.JsonValueKind]::Object) { throw 'Telemetry array contains a nonobject item.' }
                                }
                            }
                            else { throw 'Telemetry body must be an object or array of objects.' }
                            if ($itemsSent -le 0) { throw 'Telemetry body contains no items.' }
                        } finally { $json.Dispose() }
                    } catch {
                        $opSignal.LogCritical("Invalid telemetry body: $($_.Exception.Message)")
                        return $opSignal
                    }
                    $countKeySignal = Resolve-PathFromDictionary -Dictionary $Plan -Path 'Config.CountKey' | Select-Object -Last 1
                    if (-not $countKeySignal.HasResult() -or [string]::IsNullOrWhiteSpace([string]$countKeySignal.GetResult()) -or $null -eq $ItemSignal.GetPointer()) {
                        $opSignal.LogCritical('SendMessage requires Config.CountKey and an item graph.')
                        return $opSignal
                    }
                    $countWrite = $ItemSignal.GetPointer().RegisterResultAsSignal([string]$countKeySignal.GetResult(), $itemsSent) | Select-Object -Last 1
                    if ($opSignal.MergeSignalAndVerifyFailure($countWrite)) { return $opSignal }

                    $uriSignal= Resolve-PathFromDictionary -Dictionary $this.Signal -Path "%.@.Addresses" | Select-Object -Last 1
#                    $resourceSignal= Resolve-PathFromDictionary -Dictionary $this.Signal -Path "%.@.Resource" | Select-Object -Last 1
                    
                    $RestPlan = [PSCustomObject]@{
                        Config = [PSCustomObject]@{
                            Body = $body
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
                'HandleResponse' {
                    $rawSignal = Resolve-PathFromDictionary -Dictionary $Plan -Path 'Config.RawResponse' | Select-Object -Last 1
                    $sentSignal = Resolve-PathFromDictionary -Dictionary $Plan -Path 'Config.ItemsSent' | Select-Object -Last 1
                    $keySignal = Resolve-PathFromDictionary -Dictionary $Plan -Path 'Config.HandledResultKey' | Select-Object -Last 1
                    if (-not $rawSignal.HasResult() -or $null -eq $rawSignal.GetResult() -or
                        -not $sentSignal.HasResult() -or -not $keySignal.HasResult() -or
                        [string]::IsNullOrWhiteSpace([string]$keySignal.GetResult()) -or $null -eq $ItemSignal.GetPointer()) {
                        $opSignal.LogCritical('HandleResponse requires raw response, sent count, result key, and item graph.')
                        return $opSignal
                    }
                    $raw = $rawSignal.GetResult()
                    if ($raw -is [string]) {
                        try { $raw = $raw | ConvertFrom-Json -Depth 30 -ErrorAction Stop }
                        catch { $opSignal.LogCritical('HandleResponse raw response is invalid JSON.'); return $opSignal }
                    }
                    if ($raw -isnot [System.Collections.IDictionary] -and $raw -isnot [pscustomobject]) {
                        $opSignal.LogCritical('HandleResponse raw response must be a property bag.')
                        return $opSignal
                    }
                    if ($raw -is [System.Collections.IDictionary]) { $raw = [pscustomobject]$raw }
                    $receivedProperty = $raw.PSObject.Properties['itemsReceived']
                    $acceptedProperty = $raw.PSObject.Properties['itemsAccepted']
                    $errorsProperty = $raw.PSObject.Properties['errors']
                    if ($null -eq $receivedProperty -or $null -eq $acceptedProperty) {
                        $opSignal.LogCritical('HandleResponse receipt lacks required counts.')
                        return $opSignal
                    }
                    $values = @($sentSignal.GetResult(), $receivedProperty.Value, $acceptedProperty.Value)
                    foreach ($value in $values) {
                        if ($null -eq $value -or $value.GetType().FullName -notin @(
                            'System.Byte', 'System.SByte', 'System.Int16', 'System.UInt16',
                            'System.Int32', 'System.UInt32', 'System.Int64', 'System.UInt64')) {
                            $opSignal.LogCritical('HandleResponse counts must be whole nonnegative integers.')
                            return $opSignal
                        }
                    }
                    try {
                        $itemsSent = [long]$values[0]
                        $itemsReceived = [long]$values[1]
                        $itemsAccepted = [long]$values[2]
                    } catch { $opSignal.LogCritical('HandleResponse count exceeds supported range.'); return $opSignal }
                    if ($itemsSent -le 0 -or $itemsReceived -lt 0 -or $itemsAccepted -lt 0 -or
                        $itemsAccepted -gt $itemsReceived -or $itemsReceived -gt $itemsSent -or
                        ($null -ne $errorsProperty -and $null -ne $errorsProperty.Value -and $errorsProperty.Value -isnot [array])) {
                        $opSignal.LogCritical('HandleResponse receipt counts or errors are invalid.')
                        return $opSignal
                    }
                    $handled = [pscustomobject]@{
                        ItemsReceived = $itemsReceived
                        ItemsAccepted = $itemsAccepted
                        Result = [bool]($itemsAccepted -eq $itemsSent)
                    }
                    $write = $ItemSignal.GetPointer().RegisterResultAsSignal([string]$keySignal.GetResult(), $handled) | Select-Object -Last 1
                    if ($opSignal.MergeSignalAndVerifyFailure($write)) { return $opSignal }
                    $opSignal.SetResult($handled)
                    if ($null -ne $errorsProperty -and $null -ne $errorsProperty.Value) {
                        $index = 0
                        foreach ($errorItem in $errorsProperty.Value) {
                            $code = if ($null -ne $errorItem) { $errorItem.code } else { $null }
                            $message = if ($null -ne $errorItem) { $errorItem.message } else { $null }
                            $opSignal.LogCritical("Application Insights error[$index]: code=$code message=$message")
                            $index++
                        }
                    }
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
