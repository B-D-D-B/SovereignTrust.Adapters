function Get-OpenAIValue([object]$Object, [string]$Name) {
    if ($null -eq $Object) { return $null }
    if ($Object -is [Collections.IDictionary]) { return $Object[$Name] }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Resolve-OpenAISettings {
    param([object]$Jacket)
    $s = [Signal]::Start('Resolve-OpenAISettings') | Select-Object -Last 1
    try {
        if ((Get-OpenAIValue $Jacket 'ApiKind') -cne 'OpenAIResponses') { throw 'kind' }
        $addresses = @(Get-OpenAIValue $Jacket 'Addresses')
        $resources = @(Get-OpenAIValue $Jacket 'Resource')
        if ($addresses.Count -ne 1 -or $addresses[0] -isnot [string] -or $resources.Count -ne 1 -or
            $resources[0] -isnot [string] -or [string]::IsNullOrWhiteSpace($resources[0])) { throw 'jacket' }
        $uri = $null
        if (-not [Uri]::TryCreate($addresses[0], [UriKind]::Absolute, [ref]$uri) -or
            $uri.Scheme -cne 'https' -or $uri.Host -cne 'api.openai.com' -or $uri.Port -ne 443 -or
            $uri.AbsolutePath -cne '/v1/responses' -or $uri.UserInfo -or $uri.Query -or $uri.Fragment) { throw 'address' }
        $default = Get-OpenAIValue $Jacket 'DefaultModelKey'
        $items = @(Get-OpenAIValue $Jacket 'Profiles')
        if ($default -isnot [string] -or [string]::IsNullOrWhiteSpace($default) -or
            $items -is [string] -or $items -isnot [Collections.IEnumerable]) { throw 'profiles' }
        $profiles = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
        foreach ($item in $items) {
            $key = Get-OpenAIValue $item 'ModelKey'; $model = Get-OpenAIValue $item 'Model'
            $effort = Get-OpenAIValue $item 'ReasoningEffort'; $tokens = Get-OpenAIValue $item 'MaxOutputTokens'
            if ($key -isnot [string] -or [string]::IsNullOrWhiteSpace($key) -or $model -isnot [string] -or
                [string]::IsNullOrWhiteSpace($model) -or $profiles.ContainsKey($key)) { throw 'profile' }
            if ($null -ne $effort -and $effort -cnotin @('none','minimal','low','medium','high','xhigh','max')) { throw 'effort' }
            if ($null -ne $tokens -and (($tokens -isnot [int] -and $tokens -isnot [long]) -or $tokens -le 0)) { throw 'tokens' }
            $profiles.Add($key, [pscustomobject]@{ Model=$model; ReasoningEffort=$effort; MaxOutputTokens=$tokens })
        }
        if (-not $profiles.ContainsKey($default)) { throw 'default' }
        $s.SetResult([pscustomobject]@{ Address=$uri.AbsoluteUri; Credential=$resources[0]; DefaultModelKey=$default; Profiles=$profiles }) | Out-Null
    } catch { $null = $s.LogCritical('OpenAI settings are invalid.') }
    return $s
}

function Assert-OpenAIStaticGif([byte[]]$Bytes) {
    if ($Bytes.Length -lt 14 -or [Text.Encoding]::ASCII.GetString($Bytes,0,6) -cnotin @('GIF87a','GIF89a')) { throw 'gif-header' }
    $at=13
    if (($Bytes[10] -band 0x80) -ne 0) { $at += 3 * [math]::Pow(2,1+($Bytes[10] -band 7)) }
    $frames=0
    while ($at -lt $Bytes.Length) {
        $kind=$Bytes[$at];$at++
        if ($kind -eq 0x3B) { if($frames -ne 1){throw 'gif-frame'}; return }
        if ($kind -eq 0x2C) {
            $frames++
            if ($frames -gt 1 -or $at+9 -gt $Bytes.Length) { throw 'gif-frame' }
            $packed=$Bytes[$at+8];$at+=9
            if (($packed -band 0x80) -ne 0) { $at += 3 * [math]::Pow(2,1+($packed -band 7)) }
            $at++
        } elseif ($kind -eq 0x21) { $at++ } else { throw 'gif-block' }
        while ($at -lt $Bytes.Length) {
            $count=$Bytes[$at];$at++
            if ($count -eq 0) { break }
            $at += $count
            if ($at -gt $Bytes.Length) { throw 'gif-subblock' }
        }
    }
    throw 'gif-trailer'
}

function ConvertTo-OpenAIImagePart([object]$Item) {
    $type = Get-OpenAIValue $Item 'MediaType'
    $path = Get-OpenAIValue $Item 'MediaPath'
    $url = Get-OpenAIValue $Item 'MediaUrl'
    $detail = Get-OpenAIValue $Item 'Detail'
    if ($null -eq $detail) { $detail = 'auto' }
    if ($type -cne 'image' -or $detail -cnotin @('auto','low','high') -or
        (($path -is [string] -and $path.Trim().Length -gt 0) -eq ($url -is [string] -and $url.Trim().Length -gt 0))) { throw 'media' }
    if ($path) {
        if (-not [IO.File]::Exists($path)) { throw 'file' }
        $file = [IO.FileInfo]::new($path)
        if ($file.Length -gt 10MB -or $file.Length -lt 4) { throw 'size' }
        $bytes = [IO.File]::ReadAllBytes($path)
        $ext = $file.Extension.ToLowerInvariant()
        $mime = switch ($ext) {
            '.png' { if ($bytes.Length -lt 8 -or [Convert]::ToHexString($bytes[0..7]) -cne '89504E470D0A1A0A') { throw 'signature' }; 'image/png' }
            { $_ -in @('.jpg','.jpeg') } { if ($bytes[0] -ne 255 -or $bytes[1] -ne 216 -or $bytes[-2] -ne 255 -or $bytes[-1] -ne 217) { throw 'signature' }; 'image/jpeg' }
            '.webp' { if ([Text.Encoding]::ASCII.GetString($bytes,0,4) -cne 'RIFF' -or $bytes.Length -lt 12 -or [Text.Encoding]::ASCII.GetString($bytes,8,4) -cne 'WEBP') { throw 'signature' }; 'image/webp' }
            '.gif' { Assert-OpenAIStaticGif $bytes; 'image/gif' }
            default { throw 'extension' }
        }
        $url = 'data:' + $mime + ';base64,' + [Convert]::ToBase64String($bytes)
    } else {
        $uri = $null
        if (-not [Uri]::TryCreate($url,[UriKind]::Absolute,[ref]$uri) -or $uri.Scheme -cne 'https' -or $uri.UserInfo) { throw 'url' }
    }
    return @{ type='input_image'; image_url=$url; detail=$detail }
}

function Invoke-OpenAIResponses {
    param([object]$Settings, [object]$Plan, [Signal]$ConductionSignal, [ValidateRange(1,5)][int]$FixtureTimeoutSeconds = 0)
    $s = [Signal]::Start('Invoke-OpenAIResponses', $ConductionSignal) | Select-Object -Last 1
    try {
        $config = Get-OpenAIValue $Plan 'Config'
        if ($null -eq $config -or $null -ne (Get-OpenAIValue $config 'Model') -or
            $null -ne (Get-OpenAIValue $config 'MediaPath') -or $null -ne (Get-OpenAIValue $config 'MediaUrl')) { throw 'config' }
        $key = Get-OpenAIValue $config 'ModelKey'
        if ($null -eq $key) { $key = $Settings.DefaultModelKey }
        if ($key -isnot [string] -or -not $Settings.Profiles.ContainsKey($key)) { throw 'model' }
        $profile = $Settings.Profiles[$key]
        $prompt = Get-OpenAIValue $config 'Prompt'; $content = Get-OpenAIValue $config 'Content'
        if ($null -ne $prompt -and $null -ne $content) { throw 'prompt' }
        $input = @(); $parts = @()
        if ($null -ne $prompt) {
            $system = Get-OpenAIValue $prompt 'System'
            if ($system -is [string] -and $system.Trim()) { $input += @{ role='system'; content=$system } }
            foreach ($value in @(Get-OpenAIValue $prompt 'Texts')) {
                if ($null -eq $value) { continue }
                if ($value -isnot [string]) { throw 'text' }
                if ($value.Trim()) { $parts += @{ type='input_text'; text=$value } }
            }
            $media = @(Get-OpenAIValue $prompt 'Media') | Where-Object { $null -ne $_ }
            if ($media.Count -gt 10) { throw 'count' }
            foreach ($item in $media) { $parts += ConvertTo-OpenAIImagePart $item }
        } elseif ($content -is [string] -and $content.Trim()) { $parts += @{ type='input_text'; text=$content } }
        if ($parts.Count -eq 0) { throw 'empty' }
        $input += @{ role='user'; content=$parts }
        $body = @{ model=$profile.Model; input=$input }
        if ($null -ne $profile.ReasoningEffort) { $body.reasoning = @{ effort=$profile.ReasoningEffort } }
        if ($null -ne $profile.MaxOutputTokens) { $body.max_output_tokens = $profile.MaxOutputTokens }
        $json = ConvertTo-Json $body -Depth 30 -Compress
        if ([Text.Encoding]::UTF8.GetByteCount($json) -gt 20MB) { throw 'request-size' }
        $headers = @{ Authorization=('Bearer ' + $Settings.Credential); 'Content-Type'='application/json' }
        $oldProgress = $ProgressPreference
        try {
            $ProgressPreference = 'SilentlyContinue'
            $connectTimeout = if ($FixtureTimeoutSeconds) { $FixtureTimeoutSeconds } else { 30 }
            $operationTimeout = if ($FixtureTimeoutSeconds) { $FixtureTimeoutSeconds } else { 60 }
            $response = Invoke-WebRequest -Uri $Settings.Address -Method Post -Headers $headers -Body $json -ContentType 'application/json' -MaximumRetryCount 0 -MaximumRedirection 0 -ConnectionTimeoutSeconds $connectTimeout -OperationTimeoutSeconds $operationTimeout -SkipHttpErrorCheck -ErrorAction Stop -Verbose:$false -Debug:$false -WarningAction SilentlyContinue
        } finally { $ProgressPreference = $oldProgress }
        $status = [int]$response.StatusCode
        if ($status -lt 200 -or $status -ge 300) { $null = $s.LogCritical("OpenAI HTTP failure ($status)."); return $s }
        $responseText = if ($response.Content -is [byte[]]) { [Text.Encoding]::UTF8.GetString($response.Content) } else { [string]$response.Content }
        $parsed = ConvertFrom-Json -InputObject $responseText -Depth 100 -ErrorAction Stop
        if ($parsed.status -cne 'completed' -or $null -ne $parsed.error -or $null -ne $parsed.incomplete_details) { throw 'status' }
        $texts = @()
        foreach ($entry in @($parsed.output)) {
            if ($entry.type -cne 'message' -or $entry.role -cne 'assistant') { continue }
            foreach ($part in @($entry.content)) {
                if ($part.type -ceq 'refusal') { throw 'refusal' }
                if ($part.type -ceq 'output_text' -and $part.text -is [string] -and $part.text.Trim()) { $texts += $part.text }
            }
        }
        if ($texts.Count -eq 0) { throw 'output' }
        $normalized = @{ choices=@(@{ message=@{ role='assistant'; content=($texts -join "`n") } }) } | ConvertTo-Json -Depth 8 -Compress
        $s.SetResult($normalized) | Out-Null
    } catch { $null = $s.LogCritical('OpenAI request failed.') }
    return $s
}
