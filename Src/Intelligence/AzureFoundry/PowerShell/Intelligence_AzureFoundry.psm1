using module SignalGraph

$stModuleName = 'SovereignTrust.Foundation'
if (-not (Get-Module -Name $stModuleName)) {
    $stPath = Join-Path $PSScriptRoot "../../../../../SovereignTrust.Foundation/Src/PowerShell/SovereignTrust.Foundation.psd1"
    Import-Module (Resolve-Path $stPath).ProviderPath -Force
}

. "$PSScriptRoot/Invoke-AzureFoundryOpenAIResponses.ps1"

class Intelligence_AzureFoundry {
    [object]$MappedAdapter
    [Signal]$Signal
    [object]$Settings

    Intelligence_AzureFoundry() { }

    Intelligence_AzureFoundry([object]$mappedAdapter) {
        $this.MappedAdapter = $mappedAdapter
    }

    [Signal] Construct([object]$dictionary) {
        $opSignal = [Signal]::Start("Intelligence_AzureFoundry.Construct") | Select-Object -Last 1

        try {
            if ($null -eq $dictionary) {
                $opSignal.LogCritical("Cannot construct Intelligence_AzureFoundry — provided dictionary is null.")
                return $opSignal
            }

            $version = Get-FoundryMember $dictionary 'SchemaVersion'
            if ($null -ne $version -and (($version -isnot [int] -and $version -isnot [long]) -or $version -ne 2)) {
                throw 'Foundry schema is invalid.'
            }

            $settingsSignal = if ($version -eq 2) { Resolve-AzureFoundryV2Settings -Jacket $dictionary | Select-Object -Last 1 } else {
                Resolve-AzureFoundrySettings -Jacket $dictionary | Select-Object -Last 1
            }

            if ($opSignal.MergeSignalAndVerifyFailure($settingsSignal) -or -not $settingsSignal.HasResult()) {
                return $opSignal
            }

            $this.Settings = $settingsSignal.GetResult()

            $this.Signal = [Signal]::Start("Intelligence_AzureFoundry") | Select-Object -Last 1

            $jacket = [Signal]::Start("Intelligence_AzureFoundry.Jacket") | Select-Object -Last 1
            $jacket.SetResult($dictionary)

            $this.Signal.SetJacket($jacket)
            $opSignal.LogInformation("Intelligence_AzureFoundry constructed successfully with provided jacket.")
        }
        catch {
            $opSignal.LogCritical("Error constructing Intelligence_AzureFoundry: $_")
        }

        return $opSignal
    }

    [Signal] Invoke(
        [string]$Slot,
        [string]$Activity,
        [Signal]$ConductionSignal,
        [object]$Plan,
        [Signal]$ItemSignal
    ) {
        $opSignal = [Signal]::Start("Intelligence_AzureFoundry.Invoke:$Slot.$Activity", $ConductionSignal) | Select-Object -Last 1

        try {
            if (-not $ConductionSignal) {
                $opSignal.LogCritical("Null ConductionSignal passed to Intelligence_AzureFoundry.Invoke()")
                return $opSignal
            }

            if (-not $Activity) {
                $opSignal.LogWarning("No Activity provided to Intelligence_AzureFoundry.Invoke()")
                return $opSignal
            }

            if ($Activity -ieq 'SendMessageOriginal') {
                throw 'Unsupported Foundry activity.'
            }

            # Resolve Config from Plan (or from Environment if you prefer)
            # Convention: Plan contains everything needed to hit the service for this step
            $configSignal = Resolve-PathFromDictionary -Dictionary $Plan -Path "Config" -SignalLevel "Warning" | Select-Object -Last 1
            $config = $configSignal.HasResult() ? $configSignal.GetResult() : $null
            if ($this.Settings.SchemaVersion -eq 2 -and $null -ne $config -and
                $config -isnot [Collections.IDictionary] -and $config -isnot [pscustomobject]) { throw 'Foundry Config is invalid.' }

            if (-not $config) {
                # Optional fallback: pull config from Environment/Jacket
                # $env = $ConductionSignal.GetJacket().GetResult()
                # $configSignal = Resolve-PathFromDictionary -Dictionary $env -Path "Network.StorageNetwork.Config" -SignalLevel "Warning" | Select-Object -Last 1
                $opSignal.LogWarning("StorageNetwork Config not found on Plan.Config (no fallback enabled).")
            }

            $resultSignal = $null

            switch ($Activity) {
                "ValidateProfiles" {
                    if ($this.Settings.SchemaVersion -ne 2) { throw 'Foundry profile validation requires schema 2.' }
                    $worker = Get-FoundryMember $config 'WorkerProfile'
                    $reviewer = Get-FoundryMember $config 'ReviewerProfile'
                    if ($worker -cne 'visual-worker-standard' -or
                        $reviewer -cnotin @('visual-reviewer-standard','visual-reviewer-advanced') -or
                        -not $this.Settings.Profiles.ContainsKey($worker) -or
                        -not $this.Settings.Profiles.ContainsKey($reviewer)) {
                        throw 'Foundry artifact profiles are invalid.'
                    }
                    $opSignal.SetResult($true) | Out-Null
                    break
                }
                "SendMessage" {
                    $selected = $this.Settings
                    if ($this.Settings.SchemaVersion -eq 2) {
                        $selector = Get-FoundryMember $config 'Profile'
                        if ($null -ne $selector) {
                            Assert-FoundryFields $config @('Profile','Prompt') @('Profile','Prompt')
                            Assert-FoundryFields $selector @('Key') @('Key')
                            $key=Get-FoundryMember $selector 'Key'
                            if ($key -isnot [string] -or -not $this.Settings.Profiles.ContainsKey($key)) {
                                throw 'Foundry profile is unavailable.'
                            }

                            $binding=$this.Settings.Profiles[$key]
                            if ($binding.Route.ApiKind -ceq 'OpenAIResponses') {
                                throw 'Foundry profile is not an image route.'
                            }

                            $profilesSignal=Resolve-PathFromDictionary -Dictionary $this.Signal -Path '%.@.Profiles' -SignalLevel 'Information' | Select-Object -Last 1
                            $routesSignal=Resolve-PathFromDictionary -Dictionary $this.Signal -Path '%.@.Routes' -SignalLevel 'Information' | Select-Object -Last 1
                            $resourcesSignal=Resolve-PathFromDictionary -Dictionary $this.Signal -Path '%.@.Resource' -SignalLevel 'Information' | Select-Object -Last 1
                            if (-not $profilesSignal.HasResult() -or -not $routesSignal.HasResult() -or -not $resourcesSignal.HasResult()) {
                                throw 'Foundry jacket is unavailable.'
                            }

                            $profiles=@($profilesSignal.GetResult())
                            $routes=@($routesSignal.GetResult())
                            $resources=@($resourcesSignal.GetResult())
                            $profile=$profiles[(Resolve-FoundryIndex $profiles $key)]
                            $routeKey=Get-FoundryMember $profile 'RouteKey'
                            $model=Get-FoundryMember $profile 'Model'
                            if ($routeKey -isnot [string] -or $model -isnot [string]) {
                                throw 'Foundry profile binding is invalid.'
                            }

                            $routeIndex=Resolve-FoundryIndex $routes $routeKey
                            $route=$routes[$routeIndex]
                            $resourceKey=Get-FoundryMember $route 'ResourceKey'
                            if ($resourceKey -isnot [string]) {
                                throw 'Foundry resource binding is invalid.'
                            }

                            $resourceIndex=Resolve-FoundryIndex $resources $resourceKey
                            $addressSignal=Resolve-PathFromDictionary -Dictionary $this.Signal -Path "%.@.Routes.$routeIndex.Address" -SignalLevel 'Information' | Select-Object -Last 1
                            $credentialSignal=Resolve-PathFromDictionary -Dictionary $this.Signal -Path "%.@.Resource.$resourceIndex.Credentials" -SignalLevel 'Information' | Select-Object -Last 1
                            if (-not $addressSignal.HasResult() -or -not $credentialSignal.HasResult()) {
                                throw 'Foundry route/resource is unavailable.'
                            }

                            $kind=Get-FoundryMember $route 'ApiKind'
                            $auth=Get-FoundryMember $route 'AuthMode'
                            if ($kind -isnot [string] -or $auth -isnot [string] -or
                                $kind -cnotin @('OpenAIImageGeneration','OpenAIImageEdit','BlackForestLabsFlux2') -or
                                $binding.Model -cne $model -or $binding.Route.Key -cne $routeKey -or
                                $binding.Route.ResourceKey -cne (Get-FoundryMember $route 'ResourceKey') -or
                                $binding.Route.ApiKind -cne $kind -or $binding.Route.AuthMode -cne $auth) { throw 'Foundry binding is invalid.' }
                            $address=Assert-FoundryRoute $addressSignal.GetResult() $kind
                            if ($address -cne $binding.Route.Address) {
                                throw 'Foundry address is invalid.'
                            }

                            $credential=$credentialSignal.GetResult()
                            if ($credential -isnot [string] -or -not $credential.Trim() -or $credential -cne $binding.Route.Credential) {
                                throw 'Foundry credential is unavailable.'
                            }

                            $prompt=Get-FoundryMember $config 'Prompt'
                            if ($prompt -isnot [Collections.IDictionary] -and $prompt -isnot [pscustomobject]) {
                                throw 'Foundry prompt is invalid.'
                            }

                            $nativeModel=Get-FoundryMember $prompt 'model'
                            if ($nativeModel -isnot [string] -or $nativeModel -cne $model) {
                                throw 'Foundry prompt model is invalid.'
                            }

                            $streamNames=@(if ($prompt -is [Collections.IDictionary]) {$prompt.Keys} else {$prompt.PSObject.Properties.Name})
                            if ('stream' -cin $streamNames) {
                                $stream=Get-FoundryMember $prompt 'stream'
                                if ($stream -isnot [bool] -or $stream) {
                                    throw 'Foundry stream is unsupported.'
                                }
                            }

                            $json=ConvertTo-Json -InputObject $prompt -Depth 100 -WarningAction Stop -ErrorAction Stop
                            if ([Text.Encoding]::UTF8.GetByteCount($json) -gt 1MB) {
                                throw 'Foundry request exceeds the limit.'
                            }

                            $headers=@{'Content-Type'='application/json'}
                            if ($kind -ceq 'BlackForestLabsFlux2' -and $auth -ceq 'BearerApiKey') { $headers['Authorization']="Bearer $credential" }
                            elseif ($kind -cne 'BlackForestLabsFlux2' -and $auth -ceq 'ApiKey') { $headers['api-key']=$credential }
                            else { throw 'Foundry image auth is invalid.' }
                            $cloneSignal=Resolve-ClonePlan -Plan $Plan | Select-Object -Last 1
                            if ($opSignal.MergeSignalAndVerifyFailure($cloneSignal) -or -not $cloneSignal.HasResult()) {
                                return $opSignal
                            }

                            $clone=$cloneSignal.GetResult()
                            foreach ($field in @(
                                @('Config.Method','Post'),@('Config.Host',$address),@('Config.Uri',$address),
                                @('Config.SkipBearerToken',$true),@('Config.Body',$prompt),@('Config.Headers',$headers)
                            )) {
                                $write=Add-PathToDictionary -Dictionary $clone -Path $field[0] -Value $field[1] | Select-Object -Last 1
                                if ($opSignal.MergeSignalAndVerifyFailure($write)) {
                                    return $opSignal
                                }
                            }

                            $resultSignal=Invoke-MappedAdapter -Adapter 'Condenser.Rest' -Activity 'POST' -Signal $ConductionSignal -Plan $clone -ItemSignal $ItemSignal | Select-Object -Last 1
                            if ($opSignal.MergeSignalAndVerifyFailure($resultSignal) -or -not $resultSignal.HasResult()) {
                                return $opSignal
                            }

                            $opSignal.SetResult($resultSignal.GetResult()) | Out-Null
                            $resultSignal=$null
                            break
                        }

                        $modelKey=Get-FoundryMember $config 'ModelKey'
                        if ($null -eq $modelKey) { $modelKey=$this.Settings.DefaultModelKey }
                        if ($modelKey -isnot [string] -or -not $this.Settings.Profiles.ContainsKey($modelKey)) {
                            throw 'Foundry text profile is unavailable.'
                        }

                        $profile=$this.Settings.Profiles[$modelKey]
                        if ($profile.Route.ApiKind -cne 'OpenAIResponses') {
                            throw 'Foundry profile is not a Responses route.'
                        }

                        $legacyProfiles=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
                        $legacyProfiles.Add($modelKey,[pscustomobject]@{Model=$profile.Model;ReasoningEffort=$profile.ReasoningEffort;MaxInputTokens=$null;ExplicitPromptCacheSupported=$profile.ExplicitPromptCacheSupported})
                        $selected=[pscustomobject]@{ApiKind='OpenAIResponses';DefaultModelKey=$modelKey;Profiles=$legacyProfiles;
                            Address=$profile.Route.Address;Credential=$profile.Route.Credential;AuthenticationMode=$profile.Route.AuthMode}
                    }

                    if ($selected.ApiKind -cne 'OpenAIResponses') {
                        throw 'Unsupported Foundry API kind.'
                    }

                    $resultSignal = Invoke-AzureFoundryOpenAIResponses -Settings $selected -Plan $Plan -ConductionSignal $ConductionSignal -ItemSignal $ItemSignal | Select-Object -Last 1
                    if ($opSignal.MergeSignalAndVerifyFailure($resultSignal)) {
                        return $opSignal
                    }

                    if (-not $resultSignal.HasResult()) {
                        throw 'Foundry response is unavailable.'
                    }

                    $opSignal.SetResult($resultSignal.GetResult()) | Out-Null
                    $resultSignal = $null
                    break
                }

                "HandleMessage" {
                    $MessageSignal = Resolve-PathFromDictionary -Dictionary $ItemSignal -Path $Plan.Path | Select-Object -Last 1

                    # TODO: Review if we should keep format inside of the Memory Condenser
                    $FormatSignal = Resolve-PathFromDictionary -Dictionary $Plan -Path "Format" -SignalLevel "Warning" | Select-Object -Last 1
                    $Format = $FormatSignal.HasResult()    ? $FormatSignal.GetResult()    : $null
                    if ($Format) {
                        $FormatSignal = [Signal]::Start("MemoryCondenser.Invoke.Format", $ItemSignal) | Select-Object -Last 1
                        $FormatSignal.SetJacket($MessageSignal)
                        $FormatSignal.SetPointer($ItemSignal.GetPointer())

                        $StepResultSignal = Invoke-CondenserAdapter -Slot "Format" -Activity $Format -Plan $Plan -Signal $ConductionSignal -ItemSignal $FormatSignal | Select-Object -Last 1
                        if ($opSignal.MergeSignalAndVerifyFailure($StepResultSignal)) {
                            return $opSignal
                        }

                        $MessageSignal.SetResult($StepResultSignal.GetResult())
                    }

                    if ($MessageSignal.HasResult()) {
                        $opSignal.SetResult($MessageSignal.GetResult())
                    }
                    break   
                }

                default {
                    $opSignal.LogWarning("Unsupported Activity: $Activity")
                    $resultSignal = [Signal]::Start("StorageNetwork.UnsupportedActivity", $ItemSignal) | Select-Object -Last 1
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
            $opSignal.LogCritical("🔥 Exception in Intelligence_AzureFoundry.Invoke: $($_.Exception.Message)", $null, $_)
        }

        return $opSignal
    }
}

function Resolve-Intelligence_AzureFoundry {
    $object = [Intelligence_AzureFoundry]::new()
    return $object
}

Export-ModuleMember -Function Resolve-Intelligence_AzureFoundry
