using module SignalGraph
<#
Path filters accept PowerShell-style parameters or key/value pairs, with or
without parentheses or brackets. Quotes are only required for values containing
spaces or separators.

Examples:
    EnrollMe -Name Plan -Type Json
    EnrollMe Name=Plan, Type=Json
    EnrollMe -Name "ABC Project" -Type Json
    EnrollMe(-Name "ABC Project" -Type Json)
    EnrollMe[Name="ABC Project", Type=Json]
#>

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

class Queue_AzureStorageQueue {
    [MappedQueueAdapter]$MappedAdapter
    [Signal]$Signal

    Queue_AzureStorageQueue() { }

    Queue_AzureStorageQueue([MappedQueueAdapter]$mappedAdapter) {
        $this.MappedAdapter = $mappedAdapter
    }

    [Signal] Construct([object]$dictionary) {
        $opSignal = [Signal]::Start("Queue_AzureStorageQueue.Construct") | Select-Object -Last 1

        try {
            if ($null -eq $dictionary) {
                $opSignal.LogCritical("Cannot construct Queue_AzureStorageQueue — provided dictionary is null.")
                return $opSignal
            }

            $this.Signal = [Signal]::Start("Queue_AzureStorageQueue") | Select-Object -Last 1

            $jacket = [Signal]::Start("Queue_AzureStorageQueue.Jacket") | Select-Object -Last 1
            $jacket.SetResult($dictionary)

            $this.Signal.SetJacket($jacket)
            $opSignal.LogInformation("Queue_AzureStorageQueue constructed successfully with provided jacket.")
        }
        catch {
            $opSignal.LogCritical("Error constructing Queue_AzureStorageQueue: $_")
        }

        return $opSignal
    }


    [object] ConvertKvpBlockToObject([string]$KvpBlock) {
        $values = [ordered]@{}
        $position = 0

        while ($position -lt $KvpBlock.Length) {
            # Parameter pairs may be separated by whitespace, commas, or both.
            while (
                $position -lt $KvpBlock.Length -and
                ([char]::IsWhiteSpace($KvpBlock[$position]) -or $KvpBlock[$position] -eq ',')
            ) {
                $position++
            }

            if ($position -ge $KvpBlock.Length) {
                break
            }

            $dashSyntax = $KvpBlock[$position] -eq '-'
            if ($dashSyntax) {
                $position++
            }

            $keyStart = $position
            while (
                $position -lt $KvpBlock.Length -and
                "$($KvpBlock[$position])" -match '[A-Za-z0-9_.-]'
            ) {
                $position++
            }

            if ($position -eq $keyStart) {
                throw "Invalid filter parameter near '$($KvpBlock.Substring($position))'."
            }

            $key = $KvpBlock.Substring($keyStart, $position - $keyStart)
            $hadWhitespace = $false

            while ($position -lt $KvpBlock.Length -and [char]::IsWhiteSpace($KvpBlock[$position])) {
                $hadWhitespace = $true
                $position++
            }

            if ($position -lt $KvpBlock.Length -and $KvpBlock[$position] -eq '=') {
                $position++
            }
            elseif (-not $dashSyntax -or -not $hadWhitespace) {
                throw "Filter parameter '$key' must use '$key=value' or '-$key value' syntax."
            }

            while ($position -lt $KvpBlock.Length -and [char]::IsWhiteSpace($KvpBlock[$position])) {
                $position++
            }

            if ($position -ge $KvpBlock.Length) {
                throw "Filter parameter '$key' does not have a value."
            }

            $value = $null
            if ($KvpBlock[$position] -eq '"' -or $KvpBlock[$position] -eq "'") {
                $quote = $KvpBlock[$position]
                $position++
                $builder = [System.Text.StringBuilder]::new()
                $closedQuote = $false

                while ($position -lt $KvpBlock.Length) {
                    $character = $KvpBlock[$position]

                    if ($character -eq $quote) {
                        if (
                            $position + 1 -lt $KvpBlock.Length -and
                            $KvpBlock[$position + 1] -eq $quote
                        ) {
                            $null = $builder.Append($quote)
                            $position += 2
                            continue
                        }

                        $closedQuote = $true
                        $position++
                        break
                    }

                    $null = $builder.Append($character)
                    $position++
                }

                if (-not $closedQuote) {
                    throw "Filter parameter '$key' has an unterminated quoted value."
                }

                $value = $builder.ToString()
            }
            else {
                $valueStart = $position

                while ($position -lt $KvpBlock.Length) {
                    if ($KvpBlock[$position] -eq ',') {
                        break
                    }

                    if ([char]::IsWhiteSpace($KvpBlock[$position])) {
                        $nextPosition = $position
                        while (
                            $nextPosition -lt $KvpBlock.Length -and
                            [char]::IsWhiteSpace($KvpBlock[$nextPosition])
                        ) {
                            $nextPosition++
                        }

                        if (
                            $nextPosition -lt $KvpBlock.Length -and
                            $KvpBlock[$nextPosition] -eq '-'
                        ) {
                            break
                        }
                    }

                    $position++
                }

                $value = $KvpBlock.Substring($valueStart, $position - $valueStart).Trim()
            }

            if ([string]::IsNullOrWhiteSpace($value)) {
                throw "Filter parameter '$key' does not have a value."
            }

            $values[$key] = $value
        }

        # Keep the existing PSCustomObject return contract.
        return ($values | ConvertTo-Json -Compress) | ConvertFrom-Json
    }

    [pscustomobject] ParsePathWithOptionalFilter([string]$Path) {

        $clean = @()
        $filters = @()

#        foreach ($seg in ($Path -split '\.')) {

            $s = $Path.Trim()

            if ($s -match '^(?<name>[^\[\]]+)\[(?<kvp>[^\]]*)\]$') {
                $clean += $matches.name.Trim()
                $filters += $this.ConvertKvpBlockToObject($matches.kvp)
            }
            elseif ($s -match '^(?<name>[^()]+)\((?<kvp>[^)]*)\)$') {
                $clean += $matches.name.Trim()
                $filters += $this.ConvertKvpBlockToObject($matches.kvp)
            }
            elseif ($s -match '^(?<name>\S+)\s+(?<kvp>(?:-[A-Za-z0-9_.-]+(?:\s+|=)|[A-Za-z0-9_.-]+\s*=).+)$') {
                $clean += $matches.name.Trim()
                $filters += $this.ConvertKvpBlockToObject($matches.kvp)
            }
            else {
                $clean += $s
            }
 #       }

        return [pscustomobject]@{
            Path    = ($clean -join '.')
            Filters = $filters
        }
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
        $opSignal = [Signal]::Start("Queue_AzureStorageQueue.Invoke:$Slot.$Activity", $ItemSignal) | Select-Object -Last 1

        try {
            if (-not $ConductionSignal) {
                $opSignal.LogCritical("❌ Null ConductionSignal passed to Queue_AzureStorageQueue.Invoke()")
                return $opSignal
            }

            $opSignal.SetJacket($ConductionSignal)

            if (-not $Activity) {
                $opSignal.LogWarning("No Activity provided to Queue_AzureStorageQueue.Invoke()")
                return $opSignal
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

            $resultSignal = $null 

            switch ($Activity) {

                # ---------------------------------------------------------
                # Canonical verbs
                # ---------------------------------------------------------

                "PeekBatch" {
                    return $this.Invoke($Slot, "ReadBatch", $ConductionSignal, $Plan, $ItemSignal)
                    break
                }

                "HandleMessage" {
                    $MessageTextSignal = Resolve-PathFromDictionary -Dictionary $ItemSignal -Path "%.@.MessageText" | Select-Object -Last 1
                    if ($opSignal.MergeSignalAndVerifyFailure($MessageTextSignal)) { return $opSignal }
                    $MessageText = $MessageTextSignal.GetResult()
                    $text = ([string]$MessageText).Trim()

                    # Try Base64→UTF8 (heuristic): re-encode equality ignoring trailing '=' padding
                    $decoded = $text
                    $wasBase64 = $false
                    try {
                        $bytes = [Convert]::FromBase64String($text)
                        $reencode = [Convert]::ToBase64String($bytes)
                        if ($reencode.TrimEnd('=') -eq $text.Trim().TrimEnd('=')) {
                            $decoded = [Text.Encoding]::UTF8.GetString($bytes)
                            $wasBase64 = $true
                        }
                    }
                    catch { }

                    # Undo HtmlEncode we do during Write-StorageQueueApi
                    $decoded = [System.Net.WebUtility]::HtmlDecode($decoded)

                    $MessageItem = $decoded | ConvertFrom-Json -Depth 10
                    # Run Item  Process

                    $DecodedItemSignal = [Signal]::Start("Queue_AzureStorageQueue.HandleItem.$($ItemSignal.Name)", $ItemSignal) | Select-Object -Last 1
                    $DecodedItemSignal.SetResult($MessageItem)


                    # TODO: This handeling needs to be moved to a condenser call that calls the discord network adapter message handler.

                    # TODO: These mappings should be done in a plan to create a new config object to pass on
                    $applicationIdSignal = Resolve-PathFromDictionary -Dictionary $MessageItem -Path "@.application_id" -SignalLevel "Warning" | Select-Object -Last 1
                    $channelIdSignal = Resolve-PathFromDictionary -Dictionary $MessageItem -Path "@.channel.id" -SignalLevel "Warning" | Select-Object -Last 1
                    $channelNameSignal = Resolve-PathFromDictionary -Dictionary $MessageItem -Path "@.channel.id" -SignalLevel "Warning" | Select-Object -Last 1
                    $channelTitleSignal = Resolve-PathFromDictionary -Dictionary $MessageItem -Path "@.channel.id -SignalLevel "Warning"" | Select-Object -Last 1
                    $channelTypeSignal = Resolve-PathFromDictionary -Dictionary $MessageItem -Path "@.channel.type" -SignalLevel "Warning" | Select-Object -Last 1
                    $interactionIdSignal = Resolve-PathFromDictionary -Dictionary $MessageItem -Path "@.id" -SignalLevel "Warning" | Select-Object -Last 1
                    $interactionSignal = Resolve-PathFromDictionary -Dictionary $MessageItem -Path "@.token" -SignalLevel "Warning" | Select-Object -Last 1
                    $replySignal = Resolve-PathFromDictionary -Dictionary $MessageItem -Path "@.data.options.0.value" -SignalLevel "Warning" | Select-Object -Last 1
                    $nameSignal = Resolve-PathFromDictionary -Dictionary $MessageItem -Path "@.data.options.0.name" -SignalLevel "Warning" | Select-Object -Last 1
 
                    $applicationId = $applicationIdSignal.GetResult()
                    $interactionId = $interactionIdSignal.GetResult()
                    $interactionToken = $interactionSignal.GetResult()
                    $channelId = $channelIdSignal.GetResult()
                    $channelType = $channelTypeSignal.GetResult()

                    $channelName = $channelNameSignal.GetResult()
                    $channelTitle = $channelTitleSignal.GetResult()

                    $name = $nameSignal.GetResult()
                    $reply = $replySignal.GetResult()
  

                    $userTitleSignal = Resolve-PathFromDictionary -Dictionary $MessageItem -Path "@.member.user.global_name" -SignalLevel "Warning" | Select-Object -Last 1
                    $userIdSignal = Resolve-PathFromDictionary -Dictionary $MessageItem -Path "@.member.user.id" -SignalLevel "Warning" | Select-Object -Last 1
                    $userNameSignal = Resolve-PathFromDictionary -Dictionary $MessageItem -Path "@.member.user.username" -SignalLevel "Warning" | Select-Object -Last 1
                    # Channel ID Is used to hold a conversation in the message graph

                    # Call the session adapter and request or register session

                    $SessionPlan = [PSCustomObject]@{
                        Adapter  = "Session.System"
                        Path     = "*.#.$channelId"
                        Activity = "RequestOrRegister"
                    }

                    $SessionItemResult = [PSCustomObject]@{
                        Id    = $channelId
                        Name  = $channelName
                        Title = $channelTitle
                        User  = [PSCustomObject]@{
                            Id    = $userIdSignal.GetResult()
                            Title = $userTitleSignal.GetResult()
                            Name  = $userNameSignal.GetResult()  
                        }
                    }

                    # Name is the activity to perform and then specific handling for the way it's done
                    if ($name) {
                        $SessionItemSignal = [Signal]::Start("Queue_AzureStorageQueue.HandleItem.$($ItemSignal.Name)", $ItemSignal) | Select-Object -Last 1
                        $SessionItemSignal.SetJacketResult($SessionItemResult)

                        $sessionResult = Invoke-MappedAdapter -Signal $ConductionSignal -ItemSignal $SessionItemSignal -Plan $SessionPlan -Adapter "Session.System" -Activity "RequestOrRegister" | Select-Object -Last 1

                        switch ($name) {
                            "direction" {
                                # Direction -> response to a prompt


                                break
                            }

                            "path" {
                                # Open -> run a plan using path, we'll have default values plugged into the config of the caller of the service and then override with parts Container.Resource.Path, special handling for : as the delimeter in order to support periods in paths converting to slashes
                                # Can Open items by running a plan that puts content in memory and then subsequent plans can use that
                                $BaseConductionPlanMapping = [pscustomobject]@{
                                    Adapter      = 'Storage.Content'
                                    Format        = "Json"
                                    Activity = "Read"
                                    Key = "Plan"
                                    HydrationPlan = "@"
                                    Path = $null
                                    Container = $null
                                    Resource = $null
                                }

                                $pathParts = $reply -split '\.'
                                $BaseConductionPlanMapping.Container = $pathParts[0]                                
                                $BaseConductionPlanMapping.Resource = $pathParts[1] + ".Json"
                                $ItemValue = $null

                                if ($pathParts.Count -gt 2) {

                                    $rawPath = ($pathParts[2..($pathParts.Count - 1)] -join '.')

                                    #$rawPath = "EnrollMe[Name=ABC,Fun=Xyz is great,NNN=a b c]"
                                    $parsed  = $this.ParsePathWithOptionalFilter($rawPath)

                                    $BaseConductionPlanMapping.Path = $parsed.Path
                                    if ($parsed.Filters.Count -gt 0) {
                                        $ItemValue  = $parsed.Filters[0]
                                    }
                                }
                                else {
                                    $BaseConductionPlanMapping.Path = $null
                                }

                                $BaseConductionPlanRoute = [PSCustomObject]@{
                                    Steps = @($BaseConductionPlanMapping)
                                }

                                $SentItemSignal = [Signal]::Start("Queue_AzureStorageQueue.HandleItem.$($ItemSignal.Name)", $ItemSignal) | Select-Object -Last 1
                                $SentItemSignal.SetJacketResult($ItemValue)

                                if ($ItemValue)
                                {
                                    $null = Add-PathToDictionary -Dictionary $SentItemSignal -Path "*.#.Data" -Value $ItemValue

                                    # Attach data ($ItemValue) to the session that will be ran by the plan.
                                    if ($sessionResult)
                                    {
                                        $null = Add-PathToDictionary -Dictionary $sessionResult -Path "*.#.Data" -Value $ItemValue
                                    }
                                }

                                if ($sessionResult)
                                {
                                    $null = Add-PathToDictionary -Dictionary $SentItemSignal -Path "*.#.Session" -Value $sessionResult
                                }

                                $xyz = Invoke-MappedAdapter -Adapter "Condenser.Memory" -Activity "Generate" -Plan $BaseConductionPlanRoute -Signal $ConductionSignal -ItemSignal $SentItemSignal | Select-Object -Last 1
                                $PlanSignal = Resolve-PathFromDictionary -Dictionary $SentItemSignal -Path "*.#.$($BaseConductionPlanMapping.Key)" | Select-Object -Last 1

                                Invoke-MappedAdapter -Adapter "Conduction.System" -Activity "Invoke" -Plan $PlanSignal.GetResult($true) -Signal $ConductionSignal -ItemSignal $sessionResult | Select-Object -Last 1

                                # TODO NEXT: Need to put in a plan that loads or reloads a publisher, etc and then add a plan to persist the object
                                break
                            }

                            "question" {

                                break
                            }
                        }
                    }


                    # Each Thread/Channel is a conduction with it's own operating memory, each plan run is essentially a phase inside of that conduction (like a conduction plan that calls another conduction plan is all inside the same conduction plan, all attached to the processid of the session)
                    # This allows for opening a publisher, enrolling a project, the project ad publisher are loaded
                    # Reverse cascading opens opens an item at a level and then loads the prior content into memory, just like the SDA conductions did
                    # This allows multiple users to exist in the same conduction pipeline with different owners
                    # Finish Support for multi-threaded runspaces that share the same conductor for multple users and processes inside the same powershell runtie



                    # Move hosting to BDDB.IO instead of done directly through SDA. BDDB.IO can work out hosting deals including charity donations for supporting projects that use sovereign trust using Signalarity.Network domain 
                    # Finish the C# implementation of the system to move that into a service hosted in azure


                    

                    <# Not done here, this call back to wait for further interaction from the service is done at the azure function handler. #> <#
                    $uri = "https://discord.com/api/v10/interactions/$interactionId/$interactionToken/callback"

                    $body = @{
                        type = 5
                    } | ConvertTo-Json -Depth 5
                    try {
                       # Invoke-RestMethod -Method Post -Uri $uri -ContentType "application/json" -Body $body
                    }
                    catch {
                        $a = $_
                    }
                    #>
                    
                    # Now delete Item
                    $deleteResultSignal = $this.Invoke($Slot, "AckItem", $ConductionSignal, $Plan, $ItemSignal)
                    $opSignal.MergeSignal($deleteResultSignal)

                    break
                }

                "ReadBatch" {
                    $PeekUntilEmptySignal = Resolve-PathFromDictionary -Dictionary $Plan -Path "PeekUntilEmpty" -Default $true | Select-Object -Last 1
                    $PeekUntilEmpty = [boolean]$PeekUntilEmptySignal.GetResult()

                    $peekDepthSignal = Resolve-PathFromDictionary -Dictionary $Plan -Path "Config.PeekDepth" -Default 1 | Select-Object -Last 1
                    $peekDepth = [int]$peekDepthSignal.GetResult()

                    $VisibilitytimeoutSignal = Resolve-PathFromDictionary -Dictionary $Plan -Path "Visibilitytimeout" -Default 10 | Select-Object -Last 1
                    $Visibilitytimeout = [int]$VisibilitytimeoutSignal.GetResult()


                    $MaxParallelismSignal = Resolve-PathFromDictionary -Dictionary $Plan -Path "MaxParallelism" -Default 1 | Select-Object -Last 1
                    $MaxParallelism = [int]$MaxParallelismSignal.GetResult()

                    $parallelSupport = $MaxParallelism -gt 1

                    $Dequeue = $true
                    $querystring = if ($Dequeue) {
                        "?numofmessages=$peekDepth&visibilitytimeout=$Visibilitytimeout"
                    }
                    else {
                        "?peekonly=true&numofmessages=$peekDepth"
                    }

                    $clonePlan = (Resolve-ClonePlan -Plan $Plan | Select-Object -Last 1).GetResult()
                    Add-PathToDictionary -Dictionary $clonePlan -Path "QueryString" -Value $querystring

                    $HostSignal = Resolve-PathFromDictionary -Dictionary $this.Signal -Path "%.@.Addresses" | Select-Object -Last 1
                    $HostAddress = $HostSignal.GetResult()

                    $UriSignal = Resolve-PathFromDictionary -Dictionary $this.Signal -Path "%.@.Resource" | Select-Object -Last 1
                    $Uri = $UriSignal.GetResult()

                    $null = Add-PathToDictionary -Dictionary $clonePlan -Path "Config.Uri" -Value "$HostAddress/$Uri"
                    $null = Add-PathToDictionary -Dictionary $clonePlan -Path "Config.Host" -Value "$HostAddress"
                    $null = Add-PathToDictionary -Dictionary $clonePlan -Path "Config.Host" -Value "https://storage.azure.com/"
                    $null = Add-PathToDictionary -Dictionary $clonePlan -Path "Config.CacheAccessToken" -Value $true

                    $responseJacketSignal = [Signal]::Start("Queue_AzureStorageQueue.Invoke:$Slot.$Activity.Jacket", $ItemSignal) | Select-Object -Last 1

                    # Call Rest Endpoint
                    $responseSignal = Invoke-MappedAdapter -Adapter "Condenser.Rest" -Activity "Get" -Signal $ConductionSignal -Plan $clonePlan -ItemSignal $ItemSignal
                    if ($opSignal.MergeSignalAndVerifyFailure($responseSignal)) { return $opSignal }
                    $responseJacketSignal.SetJacket($responseSignal)
                    
                    # Format As Xml
                    $formatResultSignal = Invoke-CondenserAdapter -Slot "Format" -Activity "Xml" -Plan $Plan -Signal $ConductionSignal -ItemSignal $responseJacketSignal | Select-Object -Last 1
                    if ($opSignal.MergeSignalAndVerifyFailure($formatResultSignal)) { return $opSignal }
                    $responseJacketSignal.SetJacket($formatResultSignal)

                    # Transform - Select Path to get Messages as array of strings
                    $transformResultSignal = Invoke-CondenserAdapter -Slot "Transform" -Activity "Select" -Plan $Plan -Signal $ConductionSignal -ItemSignal $responseJacketSignal | Select-Object -Last 1
                    if ($opSignal.MergeSignalAndVerifyFailure($transformResultSignal) -or (-not $transformResultSignal.HasResult())) { return $opSignal }
                    $responseJacketSignal.SetJacket($transformResultSignal)

                    $result = @($responseJacketSignal.GetJacket().GetResult($true) ?? [PSCustomObject]@{})
                    # Set the result value from the rest endpoint
                    $opSignal.SetResult($result)

                    break
                }

                "WriteItem" {
                    # Plan should contain the payload to write
                    # e.g. Plan.MessageText or Plan.Payload etc.
                    # Placeholder: wire to your Write-StorageQueueApi when available.
                    $opSignal.LogWarning("WriteItem not implemented yet (wire to Write-StorageQueueApi).")
                    $resultSignal = [Signal]::Start("StorageQueue.WriteItem.Unresolved", $ItemSignal) | Select-Object -Last 1
                    break
                }

                "AckItem" {
                    # Ack = delete message. Needs MessageId + PopReceipt.
                    # Expect the message to be in ItemSignal jacket/result depending on your pipeline.

                    $MessageIdSignal = Resolve-PathFromDictionary -Dictionary $ItemSignal -Path "%.@.MessageId" | Select-Object -Last 1
                    $PopReceiptSignal = Resolve-PathFromDictionary -Dictionary $ItemSignal -Path "%.@.PopReceipt" | Select-Object -Last 1

                    $MessageId = $MessageIdSignal.GetResult()
                    $PopReceipt = $PopReceiptSignal.GetResult()
                    
                    # DELETE {ServiceUrl}/{MessageId}?popreceipt={PopReceipt}
                    $querystring = "/{0}?popreceipt={1}" -f $MessageId, [Uri]::EscapeDataString($PopReceipt)

                    try {
                        $clonePlan = (Resolve-ClonePlan -Plan $Plan | Select-Object -Last 1).GetResult()
                        Add-PathToDictionary -Dictionary $clonePlan -Path "Config.QueryString" -Value $querystring

                        $HostSignal = Resolve-PathFromDictionary -Dictionary $this.Signal -Path "%.@.Addresses" -Default 1 | Select-Object -Last 1
                        $HostAddress = $HostSignal.GetResult()

                        $UriSignal = Resolve-PathFromDictionary -Dictionary $this.Signal -Path "%.@.Resource" -Default 1 | Select-Object -Last 1
                        $Uri = $UriSignal.GetResult()

                        $null = Add-PathToDictionary -Dictionary $clonePlan -Path "Config.Uri" -Value "$HostAddress/$Uri"
                        $null = Add-PathToDictionary -Dictionary $clonePlan -Path "Config.Host" -Value "$HostAddress"
                        $null = Add-PathToDictionary -Dictionary $clonePlan -Path "Config.Method" -Value "Delete"
                        $null = Add-PathToDictionary -Dictionary $clonePlan -Path "Config.CacheAccessToken" -Value $true

                        $responseJacketSignal = [Signal]::Start("Queue_AzureStorageQueue.Invoke:$Slot.$Activity.Jacket", $ItemSignal) | Select-Object -Last 1

                        $responseSignal = Invoke-MappedAdapter -Adapter "Condenser.Rest" -Activity "Delete" -Signal $ConductionSignal -Plan $clonePlan -ItemSignal $ItemSignal
                        if ($opSignal.MergeSignalAndVerifyFailure($responseSignal)) { return $opSignal }
                    }
                    catch {
                        throw "Delete-StorageQueueApi: Failed to delete message id '$MessageId'. $($_.Exception.Message)"
                    }

                    $resultSignal = [Signal]::Start("StorageQueue.AckItem.Unresolved", $ItemSignal) | Select-Object -Last 1
                    break
                }

                "DeferItem" {
                    # Defer = update visibility timeout. Needs MessageId + PopReceipt + new Visibilitytimeout.
                    $msg = $ItemSignal.HasResult() ? $ItemSignal.GetResult() : $null

                    $visSignal = Resolve-PathFromDictionary -Dictionary $Plan -Path "Visibilitytimeout" -Default 30 | Select-Object -Last 1
                    $vis = $visSignal.HasResult() ? [int]$visSignal.GetResult() : 30

                    if (-not $msg) {
                        $opSignal.LogWarning("DeferItem requires ItemSignal.Result to be the message object.")
                        $resultSignal = [Signal]::Start("StorageQueue.DeferItem.Unresolved", $ItemSignal) | Select-Object -Last 1
                        break
                    }

                    if (-not ($msg | Get-Member -Name "MessageId") -or -not ($msg | Get-Member -Name "PopReceipt")) {
                        $opSignal.LogWarning("DeferItem requires MessageId + PopReceipt on message.")
                        $resultSignal = [Signal]::Start("StorageQueue.DeferItem.Unresolved", $ItemSignal) | Select-Object -Last 1
                        break
                    }

                    # Placeholder: wire to your Update-StorageQueueVisibilityApi implementation
                    # $deferSignal = Update-StorageQueueVisibilityApi -Config $config -MessageId $msg.MessageId -PopReceipt $msg.PopReceipt -Visibilitytimeout $vis | Select-Object -Last 1
                    # $resultSignal = $deferSignal

                    $opSignal.LogWarning("DeferItem not implemented yet (wire to Update-StorageQueueVisibilityApi).")
                    $resultSignal = [Signal]::Start("StorageQueue.DeferItem.Unresolved", $ItemSignal) | Select-Object -Last 1
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
            $opSignal.LogCritical("🔥 Exception in Queue_AzureStorageQueue.Invoke: $($_.Exception.Message)", $null, $_)
        }

        return $opSignal
    }
}

function Resolve-Queue_AzureStorageQueue {
    $object = [Queue_AzureStorageQueue]::new()
    return $object
}

Export-ModuleMember -Function Resolve-Queue_AzureStorageQueue
