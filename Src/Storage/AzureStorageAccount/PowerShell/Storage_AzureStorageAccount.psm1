using module SignalGraph
$sgModuleName = 'SovereignTrust.Foundation'

if (-not (Get-Module -Name $sgModuleName)) {
    $sgPath = Join-Path $PSScriptRoot "../../../../../SovereignTrust.Foundation/Src/PowerShell/SovereignTrust.Foundation.psd1"
    Import-Module (Resolve-Path $sgPath).ProviderPath -Force
}


. "$PSScriptRoot/Invoke-AzureStorageAccount_ReadObject.ps1"
. "$PSScriptRoot/Invoke-AzureStorageAccount_WriteObject.ps1"
. "$PSScriptRoot/Invoke-AzureStorageAccount_ExistsObject.ps1"
. "$PSScriptRoot/Invoke-AzureStorageAccount_DeleteObject.ps1"
. "$PSScriptRoot/Invoke-AzureStorageAccount_ListObject.ps1"


class Storage_AzureStorageAccount {
    [object]$MappedAdapter
    [Signal]$Signal

    Storage_AzureStorageAccount() {
    }

    Storage_AzureStorageAccount(
        [object]$mappedAdapter
    ) {
        $this.MappedAdapter = $mappedAdapter
    }

    [Signal] Construct(
        [object]$dictionary
    ) {
        $opSignal = [Signal]::Start(
            "Construct-AzureStorageAccount"
        ) | Select-Object -Last 1

        try {
            if ($null -eq $dictionary) {
                return $opSignal.LogCritical(
                    "Cannot construct AzureStorageAccount — provided dictionary is null."
                )
            }

            $this.Signal = [Signal]::Start(
                "Construct-AzureStorageAccount"
            ) | Select-Object -Last 1

            $jacket = [Signal]::Start(
                "Construct-AzureStorageAccount"
            ) | Select-Object -Last 1

            $jacket.SetResult($dictionary)
            $this.Signal.SetJacket($jacket)

            $opSignal.LogInformation(
                "AzureStorageAccount constructed successfully with provided jacket."
            )
        }
        catch {
            $opSignal.LogCritical(
                "Error constructing AzureStorageAccount: $($_.Exception.Message)",
                $null,
                $_
            )
        }

        return $opSignal
    }

    [Signal] Invoke(
        [string]$Slot,
        [string]$Activity,
        [Signal]$ConductionSignal,
        [object]$Plan,
        [Signal]$ItemSignal
    ) {
        $opSignal = [Signal]::Start(
            "AzureStorageAccount.$Slot.$Activity",
            $ItemSignal
        ) | Select-Object -Last 1

        try {
            # ░▒▓█ VERIFY ACTIVE SIGNALS █▓▒░

            if ($null -eq $ConductionSignal) {
                return $opSignal.LogCritical(
                    "Cannot invoke AzureStorageAccount because ConductionSignal is null."
                )
            }

            if ($null -eq $ItemSignal) {
                return $opSignal.LogCritical(
                    "Cannot invoke AzureStorageAccount because ItemSignal is null."
                )
            }

            if ($null -eq $Plan) {
                return $opSignal.LogCritical(
                    "Cannot invoke AzureStorageAccount because Plan is null."
                )
            }

            # ░▒▓█ RESOLVE VIRTUAL PATH █▓▒░

            $virtualPathSignal = Resolve-PathFromDictionary `
                -Dictionary $Plan `
                -Path "Config.VirtualPath" `
                -Default $null `
                -SignalLevel "Information" |
            Select-Object -Last 1
            $virtualPath = $virtualPathSignal.GetResult()
            if ([string]::IsNullOrWhiteSpace([string]$virtualPath)) {
                $virtualPathSignal = Resolve-PathFromDictionary `
                    -Dictionary $Plan `
                    -Path "VirtualPath" `
                    -Default $null `
                    -SignalLevel "Information" |
                Select-Object -Last 1
                $virtualPath = $virtualPathSignal.GetResult()
            }

            if ([string]::IsNullOrWhiteSpace([string]$virtualPath) -and $Activity -ine 'List') {
                return $opSignal.LogCritical(
                    "The resolved storage virtual path is empty."
                )
            }

            # ░▒▓█ RESOLVE AZURE STORAGE ADDRESSES █▓▒░

            $addressSignal = Resolve-PathFromDictionary `
                -Dictionary $this `
                -Path '$.%.@.Addresses' |
            Select-Object -Last 1

            $resourceSignal = Resolve-PathFromDictionary `
                -Dictionary $this `
                -Path '$.%.@.Resource' |
            Select-Object -Last 1

            $signalLevelSignal = Resolve-PathFromDictionary `
                -Dictionary $Plan `
                -Path "Config.SignalLevel" `
                -Default "Critical" |
            Select-Object -Last 1

            if (
                $opSignal.MergeSignalAndVerifyFailure(
                    @(
                        $addressSignal
                        $signalLevelSignal
                    )
                )
            ) {
                return $opSignal.LogCritical(
                    "Could not resolve Azure Storage Account configuration."
                )
            }

            $addresses = @($addressSignal.GetResult())
            $resource = $resourceSignal.GetResult()
            $signalLevel = $signalLevelSignal.GetResult()

            if (
                $addresses.Count -eq 0 -or
                [string]::IsNullOrWhiteSpace(
                    [string]$addresses[0]
                )
            ) {
                return $opSignal.LogCritical(
                    "No Azure Storage Account addresses were configured."
                )
            }

            $callSignal = $null

            switch ($Activity) {
                "List" {
                    $callSignal = Invoke-AzureStorageAccount_ListObject `
                        -ConductionSignal $ConductionSignal `
                        -ItemSignal $ItemSignal `
                        -Plan $Plan `
                        -VirtualPath ([string]$virtualPath) `
                        -Resource $resource `
                        -Addresses $addresses |
                    Select-Object -Last 1
                    break
                }
                "Read" {
                    $callSignal = Invoke-AzureStorageAccount_ReadObject `
                        -ConductionSignal $ConductionSignal `
                        -Signal $this.Signal `
                        -ItemSignal $ItemSignal `
                        -Plan $Plan `
                        -VirtualPath $virtualPath `
                        -Resource $resource `
                        -SignalLevel $signalLevel `
                        -Addresses $addresses |
                    Select-Object -Last 1

                    if ($null -eq $callSignal) {
                        return $opSignal.LogCritical(
                            "Azure Storage Account read did not return a signal."
                        )
                    }

                    # TODO:
                    # Move default-content and SaveIfNew handling into
                    # the common Storage Adapter layer so that all
                    # storage implementations share this behavior.

                    $targetPathProvided = $null -ne $Plan.Config -and $null -ne $Plan.Config.PSObject.Properties['TargetPath']
                    if ($callSignal.Failure() -and -not $targetPathProvided) {
                        $contentSignal = Resolve-PathFromDictionary `
                            -Dictionary $Plan `
                            -Path "Config.Content" `
                            -SignalLevel "Warning" |
                        Select-Object -Last 1

                        if ($contentSignal.HasResult()) {
                            $content = $contentSignal.GetResult()

                            $saveIfNewSignal = Resolve-PathFromDictionary `
                                -Dictionary $Plan `
                                -Path "Config.SaveIfNew" `
                                -Default $false `
                                -SignalLevel "Warning" |
                            Select-Object -Last 1

                            if (
                                [boolean]$saveIfNewSignal.GetResult()
                            ) {
                                $clonePlanSignal = Resolve-ClonePlan `
                                    -Plan $Plan |
                                Select-Object -Last 1

                                if (
                                    $opSignal.MergeSignalAndVerifyFailure(
                                        $clonePlanSignal
                                    )
                                ) {
                                    return $opSignal
                                }

                                $clonePlan = $clonePlanSignal.GetResult()

                                $addContentSignal = Add-PathToDictionary `
                                    -Dictionary $clonePlan `
                                    -Path "Config.Content" `
                                    -Value $content |
                                Select-Object -Last 1

                                if (
                                    $addContentSignal -is [Signal] -and
                                    $opSignal.MergeSignalAndVerifyFailure(
                                        $addContentSignal
                                    )
                                ) {
                                    return $opSignal
                                }

                                $writeResultSignal = $this.Invoke(
                                    $Slot,
                                    "Write",
                                    $ConductionSignal,
                                    $clonePlan,
                                    $ItemSignal
                                )

                                if (
                                    $opSignal.MergeSignalAndVerifyFailure(
                                        $writeResultSignal
                                    )
                                ) {
                                    return $opSignal
                                }
                            }

                            if (
                                $content -is [PSCustomObject] -or
                                $content -is [hashtable]
                            ) {
                                $content = $content |
                                    ConvertTo-Json -Depth 100
                            }
                            elseif ($content -is [object[]]) {
                                if ($content.Count -eq 1) {
                                    $content = ,$content |
                                        ConvertTo-Json -Depth 100
                                }
                                else {
                                    $content = $content |
                                        ConvertTo-Json -Depth 100
                                }
                            }

                            $callSignal.LogRecovery(
                                "Default Content Override"
                            )

                            $callSignal.SetResult($content)
                        }
                    }

                    break
                }

                "Write" {
                    $contentSignal = Resolve-PathFromDictionary `
                        -Dictionary $Plan `
                        -Path "Config.Content" |
                    Select-Object -Last 1

                    if (
                        $opSignal.MergeSignalAndVerifyFailure(
                            $contentSignal
                        )
                    ) {
                        return $opSignal.LogCritical(
                            "Could not resolve Config.Content for Azure Storage Account write."
                        )
                    }

                    $content = $contentSignal.GetResult()

                    $callSignal = Invoke-AzureStorageAccount_WriteObject `
                        -ConductionSignal $ConductionSignal `
                        -Signal $this.Signal `
                        -ItemSignal $ItemSignal `
                        -Plan $Plan `
                        -Content $content `
                        -VirtualPath $virtualPath `
                        -Resource $resource `
                        -Addresses $addresses |
                    Select-Object -Last 1

                    if ($null -eq $callSignal) {
                        return $opSignal.LogCritical(
                            "Azure Storage Account write did not return a signal."
                        )
                    }

                    break
                }

                "Exists" {
                    $callSignal = Invoke-AzureStorageAccount_ExistsObject `
                        -ConductionSignal $ConductionSignal `
                        -Signal $this.Signal `
                        -ItemSignal $ItemSignal `
                        -Plan $Plan `
                        -VirtualPath $virtualPath `
                        -Resource $resource `
                        -Addresses $addresses |
                    Select-Object -Last 1
                    break
                }

                "Delete" {
                    $callSignal = Invoke-AzureStorageAccount_DeleteObject `
                        -ConductionSignal $ConductionSignal `
                        -Signal $this.Signal `
                        -ItemSignal $ItemSignal `
                        -Plan $Plan `
                        -VirtualPath $virtualPath `
                        -Resource $resource `
                        -Addresses $addresses |
                    Select-Object -Last 1
                    break
                }

                default {
                    return $opSignal.LogCritical(
                        "Unsupported Azure Storage Account activity '$Activity'."
                    )
                }
            }

            if (
                $opSignal.MergeSignalAndVerifySuccess(
                    $callSignal
                )
            ) {
                if ($callSignal.HasResult()) {
                    $opSignal.SetResult(
                        $callSignal.GetResult($true)
                    )
                }

                $opSignal.LogInformation(
                    "Successfully completed Azure Storage Account activity '$Activity' for virtual path: $virtualPath"
                )
            }
        }
        catch {
            $opSignal.LogCritical(
                "Exception in AzureStorageAccount.$Activity': $($_.Exception.Message)",
                $null,
                $_
            )
        }

        return $opSignal
    }
}

function Resolve-Storage_AzureStorageAccount {
    $object = [Storage_AzureStorageAccount]::new()
    return $object
}

Export-ModuleMember `
    -Function Resolve-Storage_AzureStorageAccount
