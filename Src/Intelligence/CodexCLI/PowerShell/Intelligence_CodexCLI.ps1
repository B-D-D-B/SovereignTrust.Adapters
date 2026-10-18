class Intelligence_CodexCLI {
    [object]$MappedAdapter
    [Signal]$Signal
    [object]$Configuration

    Intelligence_CodexCLI() {}
    Intelligence_CodexCLI([object]$mappedAdapter) { $this.MappedAdapter = $mappedAdapter }

    [Signal] Construct([object]$dictionary) {
        $opSignal = [Signal]::Start('Intelligence_CodexCLI.Construct') | Select-Object -Last 1
        try {
            if ($null -eq $dictionary) { throw 'CodexCLI configuration is required.' }
            $this.Configuration = $dictionary
            $this.Signal = [Signal]::Start('Intelligence_CodexCLI') | Select-Object -Last 1
            $jacket = [Signal]::Start('Intelligence_CodexCLI.Jacket') | Select-Object -Last 1
            $jacket.SetResult($dictionary) | Out-Null
            $this.Signal.SetJacket($jacket) | Out-Null
            $opSignal.SetResult($this) | Out-Null
        }
        catch { $null = $opSignal.LogCritical('Could not construct CodexCLI adapter.') }
        return $opSignal
    }

    [Signal] Invoke([string]$Slot, [string]$Activity, [Signal]$ConductionSignal, [object]$Plan, [Signal]$ItemSignal) {
        $opSignal = [Signal]::Start("Intelligence_CodexCLI.Invoke:$Slot.$Activity", $ItemSignal) | Select-Object -Last 1
        try {
            $activitySignal = Invoke-Intelligence_CodexCLI -Adapter $this -Slot $Slot -Activity $Activity -ConductionSignal $ConductionSignal -Plan $Plan -ItemSignal $ItemSignal | Select-Object -Last 1
            if ($opSignal.MergeSignalAndVerifyFailure($activitySignal)) { return $opSignal }
            if (-not $activitySignal.HasResult()) { throw 'CodexCLI activity produced no result.' }
            $opSignal.SetResult($activitySignal.GetResult()) | Out-Null
        }
        catch { $null = $opSignal.LogCritical('CodexCLI activity failed.') }
        return $opSignal
    }
}

function Resolve-Intelligence_CodexCLI { return [Intelligence_CodexCLI]::new() }
