function Invoke-Network_CodexCLI {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Adapter, [Parameter(Mandatory)][string]$Slot,
        [Parameter(Mandatory)][string]$Activity, [Signal]$ConductionSignal,
        [Parameter(Mandatory)][object]$Plan, [Signal]$ItemSignal)
    $opSignal = [Signal]::Start("Network_CodexCLI.Invoke:$Slot.$Activity", $ItemSignal) | Select-Object -Last 1
    try {
        switch -CaseSensitive ($Activity) {
            'SendMessage' {
                foreach ($name in @('ExecutablePath','Workspace','Flags','AuthenticationMode','ApiKey','CodexHome','AllowSavedHomeExtensions','TimeoutSeconds','MaxPromptBytes','MaxEventBytes','MaxStderrBytes','MaxFinalBytes','MaxImages','MaxImageBytes','MaxDownloadSeconds','AllowedImageHosts','AllowedLocalImageRoots','Sandbox','ApprovalPolicy','Environment')) {
                    $policyPresence = Test-CodexCLIMember $Plan $name | Select-Object -Last 1
                    if ($opSignal.MergeSignalAndVerifyFailure($policyPresence)) { return $opSignal }
                    if ($policyPresence.GetResult()) { throw 'Plan attempts to override CodexCLI jacket policy.' }
                }
                $configSignal = Resolve-PathFromDictionary -Dictionary $Plan -Path 'Config' -SignalLevel 'Warning' | Select-Object -Last 1
                if ($configSignal.Failure() -or -not $configSignal.HasResult()) { throw 'SendMessage requires Config.' }
                $config = $configSignal.GetResult()
                $executionSignal = Invoke-CodexCLIExecution -Adapter $Adapter -Config $config | Select-Object -Last 1
                if ($opSignal.MergeSignalAndVerifyFailure($executionSignal)) { return $opSignal }
                if (-not $executionSignal.HasResult()) { throw 'CodexCLI execution returned no result.' }
                $result = $executionSignal.GetResult()
                if ($result -isnot [string]) { throw 'CodexCLI execution returned no JSON text.' }
                $null = ConvertFrom-Json -InputObject $result -Depth 20 -ErrorAction Stop
                $opSignal.SetResult($result) | Out-Null
                break
            }
            'HandleMessage' {
                $pathSignal = Resolve-PathFromDictionary -Dictionary $Plan -Path 'Path' -SignalLevel 'Warning' | Select-Object -Last 1
                $path = if ($pathSignal.HasResult()) { $pathSignal.GetResult() } else { $null }
                if ($path -isnot [string] -or [string]::IsNullOrWhiteSpace($path)) { throw 'HandleMessage requires Plan.Path.' }
                $messageSignal = Resolve-PathFromDictionary -Dictionary $ItemSignal -Path $path | Select-Object -Last 1
                if ($messageSignal.Failure() -or -not $messageSignal.HasResult()) { throw 'HandleMessage path is unavailable.' }
                $formatSignal = Resolve-PathFromDictionary -Dictionary $Plan -Path 'Format' -SignalLevel 'Warning' | Select-Object -Last 1
                $format = if ($formatSignal.HasResult()) { $formatSignal.GetResult() } else { $null }
                if ($null -ne $format -and -not [string]::IsNullOrWhiteSpace([string]$format)) {
                    $formatSignal = [Signal]::Start('Network_CodexCLI.Format', $ItemSignal) | Select-Object -Last 1
                    $formatSignal.SetJacket($messageSignal) | Out-Null
                    $formatSignal.SetPointer($ItemSignal.GetPointer()) | Out-Null
                    $formatted = Invoke-CondenserAdapter -Slot 'Format' -Activity $format -Plan $Plan -Signal $ConductionSignal -ItemSignal $formatSignal | Select-Object -Last 1
                    if ($formatted.Failure() -or -not $formatted.HasResult()) { throw 'HandleMessage formatting failed.' }
                    $opSignal.SetResult($formatted.GetResult()) | Out-Null
                }
                else { $opSignal.SetResult($messageSignal.GetResult()) | Out-Null }
                break
            }
            default { throw 'Unsupported CodexCLI activity.' }
        }
    }
    catch {
        # Provider exceptions may contain prompt, response, URL, or credentials.
        $null = $opSignal.LogCritical("CodexCLI $Activity failed. Check adapter configuration, input and local execution prerequisites.")
    }
    return $opSignal
}
