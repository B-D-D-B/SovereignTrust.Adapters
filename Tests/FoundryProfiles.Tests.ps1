using module SignalGraph

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '../Src/Network/AzureFoundry/PowerShell/Network_AzureFoundry.psd1') -Force
function Assert([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }

$jacket = [pscustomobject]@{
    Name='Foundry'; ApiKind='OpenAIResponses'; DefaultModelKey='Worker-Medium'
    Profiles=@(
        [pscustomobject]@{ ModelKey='Worker-Medium'; Model='deployment-medium'; ReasoningEffort='medium' },
        [pscustomobject]@{ ModelKey='Worker-High'; Model='deployment-high'; ReasoningEffort='high' }
    )
    Addresses=@('https://fixture.openai.azure.com/openai/v1/responses'); Resource=@('fixture-key')
}
$adapter = Resolve-Network_AzureFoundry
$constructed = $adapter.Construct($jacket)
Assert (-not $constructed.Failure()) 'Valid Foundry jacket failed construction.'
$signal = [Signal]::Start('Foundry.Tests') | Select-Object -Last 1

& (Get-Module Network_AzureFoundry) {
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
& (Get-Module Network_AzureFoundry) {
    Set-Item Function:script:Invoke-MappedAdapter -Value {
        $result = [Signal]::Start('Foundry.MockRestFailure') | Select-Object -Last 1
        $null = $result.LogCritical('Fixture HTTP failure.')
        return $result
    }
}
Assert ($adapter.Invoke('Foundry','SendMessage',$signal,$plan,$signal).Failure()) 'REST failure was not propagated.'
$jacket.Profiles += [pscustomobject]@{ ModelKey='Worker-Medium'; Model='duplicate'; ReasoningEffort='medium' }
Assert ((Resolve-Network_AzureFoundry).Construct($jacket).Failure()) 'Duplicate ModelKey was accepted.'

Write-Output 'PASS: Foundry profile selection, Responses body, normalized result, and invalid keys.'
