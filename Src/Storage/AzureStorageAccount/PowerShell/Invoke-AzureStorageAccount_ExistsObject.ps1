function Invoke-AzureStorageAccount_ExistsObject {
    param (
        [Parameter(Mandatory)][Signal]$ConductionSignal,
        [Parameter(Mandatory)][Signal]$Signal,
        [Parameter(Mandatory)][Signal]$ItemSignal,
        [Parameter(Mandatory)][object]$Plan,
        [Parameter(Mandatory)][string]$VirtualPath,
        [Parameter(Mandatory)][object]$Resource,
        [Parameter(Mandatory)][object]$Addresses
    )

    $opSignal = [Signal]::Start("Invoke-AzureStorageAccount_ExistsObject:$VirtualPath", $ItemSignal) | Select-Object -Last 1

    try {
        $pathSuffixSignal = Resolve-PathFromDictionary -Dictionary $Plan -Path "Config.PathSuffix" -SignalLevel "Warning" | Select-Object -Last 1
        $pathSuffix = if ($pathSuffixSignal.HasResult()) { [string]$pathSuffixSignal.GetResult() } else { $null }
        if ($pathSuffix -and -not $VirtualPath.EndsWith($pathSuffix, [System.StringComparison]::OrdinalIgnoreCase)) {
            $VirtualPath = "$VirtualPath$pathSuffix"
        }

        $blobPath = $VirtualPath.Replace('\', '/').TrimStart('/')
        $container = ([string]$Resource).Trim('/')
        if ([string]::IsNullOrWhiteSpace($blobPath) -or [string]::IsNullOrWhiteSpace($container)) {
            return $opSignal.LogCritical("Azure blob Exists requires a path and Resource container.")
        }
        $encodedBlobPath = ($blobPath.Split('/') | ForEach-Object { [uri]::EscapeDataString($_) }) -join '/'

        $hasAddress = $false
        foreach ($address in @($Addresses)) {
            if ([string]::IsNullOrWhiteSpace([string]$address)) { continue }
            $hasAddress = $true
            $hostAddress = ([string]$address).TrimEnd('/')
            $blobUri = "$hostAddress/$container/$encodedBlobPath"

            $restPlan = [pscustomobject]@{
                Config = [pscustomobject]@{
                    Uri = $blobUri
                    Host = "https://storage.azure.com/"
                    Method = "Head"
                    Headers = @{ "x-ms-version" = "2023-11-03" }
                    CacheAccessToken = $true
                    ReturnHttpStatus = $true
                }
            }

            $responseSignal = Invoke-MappedAdapter -Adapter "Condenser.Rest" -Activity "Head" -Signal $ConductionSignal -Plan $restPlan -ItemSignal $ItemSignal | Select-Object -Last 1
            if ($null -eq $responseSignal) { return $opSignal.LogCritical("Azure REST adapter returned no signal for Exists.") }
            if ($responseSignal.Failure() -or -not $responseSignal.HasResult()) {
                $opSignal.MergeSignal($responseSignal)
                return $opSignal.LogCritical("Azure blob Exists request failed for '$blobPath'.")
            }

            $response = $responseSignal.GetResult($true)
            $statusCode = [int]$response.StatusCode
            if ($statusCode -eq 200) {
                $opSignal.SetResult($true)
                return $opSignal
            }
            if ($statusCode -eq 404 -and $response.Headers['x-ms-error-code'] -eq 'BlobNotFound') {
                continue
            }
            else {
                return $opSignal.LogCritical("Azure blob Exists returned HTTP $statusCode for '$blobPath'.")
            }
        }

        if (-not $hasAddress) { return $opSignal.LogCritical("No Azure Storage Account addresses were configured.") }
        $opSignal.SetResult($false)
    }
    catch {
        $opSignal.LogCritical("Exception during Invoke-AzureStorageAccount_ExistsObject: $($_.Exception.Message)", $null, $_)
    }

    return $opSignal
}
