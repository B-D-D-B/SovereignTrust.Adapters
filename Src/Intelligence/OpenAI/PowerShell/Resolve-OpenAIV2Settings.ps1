function Assert-OpenAIImageEndpoint([object]$Address, [string]$Path) {
    $uri = $null
    if ($Address -isnot [string] -or -not [Uri]::TryCreate($Address,[UriKind]::Absolute,[ref]$uri) -or
        $uri.Scheme -cne 'https' -or $uri.Host -cne 'api.openai.com' -or $uri.Port -ne 443 -or
        $uri.AbsolutePath -cne $Path -or $uri.UserInfo -or $uri.Query -or $uri.Fragment) { throw 'endpoint' }
    return $uri.AbsoluteUri
}

function Resolve-OpenAIV2Settings {
    param([object]$Jacket)
    $opSignal = [Signal]::Start('Resolve-OpenAIV2Settings') | Select-Object -Last 1

    try {
        foreach ($legacy in @('ApiKind','DefaultModelKey','Addresses')) {
            if ($null -ne (Get-OpenAIValue $Jacket $legacy)) { throw 'mixed-schema' }
        }

        $resources = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
        $routes = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
        $profiles = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)

        foreach ($item in @(Get-OpenAIValue $Jacket 'Resource')) {
            $key = Get-OpenAIValue $item 'Key'; $credential = Get-OpenAIValue $item 'Credentials'
            if ($key -isnot [string] -or -not $key.Trim() -or $resources.ContainsKey($key) -or
                $credential -isnot [string] -or -not $credential.Trim()) { throw 'resource' }

            $resources.Add($key,$credential)
        }

        if (-not $resources.Count) { throw 'resource-empty' }

        $paths = @{ OpenAIResponses='/v1/responses'; OpenAIImageGeneration='/v1/images/generations'; OpenAIImageEdit='/v1/images/edits' }

        foreach ($item in @(Get-OpenAIValue $Jacket 'Routes')) {
            $key=Get-OpenAIValue $item 'Key'; $kind=Get-OpenAIValue $item 'ApiKind'
            $resourceKey=Get-OpenAIValue $item 'ResourceKey'; $auth=Get-OpenAIValue $item 'AuthMode'
            if ($key -isnot [string] -or -not $key.Trim() -or $routes.ContainsKey($key) -or
                $kind -isnot [string] -or -not $paths.ContainsKey($kind) -or
                $resourceKey -isnot [string] -or -not $resources.ContainsKey($resourceKey) -or $auth -cne 'ApiKey') { throw 'route' }

            $address=Assert-OpenAIImageEndpoint (Get-OpenAIValue $item 'Address') $paths[$kind]
            $routes.Add($key,[pscustomobject]@{Key=$key;ApiKind=$kind;Address=$address;Credential=$resources[$resourceKey]})
        }

        if (-not $routes.Count) { throw 'routes-empty' }

        $default=$null

        foreach ($item in @(Get-OpenAIValue $Jacket 'Profiles')) {
            $key=Get-OpenAIValue $item 'Key'; $routeKey=Get-OpenAIValue $item 'RouteKey'; $model=Get-OpenAIValue $item 'Model'
            $isDefault=Get-OpenAIValue $item 'IsDefault'; $effort=Get-OpenAIValue $item 'ReasoningEffort'
            $tokens=Get-OpenAIValue $item 'MaxOutputTokens'
            if ($key -isnot [string] -or -not $key.Trim() -or $profiles.ContainsKey($key) -or
                $routeKey -isnot [string] -or -not $routes.ContainsKey($routeKey) -or
                $model -isnot [string] -or -not $model.Trim() -or $isDefault -isnot [bool]) { throw 'profile' }

            $route=$routes[$routeKey]

            if ($route.ApiKind -cne 'OpenAIResponses') {
                if ($null -ne $effort -or $null -ne $tokens -or $isDefault) { throw 'image-profile' }
            } else {
                if ($null -ne $effort -and $effort -cnotin @('none','minimal','low','medium','high','xhigh','max')) { throw 'effort' }
                if ($null -ne $tokens -and (($tokens -isnot [int] -and $tokens -isnot [long]) -or $tokens -le 0)) { throw 'tokens' }
            }

            if ($isDefault) { if ($null -ne $default) { throw 'default-count' }; $default=$key }

            $profiles.Add($key,[pscustomobject]@{Key=$key;Model=$model;Route=$route;ReasoningEffort=$effort;MaxOutputTokens=$tokens})
        }

        if (-not $profiles.Count -or $null -eq $default) { throw 'default' }

        $opSignal.SetResult([pscustomobject]@{SchemaVersion=2;Profiles=$profiles;DefaultModelKey=$default}) | Out-Null
    } catch { $null=$opSignal.LogCritical('OpenAI v2 settings are invalid.') }

    return $opSignal
}
