using module SignalGraph
$stModuleName = 'SovereignTrust.Foundation'
if (-not (Get-Module -Name $stModuleName)) {
    $stPath = Join-Path $PSScriptRoot "../../../../../SovereignTrust.Foundation/Src/PowerShell/SovereignTrust.Foundation.psd1"
    Import-Module (Resolve-Path $stPath).ProviderPath -Force
}

# ---- Load queue functions (your existing REST surface) ----
# Use your existing implementations here
# . "$PSScriptRoot/Read-StorageQueueApi.ps1"
# Optional if you have them:
# . "$PSScriptRoot/Delete-StorageQueueMessageApi.ps1"
# . "$PSScriptRoot/Update-StorageQueueVisibilityApi.ps1"
# . "$PSScriptRoot/Write-StorageQueueApi.ps1"

class Storage_AzureKeyVault {
    [object]$MappedAdapter
    [Signal]$Signal

    Storage_AzureKeyVault() { }

    Storage_AzureKeyVault([object]$mappedAdapter) {
        $this.MappedAdapter = $mappedAdapter
    }

    [Signal] Construct([object]$dictionary) {
        $opSignal = [Signal]::Start("Storage_AzureKeyVault.Construct") | Select-Object -Last 1

        try {
            if ($null -eq $dictionary) {
                $opSignal.LogCritical("Cannot construct Storage_AzureKeyVault — provided dictionary is null.")
                return $opSignal
            }

            $this.Signal = [Signal]::Start("Storage_AzureKeyVault") | Select-Object -Last 1

            $jacket = [Signal]::Start("Storage_AzureKeyVault.Jacket") | Select-Object -Last 1
            $jacket.SetResult($dictionary)

            $this.Signal.SetJacket($jacket)
            $opSignal.LogInformation("Storage_AzureKeyVault constructed successfully with provided jacket.")
        }
        catch {
            $opSignal.LogCritical("Error constructing Storage_AzureKeyVault: $_")
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
        $opSignal = [Signal]::Start("Storage_AzureKeyVault.Invoke:$Slot.$Activity", $ItemSignal) | Select-Object -Last 1

        try {
            if (-not $ConductionSignal) {
                $opSignal.LogCritical("❌ Null ConductionSignal passed to Storage_AzureKeyVault.Invoke()")
                return $opSignal
            }

            $opSignal.SetJacket($ConductionSignal)

            if (-not $Activity) {
                $opSignal.LogWarning("No Activity provided to Storage_AzureKeyVault.Invoke()")
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

            $virtualPathParts = $config.VirtualPath -Split '\.'

            $Activity = $virtualPathParts[2]
            $Secret = $virtualPathParts[3]

            $resultSignal = $null 

            switch ($Activity) {

                # ---------------------------------------------------------
                # Canonical verbs
                # ---------------------------------------------------------

                "Read" {
                    # Response Message to Discord
                    $hostUriSignal = Resolve-PathFromDictionary -Dictionary $this.Signal -Path "%.@.Addresses.0" | Select-Object -Last 1
                    $uri = "$($hostUriSignal.GetResult())secrets/$Secret"#/$applicationId/$interactionToken"

                    $clonePlan = (Resolve-ClonePlan -Plan $Plan | Select-Object -Last 1).GetResult()

                    $null = Add-PathToDictionary -Dictionary $clonePlan -Path "Config.Uri" -Value $uri
                    $null = Add-PathToDictionary -Dictionary $clonePlan -Path "Config.Method" -Value "Get"
                    $null = Add-PathToDictionary -Dictionary $clonePlan -Path "Config.Host" -Value $hostUriSignal.GetResult()
                    $null = Add-PathToDictionary -Dictionary $clonePlan -Path "Config.CacheAccessToken" -Value $true
                    $null = Add-PathToDictionary -Dictionary $clonePlan -Path "Config.Querystring" -Value "?api-version=7.4"

                    # Call Rest Endpoint
                    $responseSignal = Invoke-MappedAdapter -Adapter "Condenser.Rest" -Activity "Get" -Signal $ConductionSignal -Plan $clonePlan -ItemSignal $ItemSignal
                    if ($opSignal.MergeSignalAndVerifyFailure($responseSignal)) { return $opSignal }

                    $opSignal.SetResult(($responseSignal.GetResult()).value)

                    break
                }

                default {
                    $opSignal.LogWarning("Unsupported Activity: $Activity")
                    $resultSignal = [Signal]::Start("StorageQueue.UnsupportedActivity", $ItemSignal) | Select-Object -Last 1
                    break
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
            $opSignal.LogCritical("🔥 Exception in Storage_AzureKeyVault.Invoke: $($_.Exception.Message)", $null, $_)
        }

        return $opSignal
    }
}

function Resolve-Storage_AzureKeyVault {
    $object = [Storage_AzureKeyVault]::new()
    return $object
}

Export-ModuleMember -Function Resolve-Storage_AzureKeyVault
