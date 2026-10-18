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
$item.LogInformation('fixture entry') | Out-Null
$plan = [pscustomobject]@{ Config=[pscustomobject]@{}; Path='Fixture.Body' }

$global:SatelliteRestCall = $null
$global:SatelliteCondenserCalls = @()
& (Get-Module Satellite_AzureApplicationInsights) {
    Set-Item -Path Function:script:Invoke-MappedAdapter -Value {
        param($Adapter,$Activity,$Signal,$Plan,$ItemSignal)
        $result = [Signal]::Start('SatelliteChecks.FakeMapped') | Select-Object -Last 1
        if ($Adapter -eq 'Token.Memory') { $result.SetResult('offline body') | Out-Null }
        elseif ($Adapter -eq 'Condenser.Rest') {
            $global:SatelliteRestCall = [pscustomobject]@{ Activity=$Activity; Plan=$Plan }
            if ($global:SatelliteRestFail) { $result.LogCritical('Expected REST failure.') | Out-Null }
            else { $result.SetResult('offline response') | Out-Null }
        }
        else { $result.LogCritical('Unexpected mapped route.') | Out-Null }
        return $result
    }
    Set-Item -Path Function:script:Invoke-CondenserAdapter -Value {
        param($Slot,$Activity,$Signal,$Plan,$ItemSignal)
        $global:SatelliteCondenserCalls += "$Slot.$Activity"
        $result = [Signal]::Start('SatelliteChecks.FakeCondenser') | Select-Object -Last 1
        if ($global:SatelliteCondenserFail) { $result.LogCritical('Expected condenser failure.') | Out-Null }
        else { $result.SetResult([pscustomobject]@{ Steps=@() }) | Out-Null }
        return $result
    }
}

$full = $adapter.Invoke('Telemetry','EmitSignalFull',$run,$plan,$item)
Assert (-not $full.Failure() -and -not $full.HasResult()) 'EmitSignalFull changed its non-sending result.'
Assert (@($item.Entries).Count -gt 0 -and @($item.Entries[0].Tags) -contains 'Skip') 'EmitSignalFull did not tag entries.'
Assert ($null -eq $global:SatelliteRestCall) 'EmitSignalFull unexpectedly sent REST.'
foreach ($activity in @('EmitEntries','EmitSignal')) {
    $result = $adapter.Invoke('Telemetry',$activity,$run,$plan,$item)
    Assert (-not $result.Failure()) "$activity delegation failed."
}
Assert (@($global:SatelliteCondenserCalls | Where-Object { $_ -eq 'Token.Parse' }).Count -eq 2 -and @($global:SatelliteCondenserCalls | Where-Object { $_ -eq 'Conduction.ST' }).Count -eq 2) 'Telemetry condenser delegation changed.'
$global:SatelliteCondenserFail = $true
Assert ($adapter.Invoke('Telemetry','EmitSignal',$run,$plan,$item).Failure()) 'Condenser failure was lost.'
$global:SatelliteCondenserFail = $false
$sent = $adapter.Invoke('Telemetry','SendMessage',$run,$plan,$item)
Assert (-not $sent.Failure() -and $sent.GetResult() -ceq 'offline response') 'SendMessage REST result changed.'
Assert ($global:SatelliteRestCall.Activity -ceq 'Post' -and $global:SatelliteRestCall.Plan.Config.Body -ceq 'offline body' -and $global:SatelliteRestCall.Plan.Config.Uri -ceq $jacket.Addresses) 'SendMessage REST request changed.'
$global:SatelliteRestFail = $true
Assert ($adapter.Invoke('Telemetry','SendMessage',$run,$plan,$item).Failure()) 'SendMessage REST failure was lost.'
Write-Output 'PASS: Satellite construction, entry mutation, condenser delegation and fake REST success/failure.'
