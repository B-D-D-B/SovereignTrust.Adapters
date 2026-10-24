function Invoke-AzureStorageAccount_ListObject {
    param(
        [Parameter(Mandatory)][Signal]$ConductionSignal,
        [Parameter(Mandatory)][Signal]$ItemSignal,
        [Parameter(Mandatory)][object]$Plan,
        [Parameter()][AllowEmptyString()][string]$VirtualPath,
        [Parameter(Mandatory)][object]$Resource,
        [Parameter(Mandatory)][object]$Addresses
    )

    $opSignal = [Signal]::Start("Invoke-AzureStorageAccount_ListObject:$VirtualPath", $ItemSignal) | Select-Object -Last 1
    try {
        $config = $Plan.Config
        $filter = [string]$config.Filter
        $sortBy = if ([string]::IsNullOrWhiteSpace([string]$config.SortBy)) { 'FileName' } else { [string]$config.SortBy }
        $direction = if ([string]::IsNullOrWhiteSpace([string]$config.SortDirection)) { 'Descending' } else { [string]$config.SortDirection }
        $type = if ([string]::IsNullOrWhiteSpace([string]$config.Type)) { 'File' } else { [string]$config.Type }
        if ($sortBy -notin @('DateTime', 'FileName', 'Size') -or
            $direction -notin @('Ascending', 'Descending') -or $type -notin @('File', 'Directory')) {
            return $opSignal.LogCritical('Invalid Azure storage List SortBy, SortDirection or Type.')
        }

        $address = [string]@($Addresses)[0]
        $container = ([string]$Resource).Trim('/')
        if ([string]::IsNullOrWhiteSpace($address) -or [string]::IsNullOrWhiteSpace($container)) {
            return $opSignal.LogCritical('Azure storage List requires an address and Resource container.')
        }
        $scope = ([string]$VirtualPath).Replace('\', '/').Trim('/')
        if ($scope) { $scope += '/' }
        $uri = "$($address.TrimEnd('/'))/$([uri]::EscapeDataString($container))?restype=container&comp=list"
        if ($scope) { $uri += '&prefix=' + [uri]::EscapeDataString($scope) }
        if ($type -ieq 'Directory') { $uri += '&delimiter=%2F' }

        $items = [System.Collections.Generic.List[object]]::new()
        $seenMarkers = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
        $marker = $null
        do {
            $pageUri = $uri
            if ($marker) { $pageUri += '&marker=' + [uri]::EscapeDataString($marker) }
            $restPlan = [pscustomobject]@{
                Config = [pscustomobject]@{
                    Uri = $pageUri
                    Host = 'https://storage.azure.com/'
                    Method = 'Get'
                    Headers = @{ 'x-ms-version' = '2023-11-03'; Accept = 'application/xml' }
                    CacheAccessToken = $true
                }
            }
            $responseSignal = Invoke-MappedAdapter -Adapter 'Condenser.Rest' -Activity 'Get' -Signal $ConductionSignal -Plan $restPlan -ItemSignal $ItemSignal | Select-Object -Last 1
            if ($null -eq $responseSignal -or $responseSignal.Failure() -or -not $responseSignal.HasResult()) {
                if ($responseSignal) { $opSignal.MergeSignal($responseSignal) }
                return $opSignal.LogCritical('Azure storage List page failed.')
            }
            $raw = $responseSignal.GetResult($true)
            $xml = if ($raw -is [System.Xml.XmlDocument]) { $raw } else {
                $parsed = [System.Xml.XmlDocument]::new()
                $parsed.LoadXml([string]$raw)
                $parsed
            }
            if ($null -eq $xml.DocumentElement -or $xml.DocumentElement.LocalName -ne 'EnumerationResults' -or
                $null -eq $xml.EnumerationResults.Blobs) {
                return $opSignal.LogCritical('Invalid Azure storage List XML.')
            }
            if ($type -ieq 'Directory') {
                foreach ($entry in @($xml.EnumerationResults.Blobs.BlobPrefix)) {
                    if ($null -eq $entry) { continue }
                    $name = [string]$entry.Name
                    if (-not $name.EndsWith('/') -or ($scope -and -not $name.StartsWith($scope, [StringComparison]::Ordinal))) {
                        return $opSignal.LogCritical('Invalid Azure storage directory prefix.')
                    }
                    $leaf = ($name.TrimEnd('/') -split '/')[-1]
                    $items.Add([pscustomobject]@{ FileName = $leaf; VirtualPath = $name; DateTime = $null; Size = $null })
                }
            }
            else {
                foreach ($entry in @($xml.EnumerationResults.Blobs.Blob)) {
                    if ($null -eq $entry) { continue }
                    $name = [string]$entry.Name
                    if (-not $name -or ($scope -and -not $name.StartsWith($scope, [StringComparison]::Ordinal))) {
                        return $opSignal.LogCritical('Invalid Azure storage blob name.')
                    }
                    $date = $null
                    if ($entry.Properties.'Last-Modified') {
                        $date = [datetimeoffset]::Parse([string]$entry.Properties.'Last-Modified', [Globalization.CultureInfo]::InvariantCulture).UtcDateTime.ToString('o')
                    }
                    $size = $null
                    if ($null -ne $entry.Properties.'Content-Length' -and [string]$entry.Properties.'Content-Length' -ne '') {
                        $size = [long]::Parse([string]$entry.Properties.'Content-Length', [Globalization.CultureInfo]::InvariantCulture)
                        if ($size -lt 0) { throw 'Negative blob size.' }
                    }
                    $items.Add([pscustomobject]@{ FileName = ($name -split '/')[-1]; VirtualPath = $name; DateTime = $date; Size = $size })
                }
            }
            $marker = [string]$xml.EnumerationResults.NextMarker
            if ($marker -and -not $seenMarkers.Add($marker)) {
                return $opSignal.LogCritical('Repeated Azure storage List marker.')
            }
        } while ($marker)

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
        $opSignal.LogCritical("Azure storage List failed: $($_.Exception.Message)", $null, $_)
    }
    return $opSignal
}
