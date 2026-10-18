function Invoke-Intelligence_AzureFoundry()
{

    param (
        [object]$Conductor,
        [object]$Conduit,
        [Signal]$ConductionSignal
    )

    $opSignal = [Signal]::Start("Invoke-Conduction_ST") | Select-Object -Last 1

    try { 
        if ($null -eq $Conductor) {
            return $opSignal.LogCritical("Cannot invoke Conduction_ST — provided Conductor is null.")
        } 

        if ($null -eq $ConductionSignal) {
            return $opSignal.LogCritical("Cannot invoke Conduction_ST — provided ConductionSignal is null.")
        }

        $environmentSignal = Resolve-PathFromDictionary -Dictionary $ConductionSignal -Path "%.@.Environment" | Select-Object -Last 1

        if ($opSignal.MergeSignalAndVerifyFailure($environmentSignal)) {
            $opSignal.LogCritical("Failed to resolve 'Environment' from ConductionSignal.")
            return $opSignal
        }

        $Environment = $environmentSignal.GetResult()
        $phasesSignal = Resolve-PathFromDictionary -Dictionary $ConductionSignal -Path "%.@.ConductionPlan" | Select-Object -Last 1

        if ($opSignal.MergeSignalAndVerifyFailure($phasesSignal)) {
            $opSignal.LogCritical("Failed to resolve 'Phases' from ConductionSignal.")
            return $opSignal
        }

        $phases = $phasesSignal.GetResult()
    
        foreach ($phase in $phases) {
            $phaseSignal = [Signal]::Start("Phase: $($phase.Name)", $opSignal) | Select-Object -Last 1 
            $phaseJacketSignal = [Signal]::Start("Phase: $($phase.Name)", $opSignal) | Select-Object -Last 1 
            $phaseJacketSignal.SetResult($phase) | Out-Null
            $phaseJacketSignal.SetJacket($Conductor) | Out-Null
            $phaseSignal.SetJacket($phaseJacketSignal) | Out-Null

            $opSignal.LogInformation("➡️ Processing phase: $($phase.Name)")

            $phaseOpSignal = Invoke-EnrollWires -Signal $phaseSignal -Environment $Environment
        }
    
        #$resultSignal = Invoke-AllCommandStepOutputs -Phases $phases
        
        if ($opSignal.MergeSignalAndVerifyFailure($resultSignal)) {
            $opSignal.LogCritical("Failed to process all command step outputs.")
            return $opSignal
        }

        $opSignal.SetResult($resultSignal.GetResult())
        $opSignal.LogInformation("✅ Invoked Conduction_ST successfully.")


    }
    catch {
            $opSignal.LogCritical("🔥 Exception during Invoke-Conduction_ST: $_", $null, $_)
    }

    return $opSignal
    }
