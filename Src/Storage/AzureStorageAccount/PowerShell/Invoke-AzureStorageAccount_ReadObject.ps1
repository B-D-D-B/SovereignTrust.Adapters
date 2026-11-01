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
        $config = $Plan.Config
        $targetPathProvided = $null -ne $config -and $(if ($config -is [System.Collections.IDictionary]) { $config.Contains('TargetPath') } else { $null -ne $config.PSObject.Properties['TargetPath'] })
        $hasDetail = $null -ne $config -and $(if ($config -is [System.Collections.IDictionary]) { $config.Contains('ResultDetail') } else { $null -ne $config.PSObject.Properties['ResultDetail'] })
        $resultDetail = $false
        if ($hasDetail) {
            $detailValue = if ($config -is [System.Collections.IDictionary]) { $config['ResultDetail'] } else { $config.ResultDetail }
            if ($detailValue -isnot [bool]) { return $opSignal.LogCritical('Config.ResultDetail must be a native Boolean.') }
            $resultDetail = $detailValue
        }
        if ($resultDetail -and -not $targetPathProvided) { return $opSignal.LogCritical('Config.ResultDetail requires Config.TargetPath for Read.') }
        if ($targetPathProvided) {
            $targetPath = [string]$Plan.Config.TargetPath
            if ([string]::IsNullOrWhiteSpace($targetPath) -or -not [System.IO.Path]::IsPathFullyQualified($targetPath) -or $targetPath -match '^[^:]+::') {
                return $opSignal.LogCritical('Config.TargetPath must be a nonempty absolute filesystem path.')
            }
            if ([bool]$Plan.Config.ReturnHttpStatus) {
                return $opSignal.LogCritical('Config.TargetPath cannot be combined with ReturnHttpStatus.')
            }
            $targetPath = [System.IO.Path]::GetFullPath($targetPath)
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

                    if ($resultDetail) {
                        if (-not [string]::Equals([string]$content, $targetPath, [System.StringComparison]::OrdinalIgnoreCase)) {
                            throw 'REST read returned a different Config.TargetPath.'
                        }
                        $stream = [System.IO.File]::Open($targetPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
                        $detailReceipt = $null
                        try {
                            $before = [System.IO.FileInfo]::new($targetPath)
                            $beforeLength = [long]$before.Length
                            $beforeWrite = $before.LastWriteTimeUtc
                            $beforeCreated = $before.CreationTimeUtc
                            $length = [long]$stream.Length
                            $digest = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($stream))
                            $after = [System.IO.FileInfo]::new($targetPath)
                            if ($beforeLength -ne $length -or $after.Length -ne $length -or
                                $beforeWrite -ne $after.LastWriteTimeUtc -or
                                $beforeCreated -ne $after.CreationTimeUtc) {
                                throw 'Config.TargetPath changed while computing result detail.'
                            }
                            $detailReceipt = [pscustomobject]@{
                                TargetPath = $targetPath
                                ByteLength = $length
                                Sha256 = $digest
                            }
                        }
                        finally { $stream.Dispose() }
                        $opSignal.SetResult($detailReceipt)
                    }
                    else { $opSignal.SetResult($content) }
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
