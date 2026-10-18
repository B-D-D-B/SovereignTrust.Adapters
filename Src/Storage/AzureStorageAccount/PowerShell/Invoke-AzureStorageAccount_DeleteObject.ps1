function Invoke-AzureStorageAccount_DeleteObject {
    param (
        [Parameter(Mandatory)][Signal]$ConductionSignal,
        [Parameter(Mandatory)][Signal]$Signal,
        [Parameter(Mandatory)][Signal]$ItemSignal,
        [Parameter(Mandatory)][object]$Plan,
        [Parameter(Mandatory)][string]$VirtualPath,
        [Parameter(Mandatory)][object]$Resource,
        [Parameter(Mandatory)][object]$Addresses
    )

    $opSignal = [Signal]::Start("Invoke-AzureStorageAccount_DeleteObject:$VirtualPath", $ItemSignal) | Select-Object -Last 1

    try {
        $pathSuffixSignal = Resolve-PathFromDictionary -Dictionary $Plan -Path "Config.PathSuffix" -SignalLevel "Warning" | Select-Object -Last 1
        $pathSuffix = if ($pathSuffixSignal.HasResult()) { [string]$pathSuffixSignal.GetResult() } else { $null }
        if ($pathSuffix -and -not $VirtualPath.EndsWith($pathSuffix, [System.StringComparison]::OrdinalIgnoreCase)) {
            $VirtualPath = "$VirtualPath$pathSuffix"
        }

        $blobPath = $VirtualPath.Replace('\', '/').TrimStart('/')
        $container = ([string]$Resource).Trim('/')
        $address = @($Addresses)[0]
        if ([string]::IsNullOrWhiteSpace($blobPath) -or [string]::IsNullOrWhiteSpace($container) -or [string]::IsNullOrWhiteSpace([string]$address)) {
            return $opSignal.LogCritical("Azure blob Delete requires a path, Resource container, and first address.")
        }
        $encodedBlobPath = ($blobPath.Split('/') | ForEach-Object { [uri]::EscapeDataString($_) }) -join '/'

        $hostAddress = ([string]$address).TrimEnd('/')
        $blobUri = "$hostAddress/$container/$encodedBlobPath"
        $restPlan = [pscustomobject]@{
            Config = [pscustomobject]@{
                Uri = $blobUri
                Host = "https://storage.azure.com/"
                Method = "Delete"
                Headers = @{ "x-ms-version" = "2023-11-03" }
                CacheAccessToken = $true
                ReturnHttpStatus = $true
            }
        }

        $responseSignal = Invoke-MappedAdapter -Adapter "Condenser.Rest" -Activity "Delete" -Signal $ConductionSignal -Plan $restPlan -ItemSignal $ItemSignal | Select-Object -Last 1
        if ($null -eq $responseSignal) { return $opSignal.LogCritical("Azure REST adapter returned no signal for Delete.") }
        if ($responseSignal.Failure() -or -not $responseSignal.HasResult()) {
            $opSignal.MergeSignal($responseSignal)
            return $opSignal.LogCritical("Azure blob Delete request failed for '$blobPath'.")
        }

        $response = $responseSignal.GetResult($true)
        $statusCode = [int]$response.StatusCode
        if ($statusCode -eq 202) {
            $opSignal.SetResult($true)
        }
        elseif ($statusCode -eq 404 -and $response.Headers['x-ms-error-code'] -eq 'BlobNotFound') {
            $opSignal.SetResult($false)
        }
        else {
            return $opSignal.LogCritical("Azure blob Delete returned HTTP $statusCode for '$blobPath'.")
        }
    }
    catch {
        $opSignal.LogCritical("Exception during Invoke-AzureStorageAccount_DeleteObject: $($_.Exception.Message)", $null, $_)
    }

    return $opSignal
}
