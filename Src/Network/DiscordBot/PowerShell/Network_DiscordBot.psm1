using module SignalGraph
$stModuleName = 'SovereignTrust.Foundation'
if (-not (Get-Module -Name $stModuleName)) {
    $stPath = Join-Path $PSScriptRoot "../../../../../SovereignTrust.Foundation/Src/PowerShell/SovereignTrust.Foundation.psd1"
    Import-Module (Resolve-Path $stPath).ProviderPath -Force
}

# ---- Load Network functions (your existing REST surface) ----
# Use your existing implementations here
# . "$PSScriptRoot/Read-StorageNetworkApi.ps1"
# Optional if you have them:
# . "$PSScriptRoot/Delete-StorageNetworkMessageApi.ps1"
# . "$PSScriptRoot/Update-StorageNetworkVisibilityApi.ps1"
# . "$PSScriptRoot/Write-StorageNetworkApi.ps1"

class Network_DiscordBot {
    [object]$MappedAdapter
    [Signal]$Signal

    Network_DiscordBot() { }

    Network_DiscordBot([object]$mappedAdapter) {
        $this.MappedAdapter = $mappedAdapter
    }


    [Signal] Construct([object]$dictionary) {
        $opSignal = [Signal]::Start("Network_DiscordBot.Construct") | Select-Object -Last 1

        try {
            if ($null -eq $dictionary) {
                $opSignal.LogCritical("Cannot construct Network_DiscordBot — provided dictionary is null.")
                return $opSignal
            }

            $this.Signal = [Signal]::Start("Network_DiscordBot") | Select-Object -Last 1

            $jacket = [Signal]::Start("Network_DiscordBot.Jacket") | Select-Object -Last 1
            $jacket.SetResult($dictionary)

            $this.Signal.SetJacket($jacket)
            $opSignal.LogInformation("Network_DiscordBot constructed successfully with provided jacket.")
        }
        catch {
            $opSignal.LogCritical("Error constructing Network_DiscordBot: $_")
        }

        return $opSignal
    }

    [string[]] SplitContent([string]$Content, [int]$MaxLength) {
        if ([string]::IsNullOrEmpty($Content)) {
            return @("")
        }

        if ($MaxLength -le 0) {
            throw "MaxLength must be greater than 0."
        }

        $chunks = New-Object System.Collections.Generic.List[string]
        $index = 0

        while ($index -lt $Content.Length) {
            $remaining = $Content.Length - $index
            $length = [Math]::Min($MaxLength, $remaining)

            $chunk = $Content.Substring($index, $length)
            $chunks.Add($chunk)

            $index += $length
        }

        return $chunks.ToArray()
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
        $opSignal = [Signal]::Start("Network_DiscordBot.Invoke:$Slot.$Activity", $ConductionSignal) | Select-Object -Last 1

        try {
            if (-not $ConductionSignal) {
                $opSignal.LogCritical("Null ConductionSignal passed to Network_DiscordBot.Invoke()")
                return $opSignal
            }

            if (-not $Activity) {
                $opSignal.LogWarning("No Activity provided to Network_DiscordBot.Invoke()")
                return $opSignal
            }

            # Resolve Config from Plan (or from Environment if you prefer)
            # Convention: Plan contains everything needed to hit the service for this step
            $configSignal = Resolve-PathFromDictionary -Dictionary $Plan -Path "Config" -SignalLevel "Warning" | Select-Object -Last 1
            $config = $configSignal.HasResult() ? $configSignal.GetResult() : $null

            if (-not $config) {
                # Optional fallback: pull config from Environment/Jacket
                # $env = $ConductionSignal.GetJacket().GetResult()
                # $configSignal = Resolve-PathFromDictionary -Dictionary $env -Path "Network.StorageNetwork.Config" -SignalLevel "Warning" | Select-Object -Last 1
                $opSignal.LogWarning("StorageNetwork Config not found on Plan.Config (no fallback enabled).")
            }

            $discordTokenSignal = Resolve-PathFromDictionary -Dictionary $this.Signal -Path "%.@.Resource" | Select-Object -Last 1
            $uriSignal = Resolve-PathFromDictionary -Dictionary $this.Signal -Path "%.@.Addresses" | Select-Object -Last 1
            $headers = @{
            }

            $headers["Authorization"] = "Bot $($discordTokenSignal.GetResult())"
            $headers["User-Agent"] = "DiscordBot (https://sda.studio, 1.0) PowerShell/7"

            switch ($Activity) {
                "SendFile" {
                    $sourceContentSignal = Resolve-PathFromDictionary -Dictionary $Plan -Path "Config.Content" | Select-Object -Last 1
                    $sourceBinarySignal = Resolve-PathFromDictionary -Dictionary $Plan -Path "Config.FullPath" | Select-Object -Last 1
                    $channelIdSignal = Resolve-PathFromDictionary -Dictionary $ItemSignal -Path "@.Id" | Select-Object -Last 1

                    $uri = "$($uriSignal.GetResult())/channels/$($channelIdSignal.GetResult())/messages"

                    $contentText = [string]$sourceContentSignal.GetResult()
$content = @{
Content = $contentText

}
                    $attachmentFilePath = $sourceBinarySignal.GetResult()

                    $responseResults = @()

                    $RestPlan = [PSCustomObject]@{
                        Config = [PSCustomObject]@{
                            Method          = "Post"
                            Headers         = $headers
                            SkipBearerToken = $true
                            Uri             = $uri
                            AttachmentPath  = $attachmentFilePath
                            Form            = @{
                                payload_json = ($content | ConvertTo-Json -Depth 10) 
                                "files[0]"   = $attachmentFilePath
                            }
#                            payload_json = ($contentText | ConvertTo-Json -Depth 10)
#                            "files[0]"   = $attachmentFilePath
                        }
                    }

                    # Call Rest Endpoint
                    $responseSignal = Invoke-MappedAdapter `
                        -Adapter "Condenser.Rest" `
                        -Activity "Post" `
                        -Signal $ConductionSignal `
                        -Plan $RestPlan `
                        -ItemSignal $ItemSignal |
                    Select-Object -Last 1

                    if ($opSignal.MergeSignalAndVerifyFailure($responseSignal)) {
                        return $opSignal
                    }

                    $responseResults += $responseSignal.GetResult()

                    $opSignal.SetResult($responseResults)
                    break
                }

                "SendMessage" {
                    # The App Insights Network Adapter prepares a custom plan to pass to its body. 
                    $sourceContentSignal = Resolve-PathFromDictionary -Dictionary $Plan -Path "Config.Content" | Select-Object -Last 1
                    $channelIdSignal = Resolve-PathFromDictionary -Dictionary $ItemSignal -Path "@.Id" | Select-Object -Last 1

                    $uri = "$($uriSignal.GetResult())/channels/$($channelIdSignal.GetResult())/messages"

                    $contentText = [string]$sourceContentSignal.GetResult()
                    $contentChunks = $this.SplitContent($contentText, 2000)

                    $responseResults = @()

                    foreach ($contentChunk in $contentChunks) {

                        $content = @{
                            content = $contentChunk
                        }

                        $RestPlan = [PSCustomObject]@{
                            Config = [PSCustomObject]@{
                                Body            = ($content | ConvertTo-Json -Depth 10)
                                Method          = "Post"
                                Headers         = $headers
                                SkipBearerToken = $true
                                Uri             = $uri
                            }
                        }

                        # Call Rest Endpoint
                        $responseSignal = Invoke-MappedAdapter `
                            -Adapter "Condenser.Rest" `
                            -Activity "Post" `
                            -Signal $ConductionSignal `
                            -Plan $RestPlan `
                            -ItemSignal $ItemSignal |
                        Select-Object -Last 1

                        if ($opSignal.MergeSignalAndVerifyFailure($responseSignal)) {
                            return $opSignal
                        }

                        $responseResults += $responseSignal.GetResult()
                    }

                    $opSignal.SetResult($responseResults)
                    break
                }

                "ReadBatch" {
                    $PollUntilResponseSignal = Resolve-PathFromDictionary -Dictionary $Plan -Path "Config.PollUntilResponse" -Default $false | Select-Object -Last 1
                    $PollingDelayMSSignal = Resolve-PathFromDictionary -Dictionary $Plan -Path "Config.PollingDelayMS" -Default 5000 | Select-Object -Last 1
                    $MessageLimitSignal = Resolve-PathFromDictionary -Dictionary $Plan -Path "Config.MessageLimit" -Default 10 | Select-Object -Last 1
                    $MessageReplyPathSignal = Resolve-PathFromDictionary -Dictionary $Plan -Path "Path" -SignalLevel "Information" | Select-Object -Last 1

                    $PollUntilResponse = $PollUntilResponseSignal.GetResult()
                    $channelIdSignal = Resolve-PathFromDictionary -Dictionary $ItemSignal -Path "@.Id" | Select-Object -Last 1
                    $uri = "$($uriSignal.GetResult())/channels/$($channelIdSignal.GetResult())/messages?limit=$($MessageLimitSignal.GetResult())"
                    $continue = $true

                    while ($continue) {
                        $RestPlan = [PSCustomObject]@{
                            Config = [PSCustomObject]@{
                                Method          = "Get"
                                Headers         = $headers
                                SkipBearerToken = $true
                                Uri             = $uri
                            }
                        }

                        # Call Rest Endpoint
                        $responseSignal = Invoke-MappedAdapter -Adapter "Condenser.Rest" -Activity "Post" -Signal $ConductionSignal -Plan $RestPlan -ItemSignal $ItemSignal
                        if ($opSignal.MergeSignalAndVerifyFailure($responseSignal)) { return $opSignal }

                        $continue = $PollUntilResponse
                        # Get the Message Id from the previous step when there's a id to lookup from a previous message.
                        if ($MessageReplyPathSignal.HasResult()) {
                            $messageIdsSignal = Resolve-PathFromDictionary -Dictionary $ItemSignal -Path $MessageReplyPathSignal.GetResult()  -SignalLevel "Information" | Select-Object -Last 1
                            #if ($messageIdSignal.HasResult()) {
                                $messagesIdsList = $messageIdsSignal.HasResult() ? $messageIdsSignal.GetResult() : $null
                                $messageIds = @()
                                foreach ($messagesIdsMsg in $messagesIdsList)
                                {
                                    $messageIds += $messagesIdsMsg.id
                                }

                                $messageList = $responseSignal.GetResult()
                                foreach ($message in $messageList) {
                                    $replyMessageIdSignal = Resolve-PathFromDictionary -Dictionary $message -Path "message_reference.message_id" -SignalLevel "Information" | Select-Object -Last 1
                                    if ($replyMessageIdSignal.HasResult()) {
                                        if ($messageIds -contains ($replyMessageIdSignal.GetResult())) {
                                            # Set opSignal Result to Message for processing.
                                            #$opSignal.SetResult(($message | ConvertTo-Json -Depth 10))
                                            $continue = $false
                                            $opSignal.SetResult($message)
                                            return $opSignal
                                        }
                                    }
                                }
                            #}
                        }

                        if ($continue) {
                            Start-Sleep -Milliseconds $PollingDelayMSSignal.GetResult()
                        }

                        $opSignal.SetResult($responseSignal.GetResult())
                    }

                    break
                }

                "HandleMessage" {
                    # TODO: Review, this is being done in this class, but it's generic enough it should be somewhere else.
                    #                    $MessageSignal = Resolve-PathFromDictionary -Dictionary $Plan -Path "Config.Message" | Select-Object -Last 1
                    $MessageSignal = Resolve-PathFromDictionary -Dictionary $ItemSignal -Path $Plan.Path | Select-Object -Last 1
                    
                    if ($MessageSignal.HasResult()) {
                        $opSignal.SetResult($MessageSignal.GetResult())
                    }
                    break   
                }


                default {
                    $opSignal.LogWarning("Unsupported Activity: $Activity")
                    $resultSignal = [Signal]::Start("StorageNetwork.UnsupportedActivity", $ItemSignal) | Select-Object -Last 1
                    break
                }
            }
        }
        catch {
            $opSignal.LogCritical("🔥 Exception in Network_DiscordBot.Invoke: $($_.Exception.Message)", $null, $_)
        }

        return $opSignal
    }
}

function Resolve-Network_DiscordBot {
    $object = [Network_DiscordBot]::new()
    return $object
}

Export-ModuleMember -Function Resolve-Network_DiscordBot
