using module SignalGraph
$stModuleName = 'SovereignTrust.Foundation'
if (-not (Get-Module -Name $stModuleName)) {
    $stPath = Join-Path $PSScriptRoot "../../../../../SovereignTrust.Foundation/Src/PowerShell/SovereignTrust.Foundation.psd1"
    Import-Module (Resolve-Path $stPath).ProviderPath -Force
}

# ---- Load queue functions (your existing REST surface) ----
# Use your existing implementations here
# . "$PSScriptRoot/Read-StorageQueueApi.ps1"
# Optional if you have them:
# . "$PSScriptRoot/Delete-StorageQueueMessageApi.ps1"
# . "$PSScriptRoot/Update-StorageQueueVisibilityApi.ps1"
# . "$PSScriptRoot/Write-StorageQueueApi.ps1"

function Test-AzureKeyVaultField {
    param([object]$Object, [string]$Name)
    if ($null -eq $Object) { return $false }
    if ($Object -is [System.Collections.IDictionary]) {
        foreach ($key in $Object.Keys) { if ([string]$key -ceq $Name) { return $true } }
        return $false
    }
    return $null -ne $Object.PSObject.Properties[$Name]
}

function Invoke-AzureKeyVault_ListObject {
    param(
        [Parameter(Mandatory)][Signal]$AdapterSignal,
        [Parameter(Mandatory)][Signal]$ConductionSignal,
        [Parameter(Mandatory)][Signal]$ItemSignal,
        [Parameter(Mandatory)][object]$Plan
    )
    $opSignal = [Signal]::Start('Storage_AzureKeyVault.List', $ItemSignal) | Select-Object -Last 1
    try {
        $config = $Plan.Config
        $filter = [string]$config.Filter
        $sortBy = if ([string]::IsNullOrWhiteSpace([string]$config.SortBy)) { 'FileName' } else { [string]$config.SortBy }
        $direction = if ([string]::IsNullOrWhiteSpace([string]$config.SortDirection)) { 'Descending' } else { [string]$config.SortDirection }
        $type = if ([string]::IsNullOrWhiteSpace([string]$config.Type)) { 'File' } else { [string]$config.Type }
        if ($sortBy -notin @('DateTime', 'FileName', 'Size') -or
            $direction -notin @('Ascending', 'Descending') -or $type -notin @('File', 'Directory')) {
            return $opSignal.LogCritical('Invalid Key Vault List SortBy, SortDirection or Type.')
        }
        if ($type -ieq 'Directory') {
            $opSignal.SetResult([pscustomobject]@{ Items = [object[]]@(); Count = 0 })
            return $opSignal
        }

        $path = if (-not [string]::IsNullOrWhiteSpace([string]$config.VirtualPath)) {
            [string]$config.VirtualPath
        } else { [string]$Plan.VirtualPath }
        $prefix = if ($path.Trim('/') -eq '') { '' } else { $path }

        $hostSignal = Resolve-PathFromDictionary -Dictionary $AdapterSignal -Path '%.@.Addresses.0' | Select-Object -Last 1
        if ($null -eq $hostSignal -or $hostSignal.Failure() -or -not $hostSignal.HasResult()) {
            return $opSignal.LogCritical('Key Vault List requires a vault address.')
        }
        $vault = [uri]([string]$hostSignal.GetResult())
        if ($vault.Scheme -ne 'https' -or -not $vault.IsAbsoluteUri -or $vault.AbsolutePath.Trim('/') -ne '') {
            return $opSignal.LogCritical('Invalid Key Vault address.')
        }
        $vaultBase = $vault.GetLeftPart([System.UriPartial]::Authority)
        $uri = "$vaultBase/secrets?api-version=7.4"
        $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        $items = [System.Collections.Generic.List[object]]::new()
        while ($uri) {
            if (-not $seen.Add($uri)) { return $opSignal.LogCritical('Repeated Key Vault List continuation.') }
            $restPlan = [pscustomobject]@{ Config = [pscustomobject]@{
                Uri = $uri; Host = $vaultBase; Method = 'Get'; CacheAccessToken = $true; RedactDiagnostics = $true
            } }
            $responseSignal = Invoke-MappedAdapter -Adapter 'Condenser.Rest' -Activity 'Get' -Signal $ConductionSignal -Plan $restPlan -ItemSignal $ItemSignal | Select-Object -Last 1
            if ($null -eq $responseSignal -or $responseSignal.Failure() -or -not $responseSignal.HasResult()) {
                return $opSignal.LogCritical('Key Vault List page failed.')
            }
            $page = $responseSignal.GetResult($true)
            if ($page -is [string]) { $page = $page | ConvertFrom-Json -Depth 30 }
            if ($null -eq $page -or $null -eq $page.PSObject.Properties['value'] -or
                $page.value -isnot [array]) {
                return $opSignal.LogCritical('Invalid Key Vault List response.')
            }
            foreach ($entry in $page.value) {
                if ($null -eq $entry -or [string]::IsNullOrWhiteSpace([string]$entry.id)) {
                    return $opSignal.LogCritical('Invalid Key Vault secret metadata.')
                }
                $id = [uri]([string]$entry.id)
                if ($id.Scheme -ne 'https' -or $id.Authority -ine $vault.Authority -or
                    $id.AbsolutePath -notmatch '^/secrets/([^/]+)$') {
                    return $opSignal.LogCritical('Invalid Key Vault secret identifier.')
                }
                $name = [uri]::UnescapeDataString($Matches[1])
                if ($prefix -and -not $name.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { continue }
                $date = $null
                if ($null -ne $entry.attributes -and $null -ne $entry.attributes.updated) {
                    $date = [DateTimeOffset]::FromUnixTimeSeconds([long]$entry.attributes.updated).UtcDateTime.ToString('o')
                }
                $items.Add([pscustomobject]@{ FileName = $name; VirtualPath = $name; DateTime = $date; Size = $null })
            }
            $next = [string]$page.nextLink
            if ($next) {
                $nextUri = [uri]$next
                if (-not $nextUri.IsAbsoluteUri -or $nextUri.Scheme -ne 'https' -or
                    $nextUri.Authority -ine $vault.Authority -or $nextUri.AbsolutePath -ne '/secrets') {
                    return $opSignal.LogCritical('Invalid Key Vault List nextLink.')
                }
            }
            $uri = $next
        }

        $pattern = if ([string]::IsNullOrWhiteSpace($filter)) { $null } else {
            [System.Management.Automation.WildcardPattern]::new($filter, [System.Management.Automation.WildcardOptions]::IgnoreCase)
        }
        $filtered = [System.Collections.Generic.List[object]]::new()
        foreach ($item in $items) {
            if ($null -eq $pattern -or $pattern.IsMatch($item.FileName)) { $filtered.Add($item) }
        }
        $multiplier = if ($direction -ieq 'Descending') { -1 } else { 1 }
        $comparison = [System.Comparison[object]]{
            param($a, $b)
            $av = $a.$sortBy
            $bv = $b.$sortBy
            if ($null -eq $av -and $null -ne $bv) { return 1 }
            if ($null -ne $av -and $null -eq $bv) { return -1 }
            if ($null -ne $av -and $null -ne $bv) {
                $c = if ($sortBy -ieq 'Size') { [long]$av.CompareTo([long]$bv) }
                     elseif ($sortBy -ieq 'DateTime') { [long]([datetime]$av).CompareTo([datetime]$bv) }
                     else { [string]::Compare([string]$av, [string]$bv, [StringComparison]::OrdinalIgnoreCase) }
                if ($c) { return ($multiplier * [Math]::Sign($c)) }
            }
            $c = [string]::Compare($a.FileName, $b.FileName, [StringComparison]::OrdinalIgnoreCase)
            if ($c) { return $c }
            $c = [string]::Compare($a.VirtualPath, $b.VirtualPath, [StringComparison]::OrdinalIgnoreCase)
            if ($c) { return $c }
            return [string]::Compare($a.VirtualPath, $b.VirtualPath, [StringComparison]::Ordinal)
        }
        $filtered.Sort($comparison)
        $opSignal.SetResult([pscustomobject]@{ Items = [object[]]$filtered.ToArray(); Count = $filtered.Count })
    }
    catch {
        $opSignal.LogCritical('Key Vault List failed.')
    }
    return $opSignal
}

class Storage_AzureKeyVault {
    [object]$MappedAdapter
    [Signal]$Signal

    Storage_AzureKeyVault() { }

    Storage_AzureKeyVault([object]$mappedAdapter) {
        $this.MappedAdapter = $mappedAdapter
    }

    [Signal] Construct([object]$dictionary) {
        $opSignal = [Signal]::Start("Storage_AzureKeyVault.Construct") | Select-Object -Last 1

        try {
            if ($null -eq $dictionary) {
                $opSignal.LogCritical("Cannot construct Storage_AzureKeyVault — provided dictionary is null.")
                return $opSignal
            }

            $resolved = Resolve-StorageResourceRoutesJacket -Jacket $dictionary -Family AzureKeyVault | Select-Object -Last 1
            if ($resolved.Failure() -or -not $resolved.HasResult()) {
                return $opSignal.LogCritical('Invalid Key Vault storage jacket.')
            }
            $dictionary = $resolved.GetResult()

            $this.Signal = [Signal]::Start("Storage_AzureKeyVault") | Select-Object -Last 1

            $jacket = [Signal]::Start("Storage_AzureKeyVault.Jacket") | Select-Object -Last 1
            $jacket.SetResult($dictionary)

            $this.Signal.SetJacket($jacket)
            $opSignal.LogInformation("Storage_AzureKeyVault constructed successfully with provided jacket.")
        }
        catch {
            $opSignal.LogCritical("Error constructing Storage_AzureKeyVault: $_")
        }

        return $opSignal
    }

    # ---------------------------------------------------------------------
    # Universal Invoke entry 
    # Activity uses canonical verb set: ReadBatch, PeekBatch, AckItem, DeferItem, WriteItem
    # ---------------------------------------------------------------------
    [Signal] Invoke(
        [string]$Slot,
        [string]$Activity,
        [Signal]$ConductionSignal,
        [object]$Plan,
        [Signal]$ItemSignal
    ) {
        $opSignal = [Signal]::Start("Storage_AzureKeyVault.Invoke:$Slot.$Activity", $ItemSignal) | Select-Object -Last 1

        try {
            if (-not $ConductionSignal) {
                $opSignal.LogCritical("❌ Null ConductionSignal passed to Storage_AzureKeyVault.Invoke()")
                return $opSignal
            }

            $opSignal.SetJacket($ConductionSignal)

            if (-not $Activity) {
                $opSignal.LogWarning("No Activity provided to Storage_AzureKeyVault.Invoke()")
                return $opSignal
            }
            if ((Test-AzureKeyVaultField $Plan.Config 'SourcePath') -or
                (Test-AzureKeyVaultField $Plan.Config 'TargetPath')) {
                return $opSignal.LogCritical('Key Vault storage does not support file transfer paths.')
            }

            if ($Activity -ieq 'List') {
                return Invoke-AzureKeyVault_ListObject -AdapterSignal $this.Signal -ConductionSignal $ConductionSignal -ItemSignal $ItemSignal -Plan $Plan |
                    Select-Object -Last 1
            }

            if ($Activity -inotmatch '^(Read|Write|Delete|Exists)$') {
                return $opSignal.LogCritical('Unsupported Key Vault storage activity.')
            }
            $config = $Plan.Config
            $hasExplicitPath = Test-AzureKeyVaultField $config 'VirtualPath'
            $path = if ($hasExplicitPath) {
                [string]$config.VirtualPath
            } elseif (Test-AzureKeyVaultField $Plan 'VirtualPath') {
                [string]$Plan.VirtualPath
            } else {
                if (-not [string]::IsNullOrEmpty([string]$Plan.Container)) {
                    return $opSignal.LogCritical('Key Vault storage Container must be empty.')
                }
                '/' + [string]$Plan.Resource
            }
            $legacy = [regex]::Match($path, '^Storage\.Secrets\.Read\.([A-Za-z0-9-]+)$', 'IgnoreCase')
            if ($legacy.Success) {
                if ($Activity -ine 'Read') { return $opSignal.LogCritical('Key Vault legacy path activity disagrees with supplied activity.') }
                $name = $legacy.Groups[1].Value
            } elseif ($hasExplicitPath) {
                $name = $path
            } else {
                if (-not $path.StartsWith('/')) { return $opSignal.LogCritical('Key Vault mapped path must start with one slash.') }
                $name = $path.Substring(1)
            }
            if ($name -cnotmatch '^[A-Za-z0-9-]{1,127}$' -or
                (-not $hasExplicitPath -and -not [string]::IsNullOrEmpty([string]$Plan.Container))) {
                return $opSignal.LogCritical('Invalid Key Vault secret name or container.')
            }
            $hostSignal = Resolve-PathFromDictionary -Dictionary $this.Signal -Path '%.@.Addresses.0' | Select-Object -Last 1
            $vault = $null
            if ($hostSignal.Failure() -or -not $hostSignal.HasResult() -or
                -not [uri]::TryCreate([string]$hostSignal.GetResult(), [UriKind]::Absolute, [ref]$vault) -or
                $vault.Scheme -cne 'https' -or $vault.AbsolutePath.Trim('/') -ne '' -or
                $vault.Host -notmatch '^[A-Za-z0-9-]+\.vault\.azure\.net$') {
                return $opSignal.LogCritical('Invalid Key Vault address.')
            }
            $base = $vault.GetLeftPart([UriPartial]::Authority)
            $uri = "$base/secrets/$name"
            $restConfig = [ordered]@{
                Uri = $uri; Host = $base; Method = 'Get'; CacheAccessToken = $true
                Querystring = '?api-version=7.4'; ReturnHttpStatus = $true; RedactDiagnostics = $true
            }
            if ($Activity -ieq 'Write') {
                if (-not (Test-AzureKeyVaultField $config 'Content') -or $null -eq $config.Content -or
                    (Test-AzureKeyVaultField $config 'SourcePath') -or (Test-AzureKeyVaultField $config 'TargetPath')) {
                    return $opSignal.LogCritical('Key Vault Write requires supported Content without file transfer paths.')
                }
                if ($config.Content -is [byte[]]) { return $opSignal.LogCritical('Key Vault Write does not accept binary Content.') }
                $value = if ($config.Content -is [string]) { $config.Content } elseif ($config.Content -is [pscustomobject] -or
                    $config.Content -is [System.Collections.IDictionary] -or $config.Content -is [array]) {
                    ConvertTo-Json -InputObject $config.Content -Depth 100 -Compress
                } else { return $opSignal.LogCritical('Key Vault Write Content type is unsupported.') }
                if ([Text.Encoding]::UTF8.GetByteCount($value) -gt 25600) {
                    return $opSignal.LogCritical('Key Vault Write Content exceeds the secret size limit.')
                }
                $body = [ordered]@{ value = $value }
                if (-not [string]::IsNullOrEmpty([string]$config.ContentType)) {
                    if (([string]$config.ContentType).Length -gt 255) { return $opSignal.LogCritical('Key Vault ContentType is too long.') }
                    $body.contentType = [string]$config.ContentType
                }
                $restConfig.Method = 'Put'
                $restConfig.ContentType = 'application/json; charset=utf-8'
                $restConfig.Body = ConvertTo-Json -InputObject $body -Compress -Depth 10
            } elseif ($Activity -ieq 'Delete') { $restConfig.Method = 'Delete' }
            $restPlan = [pscustomobject]@{ Config = [pscustomobject]$restConfig }
            $responseSignal = Invoke-MappedAdapter -Adapter 'Condenser.Rest' -Activity $restConfig.Method -Signal $ConductionSignal -Plan $restPlan -ItemSignal $ItemSignal | Select-Object -Last 1
            if ($null -eq $responseSignal -or $responseSignal.Failure() -or -not $responseSignal.HasResult()) {
                return $opSignal.LogCritical('Key Vault request failed.')
            }
            $envelope = $responseSignal.GetResult($true)
            $status = $envelope.StatusCode
            if ($null -eq $status -or $status -isnot [int]) { return $opSignal.LogCritical('Key Vault response status is invalid.') }
            if ($Activity -ieq 'Exists' -and $status -eq 404) { $opSignal.SetResult($false); return $opSignal }
            if ($status -ne 200) { return $opSignal.LogCritical('Key Vault request returned an unsuccessful status.') }
            $response = $envelope.Response
            if ($response -is [string] -and $response) {
                try { $response = ConvertFrom-Json -InputObject $response -Depth 30 -ErrorAction Stop }
                catch { return $opSignal.LogCritical('Key Vault response is malformed.') }
            }
            if ($Activity -ieq 'Exists') { $opSignal.SetResult($true); return $opSignal }
            if ($Activity -ieq 'Read') {
                if ($null -eq $response -or $response.value -isnot [string]) { return $opSignal.LogCritical('Key Vault Read response is invalid.') }
                $opSignal.SetResult([string]$response.value)
            } elseif ($Activity -ieq 'Write') {
                $id = $null
                if ($null -ne $response) { [uri]::TryCreate([string]$response.id, [UriKind]::Absolute, [ref]$id) | Out-Null }
                if ($null -eq $id -or $id.Scheme -cne 'https' -or $id.Authority -ine $vault.Authority -or
                    $id.AbsolutePath -notmatch "^/secrets/$name/[^/]+$") { return $opSignal.LogCritical('Key Vault Write response id is invalid.') }
                $opSignal.SetResult($id.AbsoluteUri)
            } else {
                if ($null -eq $response -or [string]$response.id -notmatch "^$([regex]::Escape($base))/secrets/$name/") {
                    return $opSignal.LogCritical('Key Vault Delete response is invalid.')
                }
                $opSignal.SetResult($true)
            }

        }
        catch {
            $opSignal.LogCritical('Key Vault storage activity failed.')
        }

        return $opSignal
    }
}

function Resolve-Storage_AzureKeyVault {
    $object = [Storage_AzureKeyVault]::new()
    return $object
}

Export-ModuleMember -Function Resolve-Storage_AzureKeyVault
