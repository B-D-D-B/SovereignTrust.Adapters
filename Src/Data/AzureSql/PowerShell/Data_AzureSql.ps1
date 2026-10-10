class Data_AzureSql {
    [object]$MappedAdapter
    [Signal]$Signal
    [object]$Configuration

    Data_AzureSql() {}
    Data_AzureSql([object]$mappedAdapter) { $this.MappedAdapter = $mappedAdapter }

    [Signal] Construct([object]$dictionary) {
        $opSignal = [Signal]::Start('Data_AzureSql.Construct') | Select-Object -Last 1
        try {
            if ($null -eq $dictionary) { throw 'AzureSql configuration is required.' }
            $this.Configuration = $dictionary
            $this.Signal = [Signal]::Start('Data_AzureSql') | Select-Object -Last 1
            $jacket = [Signal]::Start('Data_AzureSql.Configuration') | Select-Object -Last 1
            $jacket.SetResult($dictionary) | Out-Null
            $this.Signal.SetJacket($jacket) | Out-Null
            $opSignal.SetResult($this)
        }
        catch {
            $null = $opSignal.LogCritical('Could not construct AzureSql adapter.')
        }
        return $opSignal
    }

    [Signal] Invoke([string]$Slot, [string]$Activity, [Signal]$ConductionSignal, [object]$Plan, [Signal]$ItemSignal) {
        return Invoke-Data_AzureSql -Adapter $this -Slot $Slot -Activity $Activity -ConductionSignal $ConductionSignal -Plan $Plan -ItemSignal $ItemSignal | Select-Object -Last 1
    }
}

function Resolve-Data_AzureSql { return [Data_AzureSql]::new() }
