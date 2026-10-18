function Invoke-AzureStorageAccount_ReadObject {
    param (
        [Parameter(Mandatory)][Signal]$ConductionSignal,
        [Signal]$Signal,
        [Parameter(Mandatory)][Signal]$ItemSignal,
        [Parameter(Mandatory)][object]$Plan,
        [Parameter(Mandatory)][string]$VirtualPath,
        [Parameter(Mandatory)][object]$Resource,
        [Parameter()][string]$PathSuffix,
        [string]$SignalLevel = "Critical",
        [Parameter()][object]$Addresses
    )

    $opSignal = [Signal]::Start(
        "Invoke-AzureStorageAccount_ReadObject:$VirtualPath",
        $ItemSignal
    ) | Select-Object -Last 1

    try {
        $targetPathProvided = $null -ne $Plan.Config -and $null -ne $Plan.Config.PSObject.Properties['TargetPath']
        if ($targetPathProvided) {
            $targetPath = [string]$Plan.Config.TargetPath
            if ([string]::IsNullOrWhiteSpace($targetPath) -or -not [System.IO.Path]::IsPathFullyQualified($targetPath) -or $targetPath -match '^[^:]+::') {
                return $opSignal.LogCritical('Config.TargetPath must be a nonempty absolute filesystem path.')
            }
            if ([bool]$Plan.Config.ReturnHttpStatus) {
                return $opSignal.LogCritical('Config.TargetPath cannot be combined with ReturnHttpStatus.')
            }
        }
        # ░▒▓█ NORMALIZE FILE EXTENSION █▓▒░
        if (
            $PathSuffix -and
            -not $VirtualPath.EndsWith(
                $PathSuffix,
                [System.StringComparison]::OrdinalIgnoreCase
            )
        ) {
            $VirtualPath = "$VirtualPath$PathSuffix"
        }

        # Azure blob paths always use forward slashes.
        $blobPath = $VirtualPath.Replace('\', '/').TrimStart('/')

        if ([string]::IsNullOrWhiteSpace($blobPath)) {
            return $opSignal.LogCritical(
                "Cannot read Azure blob because VirtualPath is empty."
            )
        }

        foreach ($address in @($Addresses)) {
            if ([string]::IsNullOrWhiteSpace([string]$address)) {
                continue
            }

            $hostAddress = ([string]$address).TrimEnd('/')
            $blobUri = "$hostAddress/$resource/$blobPath"

            $restPlan = [pscustomobject]@{
                Config = [pscustomobject]@{
                    Uri              = $blobUri
                    Host             = "https://storage.azure.com/"
                    Method           = "Get"
                    Headers          = @{
                        "x-ms-version" = "2023-11-03"
                    }
                    CacheAccessToken = $true
                    TargetPath       = if ($targetPathProvided) { $targetPath } else { $null }
                }
            }
            if (-not $targetPathProvided) {
                $restPlan.Config.PSObject.Properties.Remove('TargetPath')
            }

            $responseSignal = Invoke-MappedAdapter `
                -Adapter "Condenser.Rest" `
                -Activity "Get" `
                -Signal $ConductionSignal `
                -Plan $restPlan `
                -ItemSignal $ItemSignal |
            Select-Object -Last 1

            if ($responseSignal.Success()) {
                $opSignal.MergeSignal($responseSignal)

                if ($responseSignal.HasResult()) {
                    $content = $responseSignal.GetResult($true)
                    if ($content -is [pscustomobject]) {
                        $content = $content | ConvertTo-Json -Depth 100
                    }

                    $opSignal.SetResult($content)
                    $opSignal.LogInformation(
                        "📄 Found and read Azure blob: '$blobPath'"
                    )

                    return $opSignal
                }
            }

            # A failed request may simply mean that this address does
            # not contain the requested blob. Check the next address.
            if (-not $targetPathProvided) {
                $opSignal.MergeSignal($responseSignal)
            }
        }

        if ($targetPathProvided) {
            return $opSignal.LogCritical("Blob '$blobPath' could not be downloaded to Config.TargetPath from any Azure Storage address.")
        }
        $opSignal.LogMessage(
            $SignalLevel,
            "Blob '$blobPath' not found in any Azure Storage address."
        )
    }
    catch {
        $opSignal.LogCritical(
            "🔥 Exception during Invoke-AzureStorageAccount_ReadObject: $($_.Exception.Message)",
            $null,
            $_
        )
    }

    return $opSignal
}
