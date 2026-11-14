using module SignalGraph

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '../Src/Intelligence/AzureFoundry/PowerShell/Intelligence_AzureFoundry.psd1') -Force
function Assert([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }

$jacket = [pscustomobject]@{
    Name='Foundry'; ApiKind='OpenAIResponses'; DefaultModelKey='Worker-Medium'
    Profiles=@(
        [pscustomobject]@{ ModelKey='Worker-Medium'; Model='deployment-medium'; ReasoningEffort='medium' },
        [pscustomobject]@{ ModelKey='Worker-High'; Model='deployment-high'; ReasoningEffort='high' }
    )
    Addresses=@('https://fixture.openai.azure.com/openai/v1/responses'); Resource=@('fixture-key')
}
$adapter = Resolve-Intelligence_AzureFoundry
$constructed = $adapter.Construct($jacket)
Assert (-not $constructed.Failure()) 'Valid Foundry jacket failed construction.'
$signal = [Signal]::Start('Foundry.Tests') | Select-Object -Last 1

& (Get-Module Intelligence_AzureFoundry) {
    Set-Item Function:script:Invoke-MappedAdapter -Value {
        param($Adapter,$Activity,$Signal,$Plan,$ItemSignal)
        $global:FoundryRequest = $Plan
        $result = [Signal]::Start('Foundry.MockRest') | Select-Object -Last 1
        $result.SetResult([pscustomobject]@{
            status='completed'
            output=@(
                [pscustomobject]@{ type='reasoning'; summary=@() },
                [pscustomobject]@{ type='message'; role='assistant'; content=@([pscustomobject]@{ type='output_text'; text='fixture answer' }) }
            )
        }) | Out-Null
        return $result
    }
}

$plan = [pscustomobject]@{ Config=[pscustomobject]@{ Prompt=[pscustomobject]@{ System='system'; Texts=@('hello'); Media=@() } } }
$result = $adapter.Invoke('Foundry','SendMessage',$signal,$plan,$signal)
Assert (-not $result.Failure() -and (($result.GetResult() | ConvertFrom-Json).choices[0].message.content -ceq 'fixture answer')) 'Default profile or result normalization failed.'
Assert ($global:FoundryRequest.Config.Body.model -ceq 'deployment-medium' -and $global:FoundryRequest.Config.Body.reasoning.effort -ceq 'medium') 'Default profile was not sent.'
Assert ($global:FoundryRequest.Config.Body.input[0].role -ceq 'system' -and $global:FoundryRequest.Config.Body.input[1].content[0].type -ceq 'input_text') 'Responses input shape is invalid.'
Assert ($global:FoundryRequest.Config.Headers['api-key'] -ceq 'fixture-key' -and $global:FoundryRequest.Config.Uri -ceq $jacket.Addresses[0]) 'Foundry address or authentication differs.'

$plan.Config | Add-Member -NotePropertyName ModelKey -NotePropertyValue 'Worker-High'
$high = $adapter.Invoke('Foundry','SendMessage',$signal,$plan,$signal)
Assert (-not $high.Failure() -and $global:FoundryRequest.Config.Body.model -ceq 'deployment-high' -and $global:FoundryRequest.Config.Body.reasoning.effort -ceq 'high') 'Explicit profile was not sent.'
$plan.Config.Prompt.Media = @([pscustomobject]@{ MediaUrl='https://example.org/image.png'; MediaType='image'; Detail='high' })
$image = $adapter.Invoke('Foundry','SendMessage',$signal,$plan,$signal)
Assert (-not $image.Failure() -and $global:FoundryRequest.Config.Body.input[1].content[1].type -ceq 'input_image' -and
    $global:FoundryRequest.Config.Body.input[1].content[1].image_url -ceq 'https://example.org/image.png') 'Responses image input shape is invalid.'
$plan.Config.ModelKey = 'unknown'
Assert ($adapter.Invoke('Foundry','SendMessage',$signal,$plan,$signal).Failure()) 'Unknown ModelKey was accepted.'
$plan.Config.ModelKey = 'Worker-Medium'
& (Get-Module Intelligence_AzureFoundry) {
    Set-Item Function:script:Invoke-MappedAdapter -Value {
        $result = [Signal]::Start('Foundry.MockRestFailure') | Select-Object -Last 1
        $null = $result.LogCritical('Fixture HTTP failure.')
        return $result
    }
}
Assert ($adapter.Invoke('Foundry','SendMessage',$signal,$plan,$signal).Failure()) 'REST failure was not propagated.'
$jacket.Profiles += [pscustomobject]@{ ModelKey='Worker-Medium'; Model='duplicate'; ReasoningEffort='medium' }
Assert ((Resolve-Intelligence_AzureFoundry).Construct($jacket).Failure()) 'Duplicate ModelKey was accepted.'

Write-Output 'PASS: Foundry profile selection, Responses body, normalized result, and invalid keys.'

$v2Jacket = [pscustomobject]@{
    SchemaVersion=2
    Resource=@([pscustomobject]@{ Key='test'; Credentials='fixture-key' })
    Routes=@([pscustomobject]@{ Key='responses'; ApiKind='OpenAIResponses'; Address='https://fixture.services.ai.azure.com/api/projects/test/openai/v1/responses'; ResourceKey='test'; AuthMode='ApiKey' })
    Profiles=@(
        [pscustomobject]@{ Key='visual-worker-standard'; IsDefault=$true; RouteKey='responses'; Model='gpt-6.1-sol'; ReasoningEffort='medium'; ExplicitPromptCacheSupported=$true },
        [pscustomobject]@{ Key='visual-reviewer-standard'; IsDefault=$false; RouteKey='responses'; Model='gpt-6.1-sol'; ReasoningEffort='medium' },
        [pscustomobject]@{ Key='visual-reviewer-advanced'; IsDefault=$false; RouteKey='responses'; Model='gpt-6-astra'; ReasoningEffort='medium' }
    )
}
$v2 = Resolve-Intelligence_AzureFoundry
Assert (-not $v2.Construct($v2Jacket).Failure()) 'Schema-2 Foundry jacket failed construction.'
$global:FoundryHttpCalls = 0
& (Get-Module Intelligence_AzureFoundry) {
    Set-Item Function:script:Invoke-MappedAdapter -Value {
        param($Adapter,$Activity,$Signal,$Plan,$ItemSignal)
        $global:FoundryHttpCalls++
        $global:FoundryRequest = $Plan
        $result = [Signal]::Start('Foundry.MockRestV2') | Select-Object -Last 1
        $result.SetResult([pscustomobject]@{
            status='completed'
            usage=[pscustomobject]@{ input_tokens=1250; input_tokens_details=[pscustomobject]@{ cached_tokens=1024; cache_write_tokens=0 } }
            output=@([pscustomobject]@{ type='message'; role='assistant'; content=@([pscustomobject]@{ type='output_text'; text='structured fixture' }) })
        }) | Out-Null
        return $result
    }
}
$structured = [pscustomobject]@{ Config=[pscustomobject]@{
    ModelKey='visual-worker-standard'
    Prompt=[pscustomobject]@{
        StableSystem='shared authority'
        StableTexts=@('task contract','canonical resources')
        StableMedia=@([pscustomobject]@{ MediaUrl='https://example.org/source.png'; MediaType='image'; Detail='high' })
        PhaseSystem='Pass1 trusted role'
        PhaseTexts=@('CandidateInputs: None')
    }
} }
$before = $global:FoundryHttpCalls
$valid = $v2.Invoke('Foundry','ValidateProfiles',$signal,([pscustomobject]@{ Config=[pscustomobject]@{ WorkerProfile='visual-worker-standard'; ReviewerProfile='visual-reviewer-standard' } }),$signal)
Assert (-not $valid.Failure() -and $valid.HasResult() -and $global:FoundryHttpCalls -eq $before) 'Artifact profile preflight contacted provider or failed.'
$invalid = $v2.Invoke('Foundry','ValidateProfiles',$signal,([pscustomobject]@{ Config=[pscustomobject]@{ WorkerProfile='visual-worker-standard'; ReviewerProfile='visual-worker-standard' } }),$signal)
Assert ($invalid.Failure() -and $global:FoundryHttpCalls -eq $before) 'Invalid reviewer profile was not rejected before send.'
foreach ($invalidReviewer in @('', 'text-reviewer-standard', 'unknown')) {
    $invalid = $v2.Invoke('Foundry','ValidateProfiles',$signal,([pscustomobject]@{ Config=[pscustomobject]@{ WorkerProfile='visual-worker-standard'; ReviewerProfile=$invalidReviewer } }),$signal)
    Assert ($invalid.Failure() -and $global:FoundryHttpCalls -eq $before) "Reviewer override '$invalidReviewer' was not rejected before send."
}
$missingWorker = $v2.Invoke('Foundry','ValidateProfiles',$signal,([pscustomobject]@{ Config=[pscustomobject]@{ WorkerProfile=''; ReviewerProfile='visual-reviewer-standard' } }),$signal)
Assert ($missingWorker.Failure() -and $global:FoundryHttpCalls -eq $before) 'Unknown ModelMode/worker profile was not rejected before send.'
$result = $v2.Invoke('Foundry','SendMessage',$signal,$structured,$signal)
Assert (-not $result.Failure()) 'Schema-2 structured request failed.'
$body = $global:FoundryRequest.Config.Body
Assert ($body.model -ceq 'gpt-6.1-sol' -and $body.reasoning.effort -ceq 'medium' -and $body.input.Count -eq 4) 'Schema-2 selected profile or ordered message count changed.'
Assert ($body.input[0].role -ceq 'system' -and $body.input[0].content -ceq 'shared authority' -and
    $body.input[1].role -ceq 'user' -and $body.input[1].content.Count -eq 3 -and
    $body.input[1].content[0].text -ceq 'task contract' -and $body.input[1].content[1].text -ceq 'canonical resources' -and
    $body.input[1].content[2].type -ceq 'input_image' -and $body.input[1].content[2].image_url -ceq 'https://example.org/source.png' -and
    $body.input[2].role -ceq 'system' -and $body.input[2].content -ceq 'Pass1 trusted role' -and
    $body.input[3].role -ceq 'user' -and $body.input[3].content[0].text -ceq 'CandidateInputs: None') 'Structured stable/phase boundary or media order changed.'
Assert ($body.input[1].content[2].prompt_cache_breakpoint.mode -ceq 'explicit' -and
    $null -eq $body.input[1].content[1].prompt_cache_breakpoint -and $null -eq $body.prompt_cache_options) 'Capability-gated stable image breakpoint is invalid.'
$normalized = $result.GetResult() | ConvertFrom-Json -Depth 20
Assert ($normalized.choices[0].message.content -ceq 'structured fixture' -and $normalized.usage.input_tokens_details.cached_tokens -eq 1024) 'Output/usage normalization changed.'
$structured.Config.Prompt.StableMedia = @()
$textOnly = $v2.Invoke('Foundry','SendMessage',$signal,$structured,$signal)
Assert (-not $textOnly.Failure() -and $global:FoundryRequest.Config.Body.input[1].content[1].prompt_cache_breakpoint.mode -ceq 'explicit') 'Stable text breakpoint missing.'
$structured.Config.ModelKey = 'visual-reviewer-standard'
$withoutCapability = $v2.Invoke('Foundry','SendMessage',$signal,$structured,$signal)
Assert (-not $withoutCapability.Failure() -and $null -eq $global:FoundryRequest.Config.Body.input[1].content[1].prompt_cache_breakpoint) 'Disabled capability emitted a breakpoint.'
$structured.Config | Add-Member -NotePropertyName ProfileRole -NotePropertyValue 'reviewer'
$structured.Config.ModelKey = 'visual-worker-standard'
Assert ($v2.Invoke('Foundry','SendMessage',$signal,$structured,$signal).Failure()) 'Worker profile accepted reviewer role.'
$structured.Config.ModelKey = 'visual-reviewer-advanced'
Assert (-not $v2.Invoke('Foundry','SendMessage',$signal,$structured,$signal).Failure() -and $global:FoundryRequest.Config.Body.model -ceq 'gpt-6-astra') 'Explicit advanced reviewer did not route.'
$structured.Config.Prompt | Add-Member -NotePropertyName Texts -NotePropertyValue @('legacy collision')
$before = $global:FoundryHttpCalls
Assert ($v2.Invoke('Foundry','SendMessage',$signal,$structured,$signal).Failure() -and $global:FoundryHttpCalls -eq $before) 'Mixed legacy/structured prompt was sent.'
$badJacket = $v2Jacket | ConvertTo-Json -Depth 20 | ConvertFrom-Json -Depth 20
$badJacket.Profiles[0].ExplicitPromptCacheSupported = 'true'
Assert ((Resolve-Intelligence_AzureFoundry).Construct($badJacket).Failure()) 'Invalid cache capability type was accepted.'
Write-Output 'PASS: schema-2 role preflight, stable/phase serialization, capability-gated breakpoints, and usage.'
