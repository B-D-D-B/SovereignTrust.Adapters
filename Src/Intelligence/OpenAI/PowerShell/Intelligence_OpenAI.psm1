using module SignalGraph

$foundation = Join-Path $PSScriptRoot '../../../../../SovereignTrust.Foundation/Src/PowerShell/SovereignTrust.Foundation.psd1'
if (-not (Get-Module SovereignTrust.Foundation)) { Import-Module (Resolve-Path $foundation).ProviderPath -Force }

. "$PSScriptRoot/Invoke-OpenAIResponses.ps1"
. "$PSScriptRoot/Resolve-OpenAIV2Settings.ps1"

function Assert-OpenAIImageFields($Value,[string[]]$Allowed,[string[]]$Required) {
    if ($null -eq $Value -or ($Value -isnot [Collections.IDictionary] -and $Value -isnot [pscustomobject])) { throw 'object' }
    $names=@(if ($Value -is [Collections.IDictionary]) { $Value.Keys } else { $Value.PSObject.Properties.Name })
    foreach ($name in $names) { if ($name -isnot [string] -or $name -cnotin $Allowed) { throw 'field' } }
    foreach ($name in $Required) { if ($name -cnotin $names) { throw 'required' } }
}

function Resolve-OpenAIImageIndex($Items,[string]$Key) {
    $found=-1
    for ($i=0; $i -lt @($Items).Count; $i++) {
        if ((Get-OpenAIValue $Items[$i] 'Key') -ceq $Key) {
            if ($found -ge 0) { throw 'duplicate-key' }
            $found=$i
        }

    }

    if ($found -lt 0) { throw 'missing-key' }
    return $found
}

class Intelligence_OpenAI {
    [object]$MappedAdapter
    [Signal]$Signal
    [object]$Settings

    Intelligence_OpenAI() { }
    Intelligence_OpenAI([object]$mappedAdapter) { $this.MappedAdapter = $mappedAdapter }

    [Signal] Construct([object]$dictionary) {
        $s = [Signal]::Start('Intelligence_OpenAI.Construct') | Select-Object -Last 1

        try {
            $version=Get-OpenAIValue $dictionary 'SchemaVersion'
            if ($null -ne $version -and (($version -isnot [int] -and $version -isnot [long]) -or $version -ne 2)) { throw 'schema' }

            $resolved = if ($version -eq 2) { Resolve-OpenAIV2Settings $dictionary | Select-Object -Last 1 } else {
                Resolve-OpenAISettings $dictionary | Select-Object -Last 1
            }

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
        $opSignal = [Signal]::Start("Intelligence_OpenAI.Invoke:$Slot.$Activity", $ConductionSignal) | Select-Object -Last 1

        try {
            if ($null -eq $ConductionSignal) { throw 'context' }

            switch ($Activity) {
                { $_ -ceq 'SendMessage' } {
                    $selected=$this.Settings

                    if ($this.Settings.SchemaVersion -eq 2) {
                        $configSignal=Resolve-PathFromDictionary -Dictionary $Plan -Path 'Config' -SignalLevel 'Information' | Select-Object -Last 1
                        $config=$null
                        if ($configSignal.HasResult()) { $config=$configSignal.GetResult() }
                        if ($null -ne $config -and $config -isnot [Collections.IDictionary] -and $config -isnot [pscustomobject]) { throw 'config' }

                        $selector=$null
                        if ($null -ne $config) {
                            $selectorSignal=Resolve-PathFromDictionary -Dictionary $config -Path 'Profile' -SignalLevel 'Information' | Select-Object -Last 1
                            if ($selectorSignal.HasResult()) { $selector=$selectorSignal.GetResult() }
                        }

                        if ($null -ne $selector) {

                            Assert-OpenAIImageFields $config @('Profile','Prompt') @('Profile','Prompt')
                            Assert-OpenAIImageFields $selector @('Key') @('Key')

                            $keySignal=Resolve-PathFromDictionary -Dictionary $selector -Path 'Key' -SignalLevel 'Information' | Select-Object -Last 1
                            if (-not $keySignal.HasResult()) { throw 'profile-key' }

                            $key=$keySignal.GetResult()
                            if ($key -isnot [string] -or -not $this.Settings.Profiles.ContainsKey($key)) { throw 'profile-key' }
                            if ($this.Settings.Profiles[$key].Route.ApiKind -cnotin @('OpenAIImageGeneration','OpenAIImageEdit')) { throw 'activity-profile' }

                            $profilesSignal=Resolve-PathFromDictionary -Dictionary $this.Signal -Path '%.@.Profiles' -SignalLevel 'Information' | Select-Object -Last 1
                            $routesSignal=Resolve-PathFromDictionary -Dictionary $this.Signal -Path '%.@.Routes' -SignalLevel 'Information' | Select-Object -Last 1
                            $resourcesSignal=Resolve-PathFromDictionary -Dictionary $this.Signal -Path '%.@.Resource' -SignalLevel 'Information' | Select-Object -Last 1
                            if (-not $profilesSignal.HasResult() -or -not $routesSignal.HasResult() -or -not $resourcesSignal.HasResult()) { throw 'jacket' }

                            $profiles=@($profilesSignal.GetResult());$routes=@($routesSignal.GetResult());$resources=@($resourcesSignal.GetResult())
                            $profile=$profiles[(Resolve-OpenAIImageIndex $profiles $key)]
                            $routeKey=Get-OpenAIValue $profile 'RouteKey';$model=Get-OpenAIValue $profile 'Model'
                            $routeIndex=Resolve-OpenAIImageIndex $routes $routeKey
                            $route=$routes[$routeIndex]
                            $resourceIndex=Resolve-OpenAIImageIndex $resources (Get-OpenAIValue $route 'ResourceKey')

                            $addressSignal=Resolve-PathFromDictionary -Dictionary $this.Signal -Path "%.@.Routes.$routeIndex.Address" -SignalLevel 'Information' | Select-Object -Last 1
                            $credentialSignal=Resolve-PathFromDictionary -Dictionary $this.Signal -Path "%.@.Resource.$resourceIndex.Credentials" -SignalLevel 'Information' | Select-Object -Last 1
                            if (-not $addressSignal.HasResult() -or -not $credentialSignal.HasResult()) { throw 'route-resource' }

                            $kind=Get-OpenAIValue $route 'ApiKind'
                            $path=switch -CaseSensitive ($kind) {
                                'OpenAIImageGeneration' { '/v1/images/generations' }
                                'OpenAIImageEdit' { '/v1/images/edits' }
                                default { throw 'route-kind' }
                            }
                            if ((Get-OpenAIValue $route 'AuthMode') -cne 'ApiKey' -or
                                $this.Settings.Profiles[$key].Model -cne $model -or $this.Settings.Profiles[$key].Route.Key -cne $routeKey) { throw 'binding' }

                            $address=Assert-OpenAIImageEndpoint $addressSignal.GetResult() $path
                            $credential=$credentialSignal.GetResult()
                            if ($credential -isnot [string] -or -not $credential.Trim()) { throw 'credential' }

                            $promptSignal=Resolve-PathFromDictionary -Dictionary $config -Path 'Prompt' -SignalLevel 'Information' | Select-Object -Last 1
                            if (-not $promptSignal.HasResult()) { throw 'prompt' }

                            $prompt=$promptSignal.GetResult()
                            if ($prompt -isnot [Collections.IDictionary] -and $prompt -isnot [pscustomobject]) { throw 'prompt' }
                            $promptNames=@(if ($prompt -is [Collections.IDictionary]) {$prompt.Keys} else {$prompt.PSObject.Properties.Name})
                            $modelSignal=Resolve-PathFromDictionary -Dictionary $prompt -Path 'model' -SignalLevel 'Information' | Select-Object -Last 1
                            if (-not $modelSignal.HasResult()) { throw 'prompt-model' }
                            $nativeModel=$modelSignal.GetResult()
                            if ($nativeModel -isnot [string] -or $nativeModel -cne $model) { throw 'prompt-model' }

                            $streamSignal=Resolve-PathFromDictionary -Dictionary $prompt -Path 'stream' -SignalLevel 'Information' | Select-Object -Last 1
                            if ('stream' -in $promptNames) {
                                if (-not $streamSignal.HasResult()) { throw 'stream' }
                                $stream=$streamSignal.GetResult()
                                if ($stream -isnot [bool] -or $stream) { throw 'stream' }
                            }

                            $json=ConvertTo-Json -InputObject $prompt -Depth 100 -WarningAction Stop -ErrorAction Stop
                            if ([Text.Encoding]::UTF8.GetByteCount($json) -gt 1MB) { throw 'request-size' }

                            $cloneSignal=Resolve-ClonePlan -Plan $Plan | Select-Object -Last 1
                            if ($opSignal.MergeSignalAndVerifyFailure($cloneSignal) -or -not $cloneSignal.HasResult()) { return $opSignal }

                            $clone=$cloneSignal.GetResult()
                            foreach ($field in @(
                                @('Config.Method','Post'),@('Config.Host',$address),@('Config.Uri',$address),
                                @('Config.SkipBearerToken',$true),@('Config.Body',$prompt),
                                @('Config.Headers',@{Authorization="Bearer $credential";'Content-Type'='application/json'})
                            )) {
                                $write=Add-PathToDictionary -Dictionary $clone -Path $field[0] -Value $field[1] | Select-Object -Last 1
                                if ($opSignal.MergeSignalAndVerifyFailure($write)) { return $opSignal }
                            }

                            $rest=Invoke-MappedAdapter -Adapter 'Condenser.Rest' -Activity 'POST' -Signal $ConductionSignal -Plan $clone -ItemSignal $ItemSignal | Select-Object -Last 1
                            if ($opSignal.MergeSignalAndVerifyFailure($rest) -or -not $rest.HasResult()) { return $opSignal }

                            $opSignal.SetResult($rest.GetResult()) | Out-Null
                            break
                        }

                        $key=Get-OpenAIValue $config 'ModelKey'
                        if ($null -eq $key) { $key=$this.Settings.DefaultModelKey }
                        if ($key -isnot [string] -or -not $this.Settings.Profiles.ContainsKey($key)) { throw 'profile' }
                        $profile=$this.Settings.Profiles[$key]
                        if ($profile.Route.ApiKind -ceq 'OpenAIResponses') {
                            $legacyProfiles=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
                            $legacyProfiles.Add($key,[pscustomobject]@{Model=$profile.Model;ReasoningEffort=$profile.ReasoningEffort;MaxOutputTokens=$profile.MaxOutputTokens})
                            $selected=[pscustomobject]@{Address=$profile.Route.Address;Credential=$profile.Route.Credential;DefaultModelKey=$key;Profiles=$legacyProfiles}
                        } else { throw 'activity-profile' }
                    }

                    $r = Invoke-OpenAIResponses -Settings $selected -Plan $Plan -ConductionSignal $ConductionSignal | Select-Object -Last 1
                    if ($opSignal.MergeSignalAndVerifyFailure($r)) { return $opSignal }
                    if (-not $r.HasResult()) { throw 'response' }
                    $opSignal.SetResult($r.GetResult()) | Out-Null
                    break
                }

                'HandleMessage' {
                    $message = Resolve-PathFromDictionary -Dictionary $ItemSignal -Path $Plan.Path -SignalLevel 'Critical' | Select-Object -Last 1
                    if ($opSignal.MergeSignalAndVerifyFailure($message)) { return $opSignal }
                    if (-not $message.HasResult() -and @($message.Entries).Count -gt 0) { throw 'lookup' }
                    $format = Resolve-PathFromDictionary -Dictionary $Plan -Path 'Format' -SignalLevel 'Information' | Select-Object -Last 1
                    if ($format.HasResult() -and $format.GetResult()) {
                        $fs = [Signal]::Start('Intelligence_OpenAI.Format', $ItemSignal) | Select-Object -Last 1
                        $fs.SetJacket($message) | Out-Null
                        $fs.SetPointer($ItemSignal.GetPointer()) | Out-Null
                        $converted = Invoke-CondenserAdapter -Slot 'Format' -Activity $format.GetResult() -Plan $Plan -Signal $ConductionSignal -ItemSignal $fs | Select-Object -Last 1
                        if ($opSignal.MergeSignalAndVerifyFailure($converted) -or -not $converted.HasResult()) { return $opSignal }
                        $message.SetResult($converted.GetResult()) | Out-Null
                    }

                    if ($message.HasResult()) { $opSignal.SetResult($message.GetResult()) | Out-Null }
                    break
                }

                default { throw 'activity' }
            }
        } catch { $null = $opSignal.LogCritical('OpenAI activity failed.') }
        return $opSignal
    }
}

function Resolve-Intelligence_OpenAI { return [Intelligence_OpenAI]::new() }
Export-ModuleMember -Function Resolve-Intelligence_OpenAI
