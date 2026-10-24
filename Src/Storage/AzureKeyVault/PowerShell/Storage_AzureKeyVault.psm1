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
                Uri = $uri; Host = $vaultBase; Method = 'Get'; CacheAccessToken = $true
            } }
            $responseSignal = Invoke-MappedAdapter -Adapter 'Condenser.Rest' -Activity 'Get' -Signal $ConductionSignal -Plan $restPlan -ItemSignal $ItemSignal | Select-Object -Last 1
            if ($null -eq $responseSignal -or $responseSignal.Failure() -or -not $responseSignal.HasResult()) {
                if ($responseSignal) { $opSignal.MergeSignal($responseSignal) }
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
        $opSignal.LogCritical("Key Vault List failed: $($_.Exception.Message)", $null, $_)
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

            if ($Activity -ieq 'List') {
                return Invoke-AzureKeyVault_ListObject -AdapterSignal $this.Signal -ConductionSignal $ConductionSignal -ItemSignal $ItemSignal -Plan $Plan |
                    Select-Object -Last 1
            }

            # Resolve Config from Plan (or from Environment if you prefer)
            # Convention: Plan contains everything needed to hit the service for this step
            $configSignal = Resolve-PathFromDictionary -Dictionary $Plan -Path "Config" -SignalLevel "Warning" | Select-Object -Last 1
            $config = $configSignal.HasResult() ? $configSignal.GetResult() : $null

            if (-not $config) {
                # Optional fallback: pull config from Environment/Jacket
                # $env = $ConductionSignal.GetJacket().GetResult()
                # $configSignal = Resolve-PathFromDictionary -Dictionary $env -Path "Queue.StorageQueue.Config" -SignalLevel "Warning" | Select-Object -Last 1
                $opSignal.LogWarning("StorageQueue Config not found on Plan.Config (no fallback enabled).")
            }

            $virtualPathParts = $config.VirtualPath -Split '\.'

            $Activity = $virtualPathParts[2]
            $Secret = $virtualPathParts[3]

            $resultSignal = $null 

            switch ($Activity) {

                # ---------------------------------------------------------
                # Canonical verbs
                # ---------------------------------------------------------

                "Read" {
                    # Response Message to Discord
                    $hostUriSignal = Resolve-PathFromDictionary -Dictionary $this.Signal -Path "%.@.Addresses.0" | Select-Object -Last 1
                    $uri = "$($hostUriSignal.GetResult())secrets/$Secret"#/$applicationId/$interactionToken"

                    $clonePlan = (Resolve-ClonePlan -Plan $Plan | Select-Object -Last 1).GetResult()

                    $null = Add-PathToDictionary -Dictionary $clonePlan -Path "Config.Uri" -Value $uri
                    $null = Add-PathToDictionary -Dictionary $clonePlan -Path "Config.Method" -Value "Get"
                    $null = Add-PathToDictionary -Dictionary $clonePlan -Path "Config.Host" -Value $hostUriSignal.GetResult()
                    $null = Add-PathToDictionary -Dictionary $clonePlan -Path "Config.CacheAccessToken" -Value $true
                    $null = Add-PathToDictionary -Dictionary $clonePlan -Path "Config.Querystring" -Value "?api-version=7.4"

                    # Call Rest Endpoint
                    $responseSignal = Invoke-MappedAdapter -Adapter "Condenser.Rest" -Activity "Get" -Signal $ConductionSignal -Plan $clonePlan -ItemSignal $ItemSignal
                    if ($opSignal.MergeSignalAndVerifyFailure($responseSignal)) { return $opSignal }

                    $opSignal.SetResult(($responseSignal.GetResult()).value)

                    break
                }

                default {
                    $opSignal.LogWarning("Unsupported Activity: $Activity")
                    $resultSignal = [Signal]::Start("StorageQueue.UnsupportedActivity", $ItemSignal) | Select-Object -Last 1
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
            $opSignal.LogCritical("🔥 Exception in Storage_AzureKeyVault.Invoke: $($_.Exception.Message)", $null, $_)
        }

        return $opSignal
    }
}

function Resolve-Storage_AzureKeyVault {
    $object = [Storage_AzureKeyVault]::new()
    return $object
}

Export-ModuleMember -Function Resolve-Storage_AzureKeyVault
