function Resolve-AzureFoundrySettings {
    param([object]$Jacket)
    $opSignal = [Signal]::Start('Resolve-AzureFoundrySettings') | Select-Object -Last 1
    try {
        $kindSignal = Resolve-PathFromDictionary -Dictionary $Jacket -Path 'ApiKind' -SignalLevel 'Information' | Select-Object -Last 1
        $defaultSignal = Resolve-PathFromDictionary -Dictionary $Jacket -Path 'DefaultModelKey' -SignalLevel 'Information' | Select-Object -Last 1
        $profilesSignal = Resolve-PathFromDictionary -Dictionary $Jacket -Path 'Profiles' -SignalLevel 'Information' | Select-Object -Last 1
        $addressSignal = Resolve-PathFromDictionary -Dictionary $Jacket -Path 'Addresses' -SignalLevel 'Information' | Select-Object -Last 1
        $resourceSignal = Resolve-PathFromDictionary -Dictionary $Jacket -Path 'Resource' -SignalLevel 'Information' | Select-Object -Last 1
        if ($kindSignal.Failure() -or -not $kindSignal.HasResult() -or $kindSignal.GetResult() -cne 'OpenAIResponses') { throw 'Foundry ApiKind must be OpenAIResponses.' }
        if ($defaultSignal.Failure() -or -not $defaultSignal.HasResult() -or $profilesSignal.Failure() -or -not $profilesSignal.HasResult()) { throw 'Foundry profiles are invalid.' }
        $defaultKey = $defaultSignal.GetResult()
        $profileItems = $profilesSignal.GetResult()
        if ($defaultKey -isnot [string] -or [string]::IsNullOrWhiteSpace($defaultKey) -or $profileItems -is [string] -or $profileItems -isnot [Collections.IEnumerable]) { throw 'Foundry profiles are invalid.' }
        $profiles = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
        foreach ($item in $profileItems) {
            if ($item -isnot [Collections.IDictionary] -and $item -isnot [pscustomobject]) { throw 'Foundry profiles are invalid.' }
            $keySignal = Resolve-PathFromDictionary -Dictionary $item -Path 'ModelKey' -SignalLevel 'Information' | Select-Object -Last 1
            $modelSignal = Resolve-PathFromDictionary -Dictionary $item -Path 'Model' -SignalLevel 'Information' | Select-Object -Last 1
            $effortSignal = Resolve-PathFromDictionary -Dictionary $item -Path 'ReasoningEffort' -SignalLevel 'Information' | Select-Object -Last 1
            if ($keySignal.Failure() -or -not $keySignal.HasResult() -or $modelSignal.Failure() -or -not $modelSignal.HasResult() -or $effortSignal.Failure() -or -not $effortSignal.HasResult()) { throw 'Foundry profiles are invalid.' }
            $key = $keySignal.GetResult(); $model = $modelSignal.GetResult(); $effort = $effortSignal.GetResult()
            if ($key -isnot [string] -or [string]::IsNullOrWhiteSpace($key) -or $model -isnot [string] -or [string]::IsNullOrWhiteSpace($model) -or
                $effort -isnot [string] -or $effort -cnotin @('none','minimal','low','medium','high','xhigh','max') -or $profiles.ContainsKey($key)) { throw 'Foundry profiles are invalid.' }
            $tokensSignal = Resolve-PathFromDictionary -Dictionary $item -Path 'MaxInputTokens' -SignalLevel 'Information' | Select-Object -Last 1
            $maxInputTokens = $null
            if (-not $tokensSignal.Failure() -and $tokensSignal.HasResult()) {
                $maxInputTokens = $tokensSignal.GetResult()
                if ($maxInputTokens -isnot [int] -and $maxInputTokens -isnot [long]) { throw 'Foundry profiles are invalid.' }
                if ($maxInputTokens -le 0) { throw 'Foundry profiles are invalid.' }
            }
            $profiles.Add($key, [pscustomobject]@{ ModelKey=$key; Model=$model; ReasoningEffort=$effort; MaxInputTokens=$maxInputTokens })
        }
        if ($profiles.Count -eq 0 -or -not $profiles.ContainsKey($defaultKey)) { throw 'Foundry profiles are invalid.' }
        $addresses = @(if ($addressSignal.HasResult()) { $addressSignal.GetResult() })
        $resources = @(if ($resourceSignal.HasResult()) { $resourceSignal.GetResult() })
        if ($addresses.Count -ne 1 -or $addresses[0] -isnot [string] -or $addresses[0] -notmatch '^https://[^/]+/openai/v1/responses/?$') { throw 'Foundry Responses address is invalid.' }
        if ($resources.Count -ne 1 -or $resources[0] -isnot [string] -or [string]::IsNullOrWhiteSpace($resources[0])) { throw 'Foundry credential is unavailable.' }
        $authSignal = Resolve-PathFromDictionary -Dictionary $Jacket -Path 'AuthenticationMode' -SignalLevel 'Information' | Select-Object -Last 1
        $authMode = if (-not $authSignal.Failure() -and $authSignal.HasResult()) { $authSignal.GetResult() } else { 'ApiKey' }
        if ($authMode -cnotin @('ApiKey','Entra')) { throw 'Foundry AuthenticationMode must be ApiKey or Entra.' }
        $opSignal.SetResult([pscustomobject]@{ ApiKind='OpenAIResponses'; DefaultModelKey=$defaultKey; Profiles=$profiles;
            Address=$addresses[0]; Credential=$resources[0]; AuthenticationMode=$authMode }) | Out-Null
    }
    catch { $null = $opSignal.LogCritical($_.Exception.Message) }
    return $opSignal
}

function Invoke-AzureFoundryOpenAIResponses {
    param([object]$Settings, [object]$Plan, [Signal]$ConductionSignal, [Signal]$ItemSignal)
    $opSignal = [Signal]::Start('Invoke-AzureFoundryOpenAIResponses', $ConductionSignal) | Select-Object -Last 1
    try {
        $keySignal = Resolve-PathFromDictionary -Dictionary $Plan -Path 'Config.ModelKey' -SignalLevel 'Information' | Select-Object -Last 1
        $modelKey = if (-not $keySignal.Failure() -and $keySignal.HasResult()) { $keySignal.GetResult() } else { $Settings.DefaultModelKey }
        if ($modelKey -isnot [string] -or [string]::IsNullOrWhiteSpace($modelKey) -or -not $Settings.Profiles.ContainsKey($modelKey)) { throw 'Foundry Config.ModelKey is not configured.' }
        $legacyModelSignal = Resolve-PathFromDictionary -Dictionary $Plan -Path 'Config.Model' -SignalLevel 'Information' | Select-Object -Last 1
        if ($legacyModelSignal.HasResult()) { throw 'Foundry Config.Model is unsupported; use Config.ModelKey.' }
        $profile = $Settings.Profiles[$modelKey]

        $systemSignal = Resolve-PathFromDictionary -Dictionary $Plan -Path 'Config.Prompt.System' -SignalLevel 'Information' | Select-Object -Last 1
        $textsSignal = Resolve-PathFromDictionary -Dictionary $Plan -Path 'Config.Prompt.Texts' -SignalLevel 'Information' | Select-Object -Last 1
        $mediaSignal = Resolve-PathFromDictionary -Dictionary $Plan -Path 'Config.Prompt.Media' -SignalLevel 'Information' | Select-Object -Last 1
        $contentSignal = Resolve-PathFromDictionary -Dictionary $Plan -Path 'Config.Content' -SignalLevel 'Information' | Select-Object -Last 1
        $input = @()
        if ($systemSignal.HasResult() -and -not [string]::IsNullOrWhiteSpace([string]$systemSignal.GetResult())) {
            $input += @{ role='system'; content=[string]$systemSignal.GetResult() }
        }
        $parts = @()
        if ($textsSignal.HasResult()) {
            foreach ($value in @($textsSignal.GetResult())) {
                if ($null -ne $value -and -not [string]::IsNullOrWhiteSpace([string]$value)) { $parts += @{ type='input_text'; text=[string]$value } }
            }
        }
        if ($contentSignal.HasResult() -and -not [string]::IsNullOrWhiteSpace([string]$contentSignal.GetResult())) {
            if ($parts.Count -gt 0) { throw 'Foundry Config.Content and Prompt.Texts are ambiguous.' }
            $parts += @{ type='input_text'; text=[string]$contentSignal.GetResult() }
        }
        $mediaItems = @()
        if ($mediaSignal.HasResult()) { $mediaItems = @($mediaSignal.GetResult()) }
        $legacyPathSignal = Resolve-PathFromDictionary -Dictionary $Plan -Path 'Config.MediaPath' -SignalLevel 'Information' | Select-Object -Last 1
        $legacyUrlSignal = Resolve-PathFromDictionary -Dictionary $Plan -Path 'Config.MediaUrl' -SignalLevel 'Information' | Select-Object -Last 1
        $legacyPath = if ($legacyPathSignal.HasResult()) { $legacyPathSignal.GetResult() } else { $null }
        $legacyUrl = if ($legacyUrlSignal.HasResult()) { $legacyUrlSignal.GetResult() } else { $null }
        if (-not [string]::IsNullOrWhiteSpace([string]$legacyPath) -or -not [string]::IsNullOrWhiteSpace([string]$legacyUrl)) {
            if ($mediaItems.Count -gt 0) { throw 'Foundry media sources are ambiguous.' }
            $mediaItems = @([pscustomobject]@{ MediaPath=$legacyPath; MediaUrl=$legacyUrl; MediaType='image'; Detail='high' })
        }
        foreach ($item in $mediaItems) {
            if ($null -eq $item) { continue }
            $pathSignal = Resolve-PathFromDictionary -Dictionary $item -Path 'MediaPath' -SignalLevel 'Information' | Select-Object -Last 1
            $urlSignal = Resolve-PathFromDictionary -Dictionary $item -Path 'MediaUrl' -SignalLevel 'Information' | Select-Object -Last 1
            $typeSignal = Resolve-PathFromDictionary -Dictionary $item -Path 'MediaType' -SignalLevel 'Information' | Select-Object -Last 1
            $detailSignal = Resolve-PathFromDictionary -Dictionary $item -Path 'Detail' -SignalLevel 'Information' | Select-Object -Last 1
            $path = if ($pathSignal.HasResult()) { $pathSignal.GetResult() } else { $null }
            $url = if ($urlSignal.HasResult()) { $urlSignal.GetResult() } else { $null }
            $type = if ($typeSignal.HasResult()) { $typeSignal.GetResult() } else { 'image' }
            $detail = if ($detailSignal.HasResult()) { $detailSignal.GetResult() } else { 'high' }
            if ($type -cne 'image' -or $detail -cnotin @('auto','low','high','original')) { throw 'Foundry image media options are invalid.' }
            if (-not [string]::IsNullOrWhiteSpace([string]$path) -and -not [string]::IsNullOrWhiteSpace([string]$url)) { throw 'Foundry image media source is ambiguous.' }
            if (-not [string]::IsNullOrWhiteSpace([string]$path)) {
                $extension = [IO.Path]::GetExtension([string]$path).ToLowerInvariant()
                $mime = switch ($extension) { '.jpg' {'image/jpeg'} '.jpeg' {'image/jpeg'} '.png' {'image/png'} '.webp' {'image/webp'} '.gif' {'image/gif'} default { throw 'Foundry image format is unsupported.' } }
                $url = 'data:' + $mime + ';base64,' + [Convert]::ToBase64String([IO.File]::ReadAllBytes([string]$path))
            }
            if (-not [string]::IsNullOrWhiteSpace([string]$url)) { $parts += @{ type='input_image'; image_url=[string]$url; detail=$detail } }
        }
        if ($parts.Count -gt 0) { $input += @{ role='user'; content=$parts } }
        if ($input.Count -eq 0) { throw 'Foundry prompt is empty.' }
        $body = @{ model=$profile.Model; reasoning=@{ effort=$profile.ReasoningEffort }; input=$input; max_output_tokens=13107 }
        $cloneSignal = Resolve-ClonePlan -Plan $Plan | Select-Object -Last 1
        if ($opSignal.MergeSignalAndVerifyFailure($cloneSignal) -or -not $cloneSignal.HasResult()) { return $opSignal }
        $clone = $cloneSignal.GetResult()
        $headers = @{ 'Content-Type'='application/json' }
        if ($Settings.AuthenticationMode -ceq 'ApiKey') { $headers['api-key'] = $Settings.Credential }
        else { $headers['Authorization'] = 'Bearer ' + $Settings.Credential }
        foreach ($field in @(
            @('Config.Method','Post'), @('Config.Host',$Settings.Address), @('Config.Uri',$Settings.Address),
            @('Config.CacheAccessToken',$true), @('Config.SkipBearerToken',$true), @('Config.Body',$body), @('Config.Headers',$headers)
        )) {
            $writeSignal = Add-PathToDictionary -Dictionary $clone -Path $field[0] -Value $field[1] | Select-Object -Last 1
            if ($opSignal.MergeSignalAndVerifyFailure($writeSignal)) { return $opSignal }
        }
        $responseSignal = Invoke-MappedAdapter -Adapter 'Condenser.Rest' -Activity 'POST' -Signal $ConductionSignal -Plan $clone -ItemSignal $ItemSignal | Select-Object -Last 1
        if ($opSignal.MergeSignalAndVerifyFailure($responseSignal) -or -not $responseSignal.HasResult()) { return $opSignal }
        $response = $responseSignal.GetResult()
        if ($response -is [string]) { $response = ConvertFrom-Json -InputObject $response -Depth 100 -ErrorAction Stop }
        $statusSignal = Resolve-PathFromDictionary -Dictionary $response -Path 'status' -SignalLevel 'Information' | Select-Object -Last 1
        if ($statusSignal.HasResult() -and $statusSignal.GetResult() -cne 'completed') { throw 'Foundry Responses request did not complete.' }
        $outputSignal = Resolve-PathFromDictionary -Dictionary $response -Path 'output' -SignalLevel 'Information' | Select-Object -Last 1
        if ($outputSignal.Failure() -or -not $outputSignal.HasResult()) { throw 'Foundry Responses output is unavailable.' }
        $texts = @()
        foreach ($entry in @($outputSignal.GetResult())) {
            $typeSignal = Resolve-PathFromDictionary -Dictionary $entry -Path 'type' -SignalLevel 'Information' | Select-Object -Last 1
            if (-not $typeSignal.HasResult() -or $typeSignal.GetResult() -cne 'message') { continue }
            $contentSignal = Resolve-PathFromDictionary -Dictionary $entry -Path 'content' -SignalLevel 'Information' | Select-Object -Last 1
            if (-not $contentSignal.HasResult()) { continue }
            foreach ($part in @($contentSignal.GetResult())) {
                $partTypeSignal = Resolve-PathFromDictionary -Dictionary $part -Path 'type' -SignalLevel 'Information' | Select-Object -Last 1
                $textSignal = Resolve-PathFromDictionary -Dictionary $part -Path 'text' -SignalLevel 'Information' | Select-Object -Last 1
                if ($partTypeSignal.HasResult() -and $partTypeSignal.GetResult() -ceq 'output_text' -and $textSignal.HasResult()) { $texts += [string]$textSignal.GetResult() }
            }
        }
        if ($texts.Count -eq 0) { throw 'Foundry Responses output contains no assistant text.' }
        $normalized = @{ choices=@(@{ message=@{ role='assistant'; content=($texts -join "`n") } }) } | ConvertTo-Json -Depth 8 -Compress
        $opSignal.SetResult($normalized) | Out-Null
        $null = $opSignal.LogInformation("Foundry model profile '$modelKey' completed.")
    }
    catch { $null = $opSignal.LogCritical("Foundry OpenAI Responses call failed: $($_.Exception.Message)") }
    return $opSignal
}
