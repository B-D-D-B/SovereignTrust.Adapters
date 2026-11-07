using module SignalGraph
$sgModuleName = 'SovereignTrust.Foundation'
if (-not (Get-Module -Name $sgModuleName)) {
    $sgPath = Join-Path $PSScriptRoot "../../../../../SovereignTrust.Foundation/Src/PowerShell/SovereignTrust.Foundation.psd1"
    Import-Module (Resolve-Path $sgPath).ProviderPath -Force
}

# Load all files (functions + classes)
. "$PSScriptRoot/Invoke-Conduction_ST.ps1"
. "$PSScriptRoot/Invoke-Conduction_ST_GetNextPhaseSet.ps1"
. "$PSScriptRoot/Invoke-ConductionPhase.ps1"
. "$PSScriptRoot/Resolve-Function.ps1"

class Conduction_ST {
    [object]$MappedAdapter
    [Signal]$Signal

    Conduction_ST() {
    }

    Conduction_ST([object]$mappedAdapter) {
        $this.MappedAdapter = $mappedAdapter
    }

    [Signal] Construct([object]$dictionary) {
        $opSignal = [Signal]::Start("Conduction_ST") | Select-Object -Last 1

        try {
            if ($null -eq $dictionary) {
                return $opSignal.LogCritical("Cannot construct Conduction_ST — provided dictionary is null.")
            }

            $resolved = Resolve-RemainingResourceRoutesJacket -Jacket $dictionary -Family Conduction_ST | Select-Object -Last 1
            if ($resolved.Failure() -or -not $resolved.HasResult()) {
                return $opSignal.MergeSignal($resolved).LogCritical('Conduction jacket is invalid.')
            }
            $dictionary = $resolved.GetResult()

            $this.Signal = [Signal]::Start("Conduction_ST") | Select-Object -Last 1

            $jacket = [Signal]::Start("Conduction_ST") | Select-Object -Last 1 
            
            $this.Signal.SetJacket($jacket)
            $jacket.SetResult($dictionary)
            $opSignal.LogInformation("Conduction_ST constructed successfully with provided jacket.")
        }
        catch {
            $opSignal.LogCritical("Error constructing Conduction_ST: $_")
        }

        return $opSignal
    }

#    [Signal] Invoke([string]$Slot, [Signal]$Context, [object]$Plan) {
    [Signal]Invoke([string]$Slot, [string]$Activity, [Signal]$ConductionSignal, [object]$Plan, [Signal]$ItemSignal) {
#    [Signal] Invoke([string]$Slot, [Signal]$ConductionSignal) {
        $opSignal = [Signal]::Start("Token_Environment.Invoke") | Select-Object -Last 1
#        $conductor = $this.MappedAdapter.Signal.GetJacket()
        
        try {
            $resultSignal = Invoke-Conduction_ST -Signal $ConductionSignal -Slot $Slot -Activity $Activity -ItemSignal $ItemSignal -Plan $Plan | Select-Object -Last 1
            $opSignal.MergeSignal($resultSignal)

            if ($resultSignal.Success()) {
                $opSignal.SetResult($resultSignal.GetResult())
                $opSignal.LogInformation("✅ Ran successfully.")
            } else {
                $opSignal.LogWarning("Failed to Run.")
            }
        }
        catch {
            $opSignal.LogCritical("🔥 Exception in Token_Environment.Invoke: $($_.Exception.Message)", $null, $_)
        }

        return $opSignal
    }

}


function Resolve-Conduction_ST()
{
    $object = [Conduction_ST]::new()
    return $object
}

# Export public utility functions
Export-ModuleMember -Function Resolve-Conduction_ST

