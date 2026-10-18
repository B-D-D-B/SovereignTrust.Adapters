function Assert-CodexCLIAllowedMembers {
    param([object]$Object, [string[]]$Allowed, [string]$Context)
    $opSignal = [Signal]::Start("Assert-CodexCLIAllowedMembers:$Context") | Select-Object -Last 1
    try {
        $keysSignal = Get-CodexCLIKeys $Object | Select-Object -Last 1
        if ($opSignal.MergeSignalAndVerifyFailure($keysSignal)) { return $opSignal }
        foreach ($name in @($keysSignal.GetResult())) {
            if ($name -cnotin $Allowed) {
                $literalSignal = Get-CodexCLILiteralMember $Object $name | Select-Object -Last 1
                if ($opSignal.MergeSignalAndVerifyFailure($literalSignal)) { return $opSignal }
                $value = $null
                if ($literalSignal.HasResult()) { $value = $literalSignal.GetResult() }
                if ($null -ne $value -and ($value -isnot [string] -or -not [string]::IsNullOrWhiteSpace($value))) {
                    throw 'Unsupported member.'
                }
            }
        }
        $opSignal.SetResult($true) | Out-Null
    }
    catch { $null = $opSignal.LogCritical("Unsupported $Context member.") }
    return $opSignal
}

function Resolve-CodexCLIPrompt {
    param([object]$Config, [object]$Runtime)
    $opSignal = [Signal]::Start('Resolve-CodexCLIPrompt') | Select-Object -Last 1
    try {
    if ($null -eq $Config) { throw 'CodexCLI requires Plan.Config.' }
    $allowedSignal = Assert-CodexCLIAllowedMembers $Config @('Prompt','Content','ModelKey','OutputSchema','Break') 'Config' | Select-Object -Last 1
    if ($opSignal.MergeSignalAndVerifyFailure($allowedSignal)) { return $opSignal }
    $contentSignal = Resolve-PathFromDictionary -Dictionary $Config -Path 'Content' -SignalLevel 'Information' | Select-Object -Last 1
    $content = $null
    if (-not $contentSignal.Failure() -and $contentSignal.HasResult()) { $content = $contentSignal.GetResult() }
    if ($null -ne $content -and $content -isnot [string]) { throw 'Config.Content must be text.' }
    $promptSignal = Resolve-PathFromDictionary -Dictionary $Config -Path 'Prompt' -SignalLevel 'Information' | Select-Object -Last 1
    $promptValue = $null
    if (-not $promptSignal.Failure() -and $promptSignal.HasResult()) { $promptValue = $promptSignal.GetResult() }
    $hasPrompt = $null -ne $promptValue -and ($promptValue -isnot [string] -or -not [string]::IsNullOrWhiteSpace($promptValue))
    if ($hasPrompt -and -not [string]::IsNullOrWhiteSpace($content)) { throw 'Config.Prompt and Config.Content are ambiguous.' }
    $media = @()
    $prompt = $null
    if ($promptValue -is [string]) { $prompt = $promptValue }
    elseif ($null -ne $promptValue) {
        if ($promptValue -isnot [Collections.IDictionary] -and $promptValue -isnot [pscustomobject]) { throw 'Config.Prompt type is invalid.' }
        $promptAllowedSignal = Assert-CodexCLIAllowedMembers $promptValue @('System','Texts','Media') 'Prompt' | Select-Object -Last 1
        if ($opSignal.MergeSignalAndVerifyFailure($promptAllowedSignal)) { return $opSignal }
        $parts = @()
        $systemSignal = Resolve-PathFromDictionary -Dictionary $promptValue -Path 'System' -SignalLevel 'Information' | Select-Object -Last 1
        $system = $null
        if (-not $systemSignal.Failure() -and $systemSignal.HasResult()) { $system = $systemSignal.GetResult() }
        if ($null -ne $system -and $system -isnot [string]) { throw 'Prompt.System must be text.' }
        if (-not [string]::IsNullOrWhiteSpace($system)) { $parts += "System:`n$system" }
        $textsSignal = Resolve-PathFromDictionary -Dictionary $promptValue -Path 'Texts' -SignalLevel 'Information' | Select-Object -Last 1
        $texts = $null
        if (-not $textsSignal.Failure() -and $textsSignal.HasResult()) { $texts = $textsSignal.GetResult() }
        if ($null -ne $texts) {
            if ($texts -is [string] -or $texts -isnot [Collections.IEnumerable]) { throw 'Prompt.Texts must be a list.' }
            foreach ($item in $texts) {
                if ($null -ne $item -and $item -isnot [string]) { throw 'Prompt.Texts items must be text.' }
                if (-not [string]::IsNullOrWhiteSpace($item)) { $parts += $item }
            }
        }
        $prompt = $parts -join "`n`n"
        $mediaField = Resolve-PathFromDictionary -Dictionary $promptValue -Path 'Media' -SignalLevel 'Information' | Select-Object -Last 1
        $mediaValue = $null
        if (-not $mediaField.Failure() -and $mediaField.HasResult()) { $mediaValue = $mediaField.GetResult() }
        if ($null -ne $mediaValue) {
            if ($mediaValue -is [string] -or $mediaValue -isnot [Collections.IEnumerable]) { throw 'Prompt.Media must be a list.' }
            $media = @($mediaValue)
        }
    }
    elseif (-not [string]::IsNullOrWhiteSpace($content)) { $prompt = $content }
    $keySignal = Resolve-PathFromDictionary -Dictionary $Config -Path 'ModelKey' -SignalLevel 'Information' | Select-Object -Last 1
    $modelKey = $null
    if (-not $keySignal.Failure() -and $keySignal.HasResult()) { $modelKey = $keySignal.GetResult() }
    if ($null -ne $modelKey -and ($modelKey -isnot [string] -or [string]::IsNullOrWhiteSpace($modelKey))) { throw 'Config.ModelKey must be nonblank text.' }
    if ($null -eq $modelKey) { $modelKey = $Runtime.DefaultModelKey }
    if (-not $Runtime.Profiles.ContainsKey($modelKey)) { throw 'Config.ModelKey is not configured.' }
    $profile = $Runtime.Profiles[$modelKey]
    $schemaSignal = Resolve-PathFromDictionary -Dictionary $Config -Path 'OutputSchema' -SignalLevel 'Information' | Select-Object -Last 1
    $schema = $null
    if (-not $schemaSignal.Failure() -and $schemaSignal.HasResult()) { $schema = $schemaSignal.GetResult() }
    $schemaJson = $null
    if ($null -ne $schema) {
        if ($null -eq (Get-Command Test-Json -ErrorAction SilentlyContinue)) { throw 'Local schema validation is unavailable.' }
        $schemaResultSignal = Resolve-CodexCLISchema $schema | Select-Object -Last 1
        if ($opSignal.MergeSignalAndVerifyFailure($schemaResultSignal)) { return $opSignal }
        $schemaJson = $schemaResultSignal.GetResult()
    }
    if ([string]::IsNullOrWhiteSpace($prompt) -and $media.Count -eq 0) { throw 'CodexCLI prompt is empty.' }
    $bytes = [Text.Encoding]::UTF8.GetByteCount($prompt)
    if ($null -ne $schemaJson) { $bytes += [Text.Encoding]::UTF8.GetByteCount($schemaJson) }
    if ($bytes -gt $Runtime.Limits.MaxPromptBytes) { throw 'CodexCLI prompt exceeds the configured limit.' }
    $opSignal.SetResult([pscustomobject]@{ Text=$prompt; Media=$media; ModelKey=$modelKey; Model=$profile.Model; ReasoningEffort=$profile.ReasoningEffort; SchemaJson=$schemaJson }) | Out-Null
    }
    catch {
        $safe = Get-CodexCLISafeFailureMessage $_.Exception.Message @(
            'CodexCLI requires Plan.Config.', 'Unsupported Config member.', 'Unsupported Prompt member.',
            'Config.Content must be text.',
            'Config.Prompt and Config.Content are ambiguous.', 'Config.Prompt type is invalid.',
            'Prompt.System must be text.', 'Prompt.Texts must be a list.', 'Prompt.Texts items must be text.',
            'Prompt.Media must be a list.', 'Config.ModelKey must be nonblank text.', 'Config.ModelKey is not configured.',
            'Local schema validation is unavailable.', 'CodexCLI prompt is empty.',
            'CodexCLI prompt exceeds the configured limit.', 'OutputSchema must be an object.',
            'OutputSchema contains an unsupported keyword.', 'OutputSchema must be a flat closed object.',
            'OutputSchema properties are required.', 'OutputSchema property limit exceeded.',
            'OutputSchema required list is invalid.', 'OutputSchema requires every property exactly once.',
            'OutputSchema property is invalid.', 'OutputSchema property type is unsupported.'
        ) 'CodexCLI prompt, model, or schema validation failed.'
        $null = $opSignal.LogCritical($safe)
    }
    return $opSignal
}

function Resolve-CodexCLISchema {
    param([object]$Schema)
    $opSignal = [Signal]::Start('Resolve-CodexCLISchema') | Select-Object -Last 1
    try {
    if ($Schema -isnot [Collections.IDictionary] -and $Schema -isnot [pscustomobject]) { throw 'OutputSchema must be an object.' }
    $keysSignal = Get-CodexCLIKeys $Schema | Select-Object -Last 1
    if ($opSignal.MergeSignalAndVerifyFailure($keysSignal)) { return $opSignal }
    foreach ($key in @($keysSignal.GetResult())) { if ($key -cnotin @('$schema','type','properties','required','additionalProperties')) { throw 'OutputSchema contains an unsupported keyword.' } }
    $schemaIdPresence = Test-CodexCLIMember $Schema '$schema' | Select-Object -Last 1
    if ($opSignal.MergeSignalAndVerifyFailure($schemaIdPresence)) { return $opSignal }
    $schemaIdSignal = Resolve-PathFromDictionary -Dictionary $Schema -Path '$schema' -SignalLevel 'Information' | Select-Object -Last 1
    $schemaId = $null
    if (-not $schemaIdSignal.Failure() -and $schemaIdSignal.HasResult()) { $schemaId = $schemaIdSignal.GetResult() }
    $typeSignal = Resolve-PathFromDictionary -Dictionary $Schema -Path 'type' -SignalLevel 'Information' | Select-Object -Last 1
    $type = $null
    if (-not $typeSignal.Failure() -and $typeSignal.HasResult()) { $type = $typeSignal.GetResult() }
    $closedSignal = Resolve-PathFromDictionary -Dictionary $Schema -Path 'additionalProperties' -SignalLevel 'Information' | Select-Object -Last 1
    $closed = $null
    if (-not $closedSignal.Failure() -and $closedSignal.HasResult()) { $closed = $closedSignal.GetResult() }
    if (($schemaIdPresence.GetResult() -and ($schemaIdSignal.Failure() -or -not $schemaIdSignal.HasResult() -or
            $schemaId -isnot [string] -or $schemaId -cne 'https://json-schema.org/draft/2020-12/schema')) -or
        $type -isnot [string] -or $type -cne 'object' -or
        $closed -isnot [bool] -or $closed -cne $false) {
        throw 'OutputSchema must be a flat closed object.'
    }
    $propertiesSignal = Resolve-PathFromDictionary -Dictionary $Schema -Path 'properties' -SignalLevel 'Information' | Select-Object -Last 1
    $properties = $null
    if (-not $propertiesSignal.Failure() -and $propertiesSignal.HasResult()) { $properties = $propertiesSignal.GetResult() }
    if ($properties -isnot [Collections.IDictionary] -and $properties -isnot [pscustomobject]) { throw 'OutputSchema properties are required.' }
    $namesSignal = Get-CodexCLIKeys $properties | Select-Object -Last 1
    if ($opSignal.MergeSignalAndVerifyFailure($namesSignal)) { return $opSignal }
    $names = @($namesSignal.GetResult())
    if ($names.Count -gt 256 -or (@($names | ForEach-Object Length | Measure-Object -Sum).Sum) -gt 16384) { throw 'OutputSchema property limit exceeded.' }
    $requiredSignal = Resolve-PathFromDictionary -Dictionary $Schema -Path 'required' -SignalLevel 'Information' | Select-Object -Last 1
    $required = $null
    if (-not $requiredSignal.Failure() -and $requiredSignal.HasResult()) { $required = $requiredSignal.GetResult() }
    if ($required -is [string] -or $required -isnot [Collections.IEnumerable]) { throw 'OutputSchema required list is invalid.' }
    $requiredNames = @($required)
    if ($requiredNames.Count -ne $names.Count -or @($requiredNames | Select-Object -Unique).Count -ne $names.Count) { throw 'OutputSchema requires every property exactly once.' }
    foreach ($name in $names) {
        if ($name -isnot [string] -or [string]::IsNullOrWhiteSpace($name) -or $name -cnotin $requiredNames) { throw 'OutputSchema required list is invalid.' }
        $propertySignal = Get-CodexCLILiteralMember $properties $name | Select-Object -Last 1
        if ($opSignal.MergeSignalAndVerifyFailure($propertySignal)) { return $opSignal }
        $property = $null
        if ($propertySignal.HasResult()) { $property = $propertySignal.GetResult() }
        if ($property -isnot [Collections.IDictionary] -and $property -isnot [pscustomobject]) { throw 'OutputSchema property is invalid.' }
        $propertyKeysSignal = Get-CodexCLIKeys $property | Select-Object -Last 1
        if ($opSignal.MergeSignalAndVerifyFailure($propertyKeysSignal)) { return $opSignal }
        $typePresence = Test-CodexCLIMember $property 'type' | Select-Object -Last 1
        if ($opSignal.MergeSignalAndVerifyFailure($typePresence)) { return $opSignal }
        $propertyTypeSignal = Resolve-PathFromDictionary -Dictionary $property -Path 'type' -SignalLevel 'Information' | Select-Object -Last 1
        $propertyType = $null
        if (-not $propertyTypeSignal.Failure() -and $propertyTypeSignal.HasResult()) { $propertyType = $propertyTypeSignal.GetResult() }
        if (@($propertyKeysSignal.GetResult()).Count -ne 1 -or -not $typePresence.GetResult() -or
            $propertyType -isnot [string] -or $propertyType -cnotin @('string','integer','number','boolean','null')) { throw 'OutputSchema property type is unsupported.' }
    }
    foreach ($name in $requiredNames) { if ($name -isnot [string] -or $name -cnotin $names) { throw 'OutputSchema required list is invalid.' } }
    $opSignal.SetResult((ConvertTo-Json -InputObject $Schema -Depth 10 -Compress)) | Out-Null
    }
    catch {
        $safe = Get-CodexCLISafeFailureMessage $_.Exception.Message @(
            'OutputSchema must be an object.', 'OutputSchema contains an unsupported keyword.',
            'OutputSchema must be a flat closed object.', 'OutputSchema properties are required.',
            'OutputSchema property limit exceeded.', 'OutputSchema required list is invalid.',
            'OutputSchema requires every property exactly once.', 'OutputSchema property is invalid.',
            'OutputSchema property type is unsupported.'
        ) 'OutputSchema validation failed.'
        $null = $opSignal.LogCritical($safe)
    }
    return $opSignal
}
