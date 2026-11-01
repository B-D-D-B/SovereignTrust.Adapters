using module SignalGraph

$foundation = Join-Path $PSScriptRoot '../../../../../SovereignTrust.Foundation/Src/PowerShell/SovereignTrust.Foundation.psd1'
if (-not (Get-Module SovereignTrust.Foundation)) { Import-Module (Resolve-Path $foundation).ProviderPath -Force }
. "$PSScriptRoot/Invoke-OpenAIResponses.ps1"

class Intelligence_OpenAI {
    [object]$MappedAdapter
    [Signal]$Signal
    [object]$Settings

    Intelligence_OpenAI() { }
    Intelligence_OpenAI([object]$mappedAdapter) { $this.MappedAdapter = $mappedAdapter }

    [Signal] Construct([object]$dictionary) {
        $s = [Signal]::Start('Intelligence_OpenAI.Construct') | Select-Object -Last 1
        try {
            $resolved = Resolve-OpenAISettings $dictionary | Select-Object -Last 1
            if ($s.MergeSignalAndVerifyFailure($resolved) -or -not $resolved.HasResult()) { return $s }
            $this.Settings = $resolved.GetResult()
            $this.Signal = [Signal]::Start('Intelligence_OpenAI') | Select-Object -Last 1
            $jacket = [Signal]::Start('Intelligence_OpenAI.Jacket') | Select-Object -Last 1
            $jacket.SetResult($dictionary) | Out-Null
            $this.Signal.SetJacket($jacket) | Out-Null
        } catch { $null = $s.LogCritical('OpenAI construction failed.') }
        return $s
    }

    [Signal] Invoke([string]$Slot, [string]$Activity, [Signal]$ConductionSignal, [object]$Plan, [Signal]$ItemSignal) {
        $s = [Signal]::Start("Intelligence_OpenAI.Invoke:$Slot.$Activity", $ConductionSignal) | Select-Object -Last 1
        try {
            if ($null -eq $ConductionSignal) { throw 'context' }
            switch ($Activity) {
                { $_ -cin @('SendMessage','SendMessageOriginal') } {
                    $r = Invoke-OpenAIResponses -Settings $this.Settings -Plan $Plan -ConductionSignal $ConductionSignal | Select-Object -Last 1
                    if ($s.MergeSignalAndVerifyFailure($r)) { return $s }
                    if (-not $r.HasResult()) { throw 'response' }
                    $s.SetResult($r.GetResult()) | Out-Null
                    break
                }
                'HandleMessage' {
                    $message = Resolve-PathFromDictionary -Dictionary $ItemSignal -Path $Plan.Path -SignalLevel 'Critical' | Select-Object -Last 1
                    if ($s.MergeSignalAndVerifyFailure($message)) { return $s }
                    if (-not $message.HasResult() -and @($message.Entries).Count -gt 0) { throw 'lookup' }
                    $format = Resolve-PathFromDictionary -Dictionary $Plan -Path 'Format' -SignalLevel 'Information' | Select-Object -Last 1
                    if ($format.HasResult() -and $format.GetResult()) {
                        $fs = [Signal]::Start('Intelligence_OpenAI.Format', $ItemSignal) | Select-Object -Last 1
                        $fs.SetJacket($message) | Out-Null
                        $fs.SetPointer($ItemSignal.GetPointer()) | Out-Null
                        $converted = Invoke-CondenserAdapter -Slot 'Format' -Activity $format.GetResult() -Plan $Plan -Signal $ConductionSignal -ItemSignal $fs | Select-Object -Last 1
                        if ($s.MergeSignalAndVerifyFailure($converted) -or -not $converted.HasResult()) { return $s }
                        $message.SetResult($converted.GetResult()) | Out-Null
                    }
                    if ($message.HasResult()) { $s.SetResult($message.GetResult()) | Out-Null }
                    break
                }
                default { throw 'activity' }
            }
        } catch { $null = $s.LogCritical('OpenAI activity failed.') }
        return $s
    }
}

function Resolve-Intelligence_OpenAI { return [Intelligence_OpenAI]::new() }
Export-ModuleMember -Function Resolve-Intelligence_OpenAI
