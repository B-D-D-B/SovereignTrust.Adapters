using module SignalGraph

$ErrorActionPreference = 'Stop'
$foundationManifest = Join-Path $PSScriptRoot '../../../../../SovereignTrust.Foundation/Src/PowerShell/SovereignTrust.Foundation.psd1'
Import-Module $foundationManifest -Force
$manifest = Join-Path $PSScriptRoot '../PowerShell/Satellite_AzureApplicationInsights.psd1'
Import-Module $manifest -Force
function Assert([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }

$adapter = Resolve-Satellite_AzureApplicationInsights
$foundation = Get-Module SovereignTrust.Foundation
Assert ($null -ne $foundation) 'Foundation dependency did not load.'
$mapped = & $foundation { [MappedSatelliteAdapter]::new() }
$typed = & (Get-Module Satellite_AzureApplicationInsights) { param($value) [Satellite_AzureApplicationInsights]::new($value) } $mapped
Assert ([object]::ReferenceEquals($typed.MappedAdapter,$mapped)) 'Satellite constructor lost mapped instance.'
$opaqueValues = @(
    (& $foundation { [MappedNetworkAdapter]::new() }),
    [pscustomobject]@{ Family='Satellite' }
)
foreach ($opaque in $opaqueValues) {
    $carried = & (Get-Module Satellite_AzureApplicationInsights) { param($value) [Satellite_AzureApplicationInsights]::new($value) } $opaque
    Assert ([object]::ReferenceEquals($carried.MappedAdapter,$opaque)) 'Satellite constructor lost opaque mapped object.'
}
$jacket = [pscustomobject]@{ Addresses='https://offline.invalid/telemetry'; PlanTokens=[pscustomobject]@{ EmitEntries='EntriesPlan'; EmitSignal='SignalPlan' } }
$constructed = $adapter.Construct($jacket)
Assert (-not $constructed.Failure()) 'Satellite Construct failed.'
$run = [Signal]::Start('SatelliteChecks.Run') | Select-Object -Last 1
$item = [Signal]::Start('SatelliteChecks.Item') | Select-Object -Last 1
$null = $item.CreateGraph()
$item.LogInformation('fixture entry') | Out-Null
$plan = [pscustomobject]@{ Config=[pscustomobject]@{ CountKey='TelemetrySendCount_Fixture' }; Path='Fixture.Body' }
$global:SatelliteBody = '{"name":"fixture"}'
$global:SatelliteResponse = [pscustomobject]@{ itemsReceived=1; itemsAccepted=1; appId=$null; errors=@() }

$global:SatelliteRestCall = $null
$global:SatelliteCondenserCalls = @()
& (Get-Module Satellite_AzureApplicationInsights) {
    Set-Item -Path Function:script:Invoke-MappedAdapter -Value {
        param($Adapter,$Activity,$Signal,$Plan,$ItemSignal)
        $result = [Signal]::Start('SatelliteChecks.FakeMapped') | Select-Object -Last 1
        if ($Adapter -eq 'Token.Memory') { $result.SetResult($global:SatelliteBody) | Out-Null }
        elseif ($Adapter -eq 'Condenser.Rest') {
            $global:SatelliteRestCall = [pscustomobject]@{ Activity=$Activity; Plan=$Plan }
            if ($global:SatelliteRestFail) { $result.LogCritical('Expected REST failure.') | Out-Null }
            else { $result.SetResult($global:SatelliteResponse) | Out-Null }
        }
        else { $result.LogCritical('Unexpected mapped route.') | Out-Null }
        return $result
    }
    Set-Item -Path Function:script:Invoke-CondenserAdapter -Value {
        param($Slot,$Activity,$Signal,$Plan,$ItemSignal)
        $global:SatelliteCondenserCalls += "$Slot.$Activity"
        $result = [Signal]::Start('SatelliteChecks.FakeCondenser') | Select-Object -Last 1
        if ($global:SatelliteCondenserFail -and (-not $global:SatelliteStoreOnFailure -or $Slot -eq 'Conduction')) {
            if ($Slot -eq 'Conduction' -and $Activity -eq 'ST' -and $global:SatelliteStoreOnFailure) {
                $null = $ItemSignal.GetPointer().RegisterResultAsSignal("TelemetryHandled_$global:SatelliteCurrentActivity", $global:SatelliteHandled)
            }
            $result.LogCritical('Expected condenser failure.') | Out-Null
        }
        else {
            if ($Slot -eq 'Conduction' -and $Activity -eq 'ST' -and -not $global:SatelliteOmitHandled) {
                $null = $ItemSignal.GetPointer().RegisterResultAsSignal("TelemetryHandled_$global:SatelliteCurrentActivity", $global:SatelliteHandled)
            }
            $result.SetResult([pscustomobject]@{ Steps=@() }) | Out-Null
        }
        return $result
    }
}

$full = $adapter.Invoke('Telemetry','EmitSignalFull',$run,$plan,$item)
Assert (-not $full.Failure() -and -not $full.HasResult()) 'EmitSignalFull changed its non-sending result.'
Assert (@($item.Entries).Count -gt 0 -and @($item.Entries[0].Tags) -contains 'Skip') 'EmitSignalFull did not tag entries.'
Assert ($null -eq $global:SatelliteRestCall) 'EmitSignalFull unexpectedly sent REST.'
foreach ($activity in @('EmitEntries','EmitSignal')) {
    $global:SatelliteCurrentActivity = $activity
    $global:SatelliteHandled = [pscustomobject]@{ ItemsReceived=1L; ItemsAccepted=1L; Result=$true }
    $result = $adapter.Invoke('Telemetry',$activity,$run,$plan,$item)
    Assert (-not $result.Failure()) "$activity delegation failed."
    Assert ($result.HasResult() -and [object]::ReferenceEquals($result.GetResult(),$global:SatelliteHandled)) "$activity did not forward handled result."
}
Assert (@($global:SatelliteCondenserCalls | Where-Object { $_ -eq 'Token.Parse' }).Count -eq 2 -and @($global:SatelliteCondenserCalls | Where-Object { $_ -eq 'Conduction.ST' }).Count -eq 2) 'Telemetry condenser delegation changed.'
$global:SatelliteCondenserFail = $true
$failedEmit = $adapter.Invoke('Telemetry','EmitSignal',$run,$plan,$item)
Assert ($failedEmit.Failure()) 'EmitSignal condenser failure was lost.'
$global:SatelliteCondenserFail = $false
$global:SatelliteOmitHandled = $true
$missingHandled = $adapter.Invoke('Telemetry','EmitSignal',$run,$plan,$item)
Assert ($missingHandled.Failure() -and -not $missingHandled.HasResult()) 'Missing handled result passed emission.'
$global:SatelliteOmitHandled = $false
$global:SatelliteStoreOnFailure = $true
$global:SatelliteCondenserFail = $true
$global:SatelliteHandled = [pscustomobject]@{ ItemsReceived=1L; ItemsAccepted=1L; Result=$true }
$failedWithHandled = $adapter.Invoke('Telemetry','EmitSignal',$run,$plan,$item)
Assert ($failedWithHandled.Failure() -and $failedWithHandled.HasResult() -and [object]::ReferenceEquals($failedWithHandled.GetResult(),$global:SatelliteHandled)) 'Failed emission lost persisted handled result.'
$global:SatelliteCondenserFail = $false
$global:SatelliteStoreOnFailure = $false
$sent = $adapter.Invoke('Telemetry','SendMessage',$run,$plan,$item)
Assert (-not $sent.Failure() -and [object]::ReferenceEquals($sent.GetResult(),$global:SatelliteResponse)) 'SendMessage REST result changed.'
Assert ($global:SatelliteRestCall.Activity -ceq 'Post' -and $global:SatelliteRestCall.Plan.Config.Body -ceq $global:SatelliteBody -and $global:SatelliteRestCall.Plan.Config.Uri -ceq $jacket.Addresses) 'SendMessage REST request changed.'
$global:SatelliteRestFail = $true
Assert ($adapter.Invoke('Telemetry','SendMessage',$run,$plan,$item).Failure()) 'SendMessage REST failure was lost.'
$global:SatelliteRestFail = $false
Assert ($item.GetPointer().Grid['TelemetrySendCount_Fixture'].GetResult() -eq 1) 'Single outbound envelope count was not stored.'
$global:SatelliteBody = '[{"name":"one"},{"name":"two"}]'
$null = $adapter.Invoke('Telemetry','SendMessage',$run,$plan,$item)
Assert ($item.GetPointer().Grid['TelemetrySendCount_Fixture'].GetResult() -eq 2 -and $global:SatelliteRestCall.Plan.Config.Body -ceq $global:SatelliteBody) 'Array count or exact outbound body changed.'
foreach ($badBody in @('', 'not-json', '[]', '[{} , 1]', '"string"')) {
    $global:SatelliteBody = $badBody
    $global:SatelliteRestCall = $null
    Assert ($adapter.Invoke('Telemetry','SendMessage',$run,$plan,$item).Failure() -and $null -eq $global:SatelliteRestCall) "Invalid outbound body reached REST: $badBody"
}
$handledPlan = [pscustomobject]@{ Config=[pscustomobject]@{ RawResponse=[pscustomobject]@{ itemsReceived=2; itemsAccepted=2; appId=$null; errors=@() }; ItemsSent=2; HandledResultKey='FixtureHandled' } }
$handled = $adapter.Invoke('Telemetry','HandleResponse',$run,$handledPlan,$item)
Assert (-not $handled.Failure() -and $handled.GetResult().Result -eq $true -and $handled.GetResult().ItemsReceived -eq 2) 'Positive response normalization failed.'
Assert ([object]::ReferenceEquals($handled.GetResult(),$item.GetPointer().Grid['FixtureHandled'].GetResult())) 'Handled result was not persisted.'
$handledPlan.Config.RawResponse = @{ ItemsReceived=2; ItemsAccepted=2; AppId=$null; Errors=@() }
Assert (-not $adapter.Invoke('Telemetry','HandleResponse',$run,$handledPlan,$item).Failure()) 'Case-insensitive property bag was rejected.'
$handledPlan.Config.RawResponse = [pscustomobject]@{ itemsReceived=2; itemsAccepted=2; appId=$null; errors=@() }
$handledPlan.Config.RawResponse.itemsAccepted = 1
$partial = $adapter.Invoke('Telemetry','HandleResponse',$run,$handledPlan,$item)
Assert (-not $partial.Failure() -and $partial.GetResult().Result -eq $false) 'Partial acceptance did not return nonfailed false.'
$handledPlan.Config.RawResponse.itemsAccepted = 2
$handledPlan.Config.RawResponse.errors = @([pscustomobject]@{code=42;message='bad one'},[pscustomobject]@{code=43;message='bad two'})
$errorResult = $adapter.Invoke('Telemetry','HandleResponse',$run,$handledPlan,$item)
Assert ($errorResult.Failure() -and $errorResult.HasResult() -and $errorResult.GetResult().Result -eq $true) 'Service errors did not retain count-only true on failed Signal.'
Assert ([object]::ReferenceEquals($errorResult.GetResult(),$item.GetPointer().Grid['FixtureHandled'].GetResult())) 'Failed handler lost persisted result.'
Assert (@($errorResult.Entries | Where-Object Level -eq 'Critical').Count -eq 2) 'Service errors did not log one critical entry each.'
foreach ($invalid in @(
    [pscustomobject]@{ itemsAccepted=1; errors=@() },
    [pscustomobject]@{ itemsReceived=2; itemsAccepted=3; errors=@() },
    [pscustomobject]@{ itemsReceived=2.0; itemsAccepted=2; errors=@() },
    [pscustomobject]@{ itemsReceived='2'; itemsAccepted=2; errors=@() },
    [pscustomobject]@{ itemsReceived=2; itemsAccepted=2; errors='bad' }
)) {
    $handledPlan.Config.RawResponse = $invalid
    Assert ($adapter.Invoke('Telemetry','HandleResponse',$run,$handledPlan,$item).Failure()) 'Malformed response was accepted.'
}
$handledPlan.Config.RawResponse = [pscustomobject]@{ itemsReceived=2; itemsAccepted=2; errors=@() }
$handledPlan.Config.ItemsSent = $null
Assert ($adapter.Invoke('Telemetry','HandleResponse',$run,$handledPlan,$item).Failure()) 'Missing sent count was accepted.'
$handledPlan.Config.ItemsSent = 2
$index = 0
foreach ($counts in @(@(-1,-1),@(-1,0),@(0,-1))) {
    $index++
    $handledPlan.Config.HandledResultKey = "RejectedNegative_$index"
    $handledPlan.Config.RawResponse = [pscustomobject]@{ itemsReceived=$counts[0]; itemsAccepted=$counts[1]; errors=@() }
    $negative = $adapter.Invoke('Telemetry','HandleResponse',$run,$handledPlan,$item)
    Assert ($negative.Failure() -and -not $negative.HasResult() -and -not $item.GetPointer().Grid.Contains($handledPlan.Config.HandledResultKey)) 'Negative service count was accepted or persisted.'
}
$handledPlan.Config.HandledResultKey = 'ZeroCounts'
$handledPlan.Config.RawResponse = [pscustomobject]@{ itemsReceived=0; itemsAccepted=0; errors=@() }
$zero = $adapter.Invoke('Telemetry','HandleResponse',$run,$handledPlan,$item)
Assert (-not $zero.Failure() -and $zero.HasResult() -and $zero.GetResult().Result -eq $false) 'Zero service counts with positive sent count were rejected.'
Write-Output 'PASS: satellite provider-free send, count, response normalization, and error cases.'
