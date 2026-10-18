function Invoke-AzureStorageAccount_WriteObject {
    param (
        [Parameter(Mandatory)]
        [Signal]$ConductionSignal,

        [Parameter(Mandatory)]
        [Signal]$Signal,

        [Parameter(Mandatory)]
        [Signal]$ItemSignal,

        [Parameter(Mandatory)]
        [object]$Plan,

        [Parameter()]
        [AllowNull()]
        [object]$Content,

        [Parameter(Mandatory)]
        [string]$VirtualPath,

        [Parameter(Mandatory)]
        [object]$Addresses,

        [Parameter(Mandatory)]
        [object]$Resource
    )

    $opSignal = [Signal]::Start(
        "Invoke-AzureStorageAccount_WriteObject:$VirtualPath",
        $ItemSignal
    ) | Select-Object -Last 1

    try {
        # ░▒▓█ RESOLVE OPTIONAL WRITE CONFIGURATION █▓▒░

        $pathSuffixSignal = Resolve-PathFromDictionary `
            -Dictionary $Plan `
            -Path "Config.PathSuffix" `
            -SignalLevel "Warning" |
        Select-Object -Last 1

        $contentTypeSignal = Resolve-PathFromDictionary `
            -Dictionary $Plan `
            -Path "Config.ContentType" `
            -SignalLevel "Warning" |
        Select-Object -Last 1

        $sourcePathSignal = Resolve-PathFromDictionary `
            -Dictionary $Plan `
            -Path "Config.SourcePath" `
            -SignalLevel "Warning" |
        Select-Object -Last 1

        # Temporary compatibility with the misspelled property name.
        if (-not $sourcePathSignal.HasResult()) {
            $sourcePathSignal = Resolve-PathFromDictionary `
                -Dictionary $Plan `
                -Path "Config.SourthPath" `
                -SignalLevel "Warning" |
            Select-Object -Last 1
        }

        $pathSuffix = if ($pathSuffixSignal.HasResult()) {
            [string]$pathSuffixSignal.GetResult()
        }
        else {
            $null
        }

        $contentType = if ($contentTypeSignal.HasResult()) {
            [string]$contentTypeSignal.GetResult()
        }
        else {
            $null
        }

        $sourcePath = if ($sourcePathSignal.HasResult()) {
            [string]$sourcePathSignal.GetResult()
        }
        else {
            $null
        }

        # ░▒▓█ NORMALIZE FILE EXTENSION █▓▒░

        if (
            -not [string]::IsNullOrWhiteSpace($pathSuffix) -and
            -not $VirtualPath.EndsWith(
                $pathSuffix,
                [System.StringComparison]::OrdinalIgnoreCase
            )
        ) {
            $VirtualPath = "$VirtualPath$pathSuffix"
        }

        # Azure blob paths always use forward slashes.
        $blobPath = $VirtualPath.Replace('\', '/').TrimStart('/')

        if ([string]::IsNullOrWhiteSpace($blobPath)) {
            return $opSignal.LogCritical(
                "Cannot write Azure blob because VirtualPath is empty."
            )
        }

        # ░▒▓█ RESOLVE REQUEST BODY █▓▒░

        $requestBody = $null
        $requestContentType = $contentType
        $uploadSource = $null

        if ($null -ne $Content) {
            if ($Content -is [byte[]]) {
                # Preserve supplied binary content exactly.
                $requestBody = $Content

                if (
                    [string]::IsNullOrWhiteSpace(
                        $requestContentType
                    )
                ) {
                    $requestContentType = "application/octet-stream"
                }
            }
            elseif (
                $Content -is [pscustomobject] -or
                $Content -is [hashtable] -or
                $Content -is [ordered] -or
                $Content -is [System.Collections.IDictionary] -or
                $Content -is [object[]]
            ) {
                $requestBody = ConvertTo-Json `
                    -InputObject $Content `
                    -Depth 100

                if ($Content -is [object[]])
                {
                    if ($Content.Count -eq 1) {
                        $Content = , $Content | ConvertTo-Json -Depth 100
                    }
                }

                if (
                    [string]::IsNullOrWhiteSpace(
                        $requestContentType
                    )
                ) {
                    $requestContentType = "application/json; charset=utf-8"
                }
            }
            else {
                $requestBody = [string]$Content

                if (
                    [string]::IsNullOrWhiteSpace(
                        $requestContentType
                    )
                ) {
                    $requestContentType = "text/plain; charset=utf-8"
                }
            }

            $uploadSource = "provided content"
        }
        elseif (
            -not [string]::IsNullOrWhiteSpace($sourcePath)
        ) {
            # Resolve-Path throws when the source does not exist.
            $resolvedSourcePath = (
                Resolve-Path `
                    -LiteralPath $sourcePath `
                    -ErrorAction Stop
            ).ProviderPath

            if (
                -not [System.IO.File]::Exists(
                    $resolvedSourcePath
                )
            ) {
                return $opSignal.LogCritical(
                    "Source file does not exist: '$resolvedSourcePath'."
                )
            }
            <#
            # Always read SourcePath as raw bytes. This supports images,
            # videos, archives, PDFs, and other binary formats.
            $requestBody = [System.IO.File]::ReadAllBytes(
                $resolvedSourcePath
            )
#>
            if (
                [string]::IsNullOrWhiteSpace(
                    $requestContentType
                )
            ) {
                $requestContentType = "application/octet-stream"
            }

            $uploadSource = $resolvedSourcePath
        }
        else {
            return $opSignal.LogCritical(
                "Azure blob write requires either Config.Content or Config.SourcePath."
            )
        }
        <#
        if ($null -eq $requestBody) {
            return $opSignal.LogCritical(
                "The Azure blob request body could not be resolved."
            )
        }
#>
        # ░▒▓█ WRITE TO FIRST SUCCESSFUL ADDRESS █▓▒░

        foreach ($address in @($Addresses)) {
            if (
                [string]::IsNullOrWhiteSpace(
                    [string]$address
                )
            ) {
                continue
            }

            $hostAddress = ([string]$address).TrimEnd('/')
            $blobUri = "$hostAddress/$resource/$blobPath"

            $headers = @{
                "x-ms-blob-type" = "BlockBlob"
                "x-ms-version"   = "2023-11-03"
                "Content-Type"   = $requestContentType
            }

            # Clone the incoming plan so existing REST adapter
            # configuration and pipeline context are preserved.
            $restPlanSignal = Resolve-ClonePlan `
                -Plan $Plan |
            Select-Object -Last 1

            if (
                $opSignal.MergeSignalAndVerifyFailure(
                    $restPlanSignal
                )
            ) {
                return $opSignal
            }

            $restPlan = $restPlanSignal.GetResult()

            if (
                -not [string]::IsNullOrWhiteSpace($sourcePath)
            ) {
                $null = Add-PathToDictionary `
                    -Dictionary $restPlan `
                    -Path "Config.SourcePath" `
                    -Value $uploadSource
            }

            $null = Add-PathToDictionary `
                -Dictionary $restPlan `
                -Path "Config.Host" `
                -Value $hostAddress

            $null = Add-PathToDictionary `
                -Dictionary $restPlan `
                -Path "Config.Uri" `
                -Value $blobUri

            $null = Add-PathToDictionary `
                -Dictionary $restPlan `
                -Path "Config.Method" `
                -Value "Put"

            if (-not [string]::IsNullOrWhiteSpace($requestBody)) {
                $null = Add-PathToDictionary `
                    -Dictionary $restPlan `
                    -Path "Config.Body" `
                    -Value $requestBody
            }

            $null = Add-PathToDictionary `
                -Dictionary $restPlan `
                -Path "Config.Headers" `
                -Value $headers

            $null = Add-PathToDictionary `
                -Dictionary $restPlan `
                -Path "Config.ContentType" `
                -Value $requestContentType

            $null = Add-PathToDictionary `
                -Dictionary $restPlan `
                -Path "Config.CacheAccessToken" `
                -Value $true

            $responseSignal = Invoke-MappedAdapter `
                -Adapter "Condenser.Rest" `
                -Activity "Put" `
                -Signal $ConductionSignal `
                -Plan $restPlan `
                -ItemSignal $ItemSignal |
            Select-Object -Last 1

            if ($null -eq $responseSignal) {
                $opSignal.LogWarning(
                    "Azure REST adapter returned no signal for address '$hostAddress'."
                )

                continue
            }

            if ($responseSignal.Success()) {
                $opSignal.MergeSignal($responseSignal)

                # Avoid returning or logging a SAS query string.
                $safeBlobUri = $blobUri.Split('?')[0]

                $opSignal.SetResult($safeBlobUri)
                $opSignal.LogInformation(
                    "📝 Wrote Azure blob from '$uploadSource': '$blobPath' -> '$safeBlobUri'"
                )

                return $opSignal
            }

            $opSignal.MergeSignal($responseSignal)
        }

        $opSignal.LogCritical(
            "Could not write Azure blob '$blobPath' to any configured address."
        )
    }
    catch {
        $opSignal.LogCritical(
            "🔥 Exception during Invoke-AzureStorageAccount_WriteObject: $($_.Exception.Message)",
            $null,
            $_
        )
    }

    return $opSignal
}