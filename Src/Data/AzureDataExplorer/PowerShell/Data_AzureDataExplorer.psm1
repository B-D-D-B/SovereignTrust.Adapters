using module SignalGraph
$sgModuleName = 'SovereignTrust.Foundation'
if (-not (Get-Module -Name $sgModuleName)) {
    $sgPath = Join-Path $PSScriptRoot "../../../../../SovereignTrust.Foundation/Src/PowerShell/SovereignTrust.Foundation.psd1"
    Import-Module (Resolve-Path $sgPath).ProviderPath -Force
}

# Load all files (functions + classes)
. "$PSScriptRoot/Invoke-Data_AzureDataExplorer.ps1"
. "$PSScriptRoot/Invoke-AzureDataExplorerAdmin.ps1"

class Data_AzureDataExplorer {
    [object]$MappedAdapter
    [Signal]$Signal

    Data_AzureDataExplorer() {
    }

    Data_AzureDataExplorer([object]$mappedAdapter) {
        $this.MappedAdapter = $mappedAdapter
    }

    [Signal] Construct([object]$dictionary) {
        $opSignal = [Signal]::Start("Data_AzureDataExplorer") | Select-Object -Last 1

        try {
            if ($null -eq $dictionary) {
                return $opSignal.LogCritical("Cannot construct Data_AzureDataExplorer — provided dictionary is null.")
            }

            $this.Signal = [Signal]::Start("Data_AzureDataExplorer") | Select-Object -Last 1

            $jacket = [Signal]::Start("Data_AzureDataExplorer") | Select-Object -Last 1 
            
            $this.Signal.SetJacket($jacket)
            $jacket.SetResult($dictionary)
            $opSignal.LogInformation("Data_AzureDataExplorer constructed successfully with provided jacket.")
        }
        catch {
            $opSignal.LogCritical("Error constructing Data_AzureDataExplorer: $_")
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
        $opSignal = [Signal]::Start("Data_AzureDataExplorer.Invoke:$Slot.$Activity", $ItemSignal) | Select-Object -Last 1

        try {
            if (-not $ConductionSignal) {
                $opSignal.LogCritical("Null ConductionSignal passed to Data_AzureDataExplorer.Invoke()")
                return $opSignal
            }

            $opSignal.SetJacket($ConductionSignal)

            if (-not $Activity) {
                $opSignal.LogCritical("No Activity provided to Data_AzureDataExplorer.Invoke()")
                return $opSignal
            }

            if ($Activity -eq 'Admin') {
                $adminSignal = Invoke-AzureDataExplorerAdmin -Adapter $this -Plan $Plan
                if ($opSignal.MergeSignalAndVerifyFailure($adminSignal)) { return $opSignal }
                if (-not $adminSignal.HasResult()) {
                    $opSignal.LogCritical('Admin completed without a result.')
                    return $opSignal
                }
                $opSignal.SetResult($adminSignal.GetResult())
                return $opSignal
            }

            # Resolve Config from Plan (or from Environment if you prefer)
            # Convention: Plan contains everything needed to hit the service for this step
            $configSignal = Resolve-PathFromDictionary -Dictionary $Plan -Path "Config" -SignalLevel "Warning" | Select-Object -Last 1
            $config = $configSignal.HasResult() ? $configSignal.GetResult() : $null

            if (-not $config) {
                # Optional fallback: pull config from Environment/Jacket
                # $env = $ConductionSignal.GetJacket().GetResult()
                # $configSignal = Resolve-PathFromDictionary -Dictionary $env -Path "Queue.StorageQueue.Config" -SignalLevel "Warning" | Select-Object -Last 1
                $opSignal.LogWarning("StorageQueue Config not found on Plan.Config (no fallback enabled).")
            }

            $resultSignal = $null

            switch ($Activity) {

                # ---------------------------------------------------------
                # Canonical verbs
                # ---------------------------------------------------------

                "Query" {
                    return $opSignal.LogCritical('Data AzureDataExplorer Query is not implemented.')
                }

                "WriteItem" {
                    $TableNameSignal = Resolve-PathFromDictionary -Dictionary $Plan -Path "Config.TableName"  | Select-Object -Last 1
                    $MappingNameSignal = Resolve-PathFromDictionary -Dictionary $Plan -Path "Config.MappingName"  | Select-Object -Last 1
                    if ($opSignal.MergeSignalAndVerifyFailure($TableNameSignal) -or $opSignal.MergeSignalAndVerifyFailure($MappingNameSignal)) {
                        return $opSignal
                    }

                    $ContentKeySignal = Resolve-PathFromDictionary -Dictionary $Plan -Path "Config.ContentKey" -Default "Content" | Select-Object -Last 1
                    $ContentKey = $ContentKeySignal.GetResult()

                    $RowsSignal = Resolve-PathFromDictionary -Dictionary $ItemSignal -Path "*.#.$ContentKey.@" | Select-Object -Last 1
                    if ($opSignal.MergeSignalAndVerifyFailure($RowsSignal)) { return $opSignal }

                    $Rows = $RowsSignal.GetResult()
                    $TableName = $TableNameSignal.GetResult()
                    $MappingName = $MappingNameSignal.GetResult()

                    # Query 
                    $Querystring = "?streamFormat=json&mappingName=$($MappingName)"


                    if ($Rows -is [string]) {
                        $Rows = $Rows | ConvertFrom-Json
                    }

                    $Body = (@($Rows) | ForEach-Object {
                                #$row = Resolve-JsonTokens -Dictionary $_ -ValueDictionary $Config
                                $_ | ConvertTo-Json -Depth 100 -Compress
                            }) -join "`n"

                    $clonePlan = (Resolve-ClonePlan -Plan $Plan | Select-Object -Last 1).GetResult()
                    $HostSignal = Resolve-PathFromDictionary -Dictionary $this.Signal -Path "%.@.Addresses" | Select-Object -Last 1
                    $HostAddress = $HostSignal.GetResult()

                    $ResourceSignal = Resolve-PathFromDictionary -Dictionary $this.Signal -Path "%.@.Resource" | Select-Object -Last 1
                    $Database = $ResourceSignal.GetResult()

                    $Url = "v1/rest/ingest/$Database/$TableName"

                    $null = Add-PathToDictionary -Dictionary $clonePlan -Path "Config.Uri" -Value "$HostAddress/$Url"
                    $null = Add-PathToDictionary -Dictionary $clonePlan -Path "Config.Method" -Value "Post"
                    $null = Add-PathToDictionary -Dictionary $clonePlan -Path "Config.Host" -Value "$HostAddress"
                    $null = Add-PathToDictionary -Dictionary $clonePlan -Path "Config.CacheAccessToken" -Value $true
                    $null = Add-PathToDictionary -Dictionary $clonePlan -Path "Config.Body" -Value $Body

                    $null = Add-PathToDictionary -Dictionary $clonePlan -Path "Config.Querystring" -Value $Querystring

                    # Call Rest Endpoint
                    $responseSignal = Invoke-MappedAdapter -Adapter "Condenser.Rest" -Activity "Get" -Signal $ConductionSignal -Plan $clonePlan -ItemSignal $ItemSignal
                    if ($opSignal.MergeSignalAndVerifyFailure($responseSignal)) { return $opSignal }

                    break
                }

                "WriteBatch" {
                    # Ack = delete message. Needs MessageId + PopReceipt.
                    # Expect the message to be in ItemSignal jacket/result depending on your pipeline.

                    $MessageIdSignal = Resolve-PathFromDictionary -Dictionary $ItemSignal -Path "%.@.MessageId" | Select-Object -Last 1
                    $PopReceiptSignal = Resolve-PathFromDictionary -Dictionary $ItemSignal -Path "%.@.PopReceipt" | Select-Object -Last 1

                    $MessageId = $MessageIdSignal.GetResult()
                    $PopReceipt = $PopReceiptSignal.GetResult()
                    
                    # DELETE {ServiceUrl}/{MessageId}?popreceipt={PopReceipt}
                    $querystring = "/{0}?popreceipt={1}" -f $MessageId, [Uri]::EscapeDataString($PopReceipt)

                    try {
                        $clonePlan = (Resolve-ClonePlan -Plan $Plan | Select-Object -Last 1).GetResult()
                        Add-PathToDictionary -Dictionary $clonePlan -Path "QueryString" -Value $querystring

                        $HostSignal = Resolve-PathFromDictionary -Dictionary $this.Signal -Path "%.@.Addresses" -Default 1 | Select-Object -Last 1
                        $HostAddress = $HostSignal.GetResult()

                        $UriSignal = Resolve-PathFromDictionary -Dictionary $this.Signal -Path "%.@.Resource" -Default 1 | Select-Object -Last 1
                        $Uri = $UriSignal.GetResult()

                        $null = Add-PathToDictionary -Dictionary $clonePlan -Path "Uri" -Value "$HostAddress/$Uri"
                        $null = Add-PathToDictionary -Dictionary $clonePlan -Path "Host" -Value "$HostAddress"
                        $null = Add-PathToDictionary -Dictionary $clonePlan -Path "CacheAccessToken" -Value $true

                        $responseJacketSignal = [Signal]::Start("Queue_AzureStorageQueue.Invoke:$Slot.$Activity.Jacket", $ItemSignal) | Select-Object -Last 1

                        $responseSignal = Invoke-MappedAdapter -Adapter "Condenser.Rest" -Activity "Delete" -Signal $ConductionSignal -Plan $clonePlan -ItemSignal $ItemSignal
                        if ($opSignal.MergeSignalAndVerifyFailure($responseSignal)) { return $opSignal }
                    }
                    catch {
                        throw "Delete-StorageQueueApi: Failed to delete message id '$MessageId'. $($_.Exception.Message)"
                    }

                    $resultSignal = [Signal]::Start("StorageQueue.AckItem.Unresolved", $ItemSignal) | Select-Object -Last 1
                    break
                }

                "Delete" {
                    return $opSignal.LogCritical('Data AzureDataExplorer Delete is not implemented.')
                }

                default {
                    $opSignal.LogCritical("Unsupported Data AzureDataExplorer activity: $Activity")
                    return $opSignal
                }
            }

            if ($resultSignal) {
                $opSignal.MergeSignal($resultSignal)
                if ($resultSignal.Success()) {
                    $opSignal.SetResult($resultSignal.GetResult($true))
                    $opSignal.LogInformation("✅ $Slot.$Activity succeeded.")
                }
                else {
                    $opSignal.LogWarning("$Slot.$Activity did not succeed.")
                }
            }

        }
        catch {
            $opSignal.LogCritical("🔥 Exception in Data_AzureDataExplorer.Invoke: $($_.Exception.Message)", $null, $_)
        }

        return $opSignal
    }

}


function Resolve-Data_AzureDataExplorer() {
    $object = [Data_AzureDataExplorer]::new()
    return $object
}

# Export public utility functions
Export-ModuleMember -Function Resolve-Data_AzureDataExplorer

