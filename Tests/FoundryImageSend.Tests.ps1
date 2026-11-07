using module SignalGraph

$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot '../Src/Intelligence/AzureFoundry/PowerShell/Intelligence_AzureFoundry.psd1') -Force
function Assert([bool]$Condition,[string]$Message) { if (-not $Condition) { throw $Message } }
$global:FoundryImageCalls=0
& (Get-Module Intelligence_AzureFoundry) {
    Set-Item Function:script:Invoke-MappedAdapter -Value {
        param($Adapter,$Activity,$Signal,$Plan,$ItemSignal)
        $global:FoundryImageCalls++
        $global:FoundryImageRequest=$Plan
        $global:FoundryImageAdapter=$Adapter
        $global:FoundryImageActivity=$Activity
        $s=[Signal]::Start('Foundry.Image.FakeRest') | Select-Object -Last 1
        $global:FoundryImageWireJson=$Plan.Config.Body | ConvertTo-Json -Depth 100 -ErrorAction Stop
        $global:FoundryImageWire=$global:FoundryImageWireJson | ConvertFrom-Json -Depth 100 -ErrorAction Stop
        if ($global:FoundryImageFail) { $null=$s.LogCritical('Fixture REST failure.') }
        elseif ($Plan.Config.Body.model -ceq 'text-deployment') {
            $s.SetResult([pscustomobject]@{status='completed';output=@([pscustomobject]@{type='message';content=@([pscustomobject]@{type='output_text';text='bridge'})})}) | Out-Null
        }
        else { $s.SetResult([pscustomobject]@{ marker='parsed'; data=@('native') }) | Out-Null }
        return $s
    }
}
function New-Jacket([string]$Kind) {
    if ($Kind -ceq 'BFL') {
        return [pscustomobject]@{ SchemaVersion=2; Resource=@([pscustomobject]@{Key='bfl';Credentials='bfl-secret'});
            Routes=@([pscustomobject]@{Key='pro';ApiKind='BlackForestLabsFlux2';Address='https://west.api.cognitive.microsoft.com/providers/blackforestlabs/v1/flux-2-pro?api-version=preview';ResourceKey='bfl';AuthMode='BearerApiKey'},
                     [pscustomobject]@{Key='flex';ApiKind='BlackForestLabsFlux2';Address='https://west.api.cognitive.microsoft.com/providers/blackforestlabs/v1/flux-2-flex?api-version=preview';ResourceKey='bfl';AuthMode='BearerApiKey'});
            Profiles=@([pscustomobject]@{Key='any-pro';IsDefault=$true;RouteKey='pro';Model='FLUX.2-pro'},
                       [pscustomobject]@{Key='other-flex';IsDefault=$false;RouteKey='flex';Model='FLUX.2-flex'}) }
    }
    return [pscustomobject]@{ SchemaVersion=2;
        Resource=@([pscustomobject]@{Key='text';Credentials='text-secret'},[pscustomobject]@{Key='image';Credentials='image-secret'});
        Routes=@([pscustomobject]@{Key='responses';ApiKind='OpenAIResponses';Address='https://west.services.ai.azure.com/api/projects/project/openai/v1/responses';ResourceKey='text';AuthMode='ApiKey'},
                 [pscustomobject]@{Key='generate';ApiKind='OpenAIImageGeneration';Address='https://west.services.ai.azure.com/api/projects/project/openai/v1/images/generations';ResourceKey='image';AuthMode='ApiKey'},
                 [pscustomobject]@{Key='edit';ApiKind='OpenAIImageEdit';Address='https://west.services.ai.azure.com/api/projects/project/openai/v1/images/edits';ResourceKey='image';AuthMode='ApiKey'});
        Profiles=@([pscustomobject]@{Key='text-any';IsDefault=$true;RouteKey='responses';Model='text-deployment';ReasoningEffort='medium'},
                   [pscustomobject]@{Key='generate-any';IsDefault=$false;RouteKey='generate';Model='image-deployment'},
                   [pscustomobject]@{Key='edit-any';IsDefault=$false;RouteKey='edit';Model='edit-deployment'}) }
}
function New-Adapter($Jacket) {
    $a=Resolve-Intelligence_AzureFoundry
    $c=$a.Construct($Jacket)
    Assert (-not $c.Failure()) "V2 construction failed: $(@($c.GetEntries() | ForEach-Object Message) -join ' | ')"
    return $a
}
function Send($Adapter,$Key,$Prompt) {
    $plan=[pscustomobject]@{Config=[pscustomobject]@{Profile=[pscustomobject]@{Key=$Key};Prompt=$Prompt}}
    $before=$plan | ConvertTo-Json -Depth 100 -Compress
    $r=$Adapter.Invoke('Foundry','SendMessage',$signal,$plan,$signal)
    Assert (($plan | ConvertTo-Json -Depth 100 -Compress) -ceq $before) 'Caller Plan changed.'
    return $r
}
$signal=[Signal]::Start('Foundry.Image.Tests') | Select-Object -Last 1
$foundry=New-Adapter (New-Jacket 'Foundry')
$textPlan=[pscustomobject]@{Config=[pscustomobject]@{Prompt=[pscustomobject]@{Texts=@('hello')}}}
$textResult=$foundry.Invoke('Foundry','SendMessage',$signal,$textPlan,$signal)
Assert (-not $textResult.Failure() -and (($textResult.GetResult() | ConvertFrom-Json).choices[0].message.content -ceq 'bridge')) 'V2 Responses bridge failed.'
Assert ($global:FoundryImageRequest.Config.Headers['api-key'] -ceq 'text-secret') 'V2 Responses credential differs.'
$textCalls=$global:FoundryImageCalls
$originalText=$foundry.Invoke('Foundry','SendMessageOriginal',$signal,$textPlan,$signal)
Assert ($originalText.Failure() -and -not $originalText.HasResult() -and $global:FoundryImageCalls -eq $textCalls) 'removed original activity dispatched.'
$handleItem=[Signal]::Start('Foundry.HandleFixture') | Select-Object -Last 1
$handleItem.SetResult([pscustomobject]@{Message='handled fixture'}) | Out-Null
$handled=$foundry.Invoke('Foundry','HandleMessage',$signal,([pscustomobject]@{Path='Result.Message'}),$handleItem)
Assert (-not $handled.Failure() -and $handled.HasResult() -and $handled.GetResult() -ceq 'handled fixture') 'HandleMessage content/result regression.'
$prompt=[pscustomobject]@{model='image-deployment';prompt="literal `"text`"`nline";size='custom';stream=$false;nested=@{custom=@(1,2)}}
$r=Send $foundry 'generate-any' $prompt
Assert (-not $r.Failure() -and $r.GetResult().marker -ceq 'parsed') 'Foundry generation parsed REST result failed.'
Assert ($global:FoundryImageAdapter -ceq 'Condenser.Rest' -and $global:FoundryImageActivity -ceq 'POST') 'REST dispatch differs.'
Assert ($global:FoundryImageRequest.Config.Headers['api-key'] -ceq 'image-secret' -and -not $global:FoundryImageRequest.Config.Headers.ContainsKey('Authorization')) 'Foundry image auth differs.'
Assert ($global:FoundryImageRequest.Config.SkipBearerToken -eq $true -and $global:FoundryImageRequest.Config.Method -ceq 'Post') 'REST controls differ.'
Assert ($global:FoundryImageWire.model -ceq $prompt.model -and $global:FoundryImageWire.prompt -ceq $prompt.prompt -and
    $global:FoundryImageWire.size -ceq $prompt.size -and $global:FoundryImageWire.stream -ceq $false -and
    $global:FoundryImageWire.nested.custom.Count -eq 2 -and $global:FoundryImageWire.nested.custom[1] -eq 2) 'REST-equivalent JSON changed native values.'
Assert ($global:FoundryImageRequest.Config.Uri -ceq $foundry.Settings.Profiles['generate-any'].Route.Address) 'Generation address differs.'
$edit=[pscustomobject]@{model='edit-deployment';prompt='edit';images=@(@{file_id='file-any'})}
Assert (-not (Send $foundry 'edit-any' $edit).Failure()) 'Foundry edit failed.'
Assert ($global:FoundryImageRequest.Config.Uri -ceq $foundry.Settings.Profiles['edit-any'].Route.Address) 'Edit address differs.'
Assert ($global:FoundryImageWire.images[0].file_id -ceq 'file-any') 'REST-equivalent edit reference changed.'
$bfl=New-Adapter (New-Jacket 'BFL')
foreach ($case in @(@('any-pro','FLUX.2-pro'),@('other-flex','FLUX.2-flex'))) {
    $native=[pscustomobject]@{model=$case[1];prompt='BFL';input_image='YWJj';custom=@{nested=$true}}
    Assert (-not (Send $bfl $case[0] $native).Failure()) 'BFL route failed.'
    Assert ($global:FoundryImageRequest.Config.Headers['Authorization'] -ceq 'Bearer bfl-secret' -and
        -not $global:FoundryImageRequest.Config.Headers.ContainsKey('api-key') -and
        $global:FoundryImageWire.input_image -ceq 'YWJj' -and $global:FoundryImageWire.custom.nested -eq $true -and
        $null -eq $global:FoundryImageWire.PSObject.Properties['size']) 'BFL auth, native base64 or omitted option differs.'
}
Assert (-not (Send $foundry 'generate-any' $prompt).Failure() -and
    $global:FoundryImageRequest.Config.Headers['api-key'] -ceq 'image-secret' -and
    -not $global:FoundryImageRequest.Config.Headers.ContainsKey('Authorization')) 'Foundry credential crossed instance boundary.'
function Assert-RejectedPlan($Adapter,$Plan,[string]$Case) {
    $before=$global:FoundryImageCalls
    $result=$Adapter.Invoke('Foundry','SendMessage',$signal,$Plan,$signal)
    Assert ($result.Failure() -and -not $result.HasResult() -and $global:FoundryImageCalls -eq $before) "$Case reached REST or returned success."
    return $result
}
$base=[pscustomobject]@{Profile=[pscustomobject]@{Key='generate-any'};Prompt=$prompt}
foreach ($case in @(
    @('Config', [pscustomobject]@{Config=@($base)}),
    @('Profile', [pscustomobject]@{Config=[pscustomobject]@{Profile=@([pscustomobject]@{Key='generate-any'});Prompt=$prompt}}),
    @('Key', [pscustomobject]@{Config=[pscustomobject]@{Profile=[pscustomobject]@{Key=@('generate-any')};Prompt=$prompt}}),
    @('Prompt', [pscustomobject]@{Config=[pscustomobject]@{Profile=[pscustomobject]@{Key='generate-any'};Prompt=@($prompt)}}),
    @('model', [pscustomobject]@{Config=[pscustomobject]@{Profile=[pscustomobject]@{Key='generate-any'};Prompt=[pscustomobject]@{model=@('image-deployment');prompt='array-model'}}}),
    @('stream', [pscustomobject]@{Config=[pscustomobject]@{Profile=[pscustomobject]@{Key='generate-any'};Prompt=[pscustomobject]@{model='image-deployment';stream=@($false)}}})
)) { $null=Assert-RejectedPlan $foundry $case[1] "Singleton-array $($case[0])" }
$overhead=[Text.Encoding]::UTF8.GetByteCount((ConvertTo-Json -InputObject ([pscustomobject]@{model='image-deployment';prompt=''}) -Depth 100))
$atLimit=[pscustomobject]@{model='image-deployment';prompt=('x' * (1MB-$overhead))}
Assert (-not (Send $foundry 'generate-any' $atLimit).Failure() -and
    [Text.Encoding]::UTF8.GetByteCount($global:FoundryImageWireJson) -eq 1MB) 'At-limit REST serialization failed.'
$overLimit=[pscustomobject]@{model='image-deployment';prompt=('x' * (1MB-$overhead+1))}
$null=Assert-RejectedPlan $foundry ([pscustomobject]@{Config=[pscustomobject]@{Profile=[pscustomobject]@{Key='generate-any'};Prompt=$overLimit}}) 'Over-limit body'
$deep=[pscustomobject]@{leaf='value'}
for($i=0;$i -lt 101;$i++) { $deep=[pscustomobject]@{next=$deep} }
$null=Assert-RejectedPlan $foundry ([pscustomobject]@{Config=[pscustomobject]@{Profile=[pscustomobject]@{Key='generate-any'};Prompt=[pscustomobject]@{model='image-deployment';nested=$deep}}}) 'Depth overflow'
$calls=$global:FoundryImageCalls
foreach ($bad in @(
    [pscustomobject]@{model='wrong';prompt='x'},
    [pscustomobject]@{model='image-deployment';stream=$true},
    [pscustomobject]@{model='image-deployment';stream=$null},
    [pscustomobject]@{model='image-deployment';stream='false'},
    [pscustomobject]@{model='image-deployment';prompt=('x' * 1048576)}
)) { Assert ((Send $foundry 'generate-any' $bad).Failure()) 'Invalid native prompt was accepted.' }
Assert ((Send $foundry 'missing' $prompt).Failure()) 'Missing profile was accepted.'
$override=[pscustomobject]@{Config=[pscustomobject]@{Profile=[pscustomobject]@{Key='generate-any'};Prompt=$prompt;Body=@{evil=$true}}}
Assert ($foundry.Invoke('Foundry','SendMessage',$signal,$override,$signal).Failure()) 'REST override was accepted.'
Assert ($global:FoundryImageCalls -eq $calls) 'Negative request reached REST.'
$global:FoundryImageFail=$true
$failed=Send $foundry 'generate-any' $prompt
Assert ($failed.Failure() -and -not $failed.HasResult()) 'REST failure was not forwarded.'
$logText=@($failed.GetEntries() | ForEach-Object Message) -join ' | '
Assert ($logText -notmatch 'image-secret|bfl-secret|literal|YWJj') 'Failure log exposed credential or body.'
$global:FoundryImageFail=$false
$sensitive=[pscustomobject]@{Config=[pscustomobject]@{Profile=[pscustomobject]@{Key='generate-any'};Prompt=[pscustomobject]@{model='wrong';prompt='sensitive-body-marker'}}}
$rejected=Assert-RejectedPlan $foundry $sensitive 'Sensitive malformed body'
$rejectedLog=@($rejected.GetEntries() | ForEach-Object Message) -join ' | '
Assert ($rejectedLog -notmatch 'image-secret|bfl-secret|sensitive-body-marker') 'Validation log exposed credential or body.'
$badJacket=New-Jacket 'BFL'; $badJacket.Routes += $badJacket.Routes[0]
Assert ((Resolve-Intelligence_AzureFoundry).Construct($badJacket).Failure()) 'Duplicate route was accepted.'
$badJacket=New-Jacket 'BFL'; $badJacket.Routes[0].AuthMode='ApiKey'
Assert ((Resolve-Intelligence_AzureFoundry).Construct($badJacket).Failure()) 'Wrong BFL auth was accepted.'
$badJacket=New-Jacket 'BFL'; $badJacket.Routes[0].Address='http://west.api.cognitive.microsoft.com/providers/blackforestlabs/v1/flux-2-pro?api-version=preview'
Assert ((Resolve-Intelligence_AzureFoundry).Construct($badJacket).Failure()) 'HTTP route was accepted.'
function Assert-BadJacket($Jacket,[string]$Case) {
    Assert ((Resolve-Intelligence_AzureFoundry).Construct($Jacket).Failure()) "$Case registration was accepted."
}
$badJacket=New-Jacket 'Foundry'; $badJacket.Profiles += $badJacket.Profiles[1]
Assert-BadJacket $badJacket 'Duplicate profile'
$badJacket=New-Jacket 'Foundry'; $badJacket.Resource += $badJacket.Resource[1]
Assert-BadJacket $badJacket 'Duplicate resource'
$badJacket=New-Jacket 'Foundry'; $badJacket.Profiles[1].RouteKey='missing'
Assert-BadJacket $badJacket 'Missing route'
$badJacket=New-Jacket 'Foundry'; $badJacket.Routes[1].ResourceKey='missing'
Assert-BadJacket $badJacket 'Missing resource'
$badJacket=New-Jacket 'Foundry'; $badJacket.Resource=$badJacket.Resource[0..0]
Assert-BadJacket $badJacket 'Absent referenced resource'
$badJacket=New-Jacket 'Foundry'; $badJacket.Routes[1].Address='https://other.example.com/api/projects/project/openai/v1/images/generations'
Assert-BadJacket $badJacket 'Wrong host'
$badJacket=New-Jacket 'Foundry'; $badJacket.Routes[1].Address='https://west.services.ai.azure.com/api/projects/project/openai/v1/images/edits'
Assert-BadJacket $badJacket 'Wrong route path'
$badJacket=New-Jacket 'Foundry'; $badJacket.Routes[1].AuthMode='BearerApiKey'
Assert-BadJacket $badJacket 'Wrong image auth'
$badJacket=New-Jacket 'Foundry'; $badJacket.Profiles[1].Model=@('image-deployment')
Assert-BadJacket $badJacket 'Array profile model'
$badJacket=New-Jacket 'Foundry'; $badJacket.Profiles[1].Key=@('generate-any')
Assert-BadJacket $badJacket 'Array profile key'
$badJacket=New-Jacket 'Foundry'; $badJacket.Profiles[1].RouteKey=@('generate')
Assert-BadJacket $badJacket 'Array profile route key'
$badJacket=New-Jacket 'Foundry'; $badJacket.Routes[1].ApiKind=@('OpenAIImageGeneration')
Assert-BadJacket $badJacket 'Array route kind'
$badJacket=New-Jacket 'Foundry'; $badJacket.Routes[1].ResourceKey=@('image')
Assert-BadJacket $badJacket 'Array route resource key'
$badJacket=New-Jacket 'Foundry'; $badJacket.Routes[1].AuthMode=@('ApiKey')
Assert-BadJacket $badJacket 'Array route auth'
$badJacket=New-Jacket 'Foundry'; $badJacket.Routes[1].Address=@('https://west.services.ai.azure.com/api/projects/project/openai/v1/images/generations')
Assert-BadJacket $badJacket 'Array route address'
$badJacket=New-Jacket 'Foundry'; $badJacket.Resource[1].Credentials=@('image-secret')
Assert-BadJacket $badJacket 'Array credential'
$badJacket=New-Jacket 'Foundry'; $badJacket.Profiles[1].IsDefault=@($false)
Assert-BadJacket $badJacket 'Array default flag'
Write-Output 'PASS: Foundry OpenAI/BFL native image dispatch, guards, isolation, failure forwarding.'
