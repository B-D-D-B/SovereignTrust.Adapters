using module SignalGraph
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot '../Src/Intelligence/OpenAI/PowerShell/Intelligence_OpenAI.psd1') -Force
function Assert([bool]$ok,[string]$why) { if (-not $ok) { throw $why } }
function Jacket([string]$credential) {
    [pscustomobject]@{SchemaVersion=2
        Resource=@([pscustomobject]@{Key='openai';Credentials=$credential})
        Routes=@([pscustomobject]@{Key='responses';ApiKind='OpenAIResponses';Address='https://api.openai.com/v1/responses';ResourceKey='openai';AuthMode='ApiKey'},
            [pscustomobject]@{Key='generate';ApiKind='OpenAIImageGeneration';Address='https://api.openai.com/v1/images/generations';ResourceKey='openai';AuthMode='ApiKey'},
            [pscustomobject]@{Key='edit';ApiKind='OpenAIImageEdit';Address='https://api.openai.com/v1/images/edits';ResourceKey='openai';AuthMode='ApiKey'})
        Profiles=@([pscustomobject]@{Key='Text';IsDefault=$true;RouteKey='responses';Model='fixture-text'},
            [pscustomobject]@{Key='ArtGenerate';IsDefault=$false;RouteKey='generate';Model='fixture-image-generation'},
            [pscustomobject]@{Key='ArtEdit';IsDefault=$false;RouteKey='edit';Model='fixture-image-edit'})}
}
function Plan([string]$key='ArtGenerate',[object]$prompt=$null) {
    if ($null -eq $prompt) { $prompt=[pscustomobject]@{model='fixture-image-generation';prompt='literal image text';n=2;size='1536x1024';output_format='jpeg';quality='high';extras=[pscustomobject]@{weights=@(1,2);labels=@('a','b')}} }
    [pscustomobject]@{Config=[pscustomobject]@{Profile=[pscustomobject]@{Key=$key};Prompt=$prompt}}
}
$a=Resolve-Intelligence_OpenAI;$b=Resolve-Intelligence_OpenAI
Assert (-not $a.Construct((Jacket 'dummy-A')).Failure()) 'first v2 construction'
Assert (-not $b.Construct((Jacket 'dummy-B')).Failure()) 'second v2 construction'
$signal=[Signal]::Start('fixture') | Select-Object -Last 1
$global:ImageRestCalls=0
$global:ImageRestResult=[pscustomobject]@{data=@([pscustomobject]@{b64_json='opaque fixture'})}
$module=Get-Module Intelligence_OpenAI
& $module {
    Set-Item Function:script:Invoke-MappedAdapter -Value {
        param($Adapter,$Activity,$Signal,$Plan,$ItemSignal)
        $global:ImageRestCalls++
        $global:ImageRestRequest=[pscustomobject]@{Adapter=$Adapter;Activity=$Activity;Plan=$Plan}
        $r=[Signal]::Start('fake-rest',$Signal) | Select-Object -Last 1
        if ($global:ImageRestFail) { $null=$r.LogCritical('fake REST failure') }
        else { $r.SetResult($global:ImageRestResult) | Out-Null }
        return $r
    }
    Set-Item Function:script:Invoke-WebRequest -Value {
        param($Uri,$Method,$Headers,$Body,$ContentType,$MaximumRetryCount,$MaximumRedirection,$ConnectionTimeoutSeconds,$OperationTimeoutSeconds,[switch]$SkipHttpErrorCheck,$ErrorAction,$Verbose,$Debug,$WarningAction)
        $global:ImageTextCalls++
        $global:ImageTextRequest=[pscustomobject]@{Uri=$Uri;Headers=$Headers;Body=$Body}
        [pscustomobject]@{StatusCode=200;Content='{"status":"completed","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"fixture text"}]}]}'}
    }
}
$global:ImageTextCalls=0
$textPlan=[pscustomobject]@{Config=[pscustomobject]@{Content='text input'}}
$r=$a.Invoke('OpenAI','SendMessage',$signal,$textPlan,$signal)
Assert (-not $r.Failure() -and ($r.GetResult()|ConvertFrom-Json).choices[0].message.content -ceq 'fixture text') 'text regression'
$textCalls=$global:ImageTextCalls
$removed=$a.Invoke('OpenAI','SendMessageOriginal',$signal,$textPlan,$signal)
Assert ($removed.Failure() -and -not $removed.HasResult() -and $global:ImageTextCalls -eq $textCalls -and $global:ImageRestCalls -eq 0) 'removed original text activity dispatched'
$lowercase=$a.Invoke('OpenAI','sendmessage',$signal,$textPlan,$signal)
Assert ($lowercase.Failure() -and -not $lowercase.HasResult() -and $global:ImageTextCalls -eq $textCalls -and $global:ImageRestCalls -eq 0) 'lowercase send activity dispatched'
Assert ($global:ImageTextCalls -eq 1 -and $global:ImageTextRequest.Headers.Authorization -ceq 'Bearer dummy-A' -and
    ($global:ImageTextRequest.Body|ConvertFrom-Json).model -ceq 'fixture-text') 'v2 text route/auth'
$plan=Plan
$before=$plan|ConvertTo-Json -Depth 20 -Compress
$r=$a.Invoke('OpenAI','SendMessage',$signal,$plan,$signal)
Assert (-not $r.Failure() -and $r.GetResult() -eq $global:ImageRestResult) 'REST response forwarding'
$restPlan=$global:ImageRestRequest.Plan
Assert ($global:ImageRestCalls -eq 1 -and $global:ImageRestRequest.Adapter -ceq 'Condenser.Rest' -and $global:ImageRestRequest.Activity -ceq 'POST') 'mapped REST dispatch'
$config=$global:ImageRestRequest.Plan.Config
Assert ($config.Uri -ceq 'https://api.openai.com/v1/images/generations' -and $config.Host -ceq $config.Uri -and $config.Method -ceq 'Post') 'generation endpoint'
Assert ($config.Headers.Authorization -ceq 'Bearer dummy-A' -and $config.Headers.'Content-Type' -ceq 'application/json' -and $config.SkipBearerToken -eq $true) 'registered bearer auth'
Assert (($config.Body|ConvertTo-Json -Depth 100 -Compress) -ceq ($plan.Config.Prompt|ConvertTo-Json -Depth 100 -Compress)) 'provider-native body changed'
Assert (($plan|ConvertTo-Json -Depth 20 -Compress) -ceq $before) 'caller Plan changed'
$editPrompt=[pscustomobject]@{model='fixture-image-edit';prompt='edit exactly';n=3;size='auto';output_format='webp';images=@([pscustomobject]@{image_url='https://example.test/image.png'},[pscustomobject]@{file_id='file_fixture'})}
$edit=Plan 'ArtEdit' $editPrompt
$r=$b.Invoke('OpenAI','SendMessage',$signal,$edit,$signal)
Assert (-not $r.Failure() -and $global:ImageRestRequest.Plan.Config.Uri -ceq 'https://api.openai.com/v1/images/edits' -and
    $global:ImageRestRequest.Plan.Config.Headers.Authorization -ceq 'Bearer dummy-B') 'edit route/resource isolation'
Assert (($global:ImageRestRequest.Plan.Config.Body|ConvertTo-Json -Depth 100 -Compress) -ceq ($editPrompt|ConvertTo-Json -Depth 100 -Compress)) 'edit body changed'
$editPrompt.images=@([pscustomobject]@{file_id='file_fixture'})
$r=$b.Invoke('OpenAI','SendMessage',$signal,$edit,$signal)
Assert (-not $r.Failure() -and $global:ImageRestRequest.Plan.Config.Body.images[0].file_id -ceq 'file_fixture') 'file ID edit'
$editPrompt.images=@([pscustomobject]@{file_id='file-abc123'})
$r=$b.Invoke('OpenAI','SendMessage',$signal,$edit,$signal)
Assert (-not $r.Failure() -and $global:ImageRestRequest.Plan.Config.Body.images[0].file_id -ceq 'file-abc123') 'documented file ID edit'
$calls=$global:ImageRestCalls
$removed=$a.Invoke('OpenAI','SendMessageOriginal',$signal,$plan,$signal)
Assert ($removed.Failure() -and -not $removed.HasResult() -and $global:ImageRestCalls -eq $calls -and $global:ImageTextCalls -eq $textCalls) 'removed original image activity dispatched'
foreach($field in @('ModelKey','Content','FormattedPrompt','BearerToken','Querystring','SourcePath','Form','ContentType','ReturnHttpStatus','Method','Host','Uri','Headers','Body','CacheAccessToken','SkipBearerToken','TargetPath')) {
    $bad=Plan
    $bad.Config|Add-Member -NotePropertyName $field -NotePropertyValue 'caller override'
    Assert ($a.Invoke('OpenAI','SendMessage',$signal,$bad,$signal).Failure() -and $global:ImageRestCalls -eq $calls) "REST override dispatched: $field"
}
foreach($bad in @(
    (Plan 'missing'),
    (Plan 'ArtGenerate' ([pscustomobject]@{model='wrong';prompt='p'}))
)) { Assert ($a.Invoke('OpenAI','SendMessage',$signal,$bad,$signal).Failure() -and $global:ImageRestCalls -eq $calls) 'invalid profile/body dispatched' }
$bad=Plan;$bad.Config.Profile|Add-Member -NotePropertyName Uri -NotePropertyValue 'https://attacker.test'
Assert ($a.Invoke('OpenAI','SendMessage',$signal,$bad,$signal).Failure() -and $global:ImageRestCalls -eq $calls) 'profile override dispatched'
$bad=Plan;$bad.Config=@($bad.Config)
Assert ($a.Invoke('OpenAI','SendMessage',$signal,$bad,$signal).Failure() -and $global:ImageRestCalls -eq $calls) 'singleton Config array dispatched'
$bad=Plan;$bad.Config.Profile=@($bad.Config.Profile)
Assert ($a.Invoke('OpenAI','SendMessage',$signal,$bad,$signal).Failure() -and $global:ImageRestCalls -eq $calls) 'singleton Profile array dispatched'
$bad=Plan;$bad.Config.Prompt=@($bad.Config.Prompt)
Assert ($a.Invoke('OpenAI','SendMessage',$signal,$bad,$signal).Failure() -and $global:ImageRestCalls -eq $calls) 'singleton Prompt array dispatched'
$bad=Plan;$bad.Config.Prompt.model=@('fixture-image-generation')
Assert ($a.Invoke('OpenAI','SendMessage',$signal,$bad,$signal).Failure() -and $global:ImageRestCalls -eq $calls) 'array model dispatched'
$minimal=Plan 'ArtGenerate' ([pscustomobject]@{model='fixture-image-generation';prompt='minimal'})
Assert (-not $a.Invoke('OpenAI','SendMessage',$signal,$minimal,$signal).Failure()) 'omitted options rejected'
Assert (($global:ImageRestRequest.Plan.Config.Body|ConvertTo-Json -Depth 100 -Compress) -ceq ($minimal.Config.Prompt|ConvertTo-Json -Depth 100 -Compress)) 'omitted options added'
$calls=$global:ImageRestCalls
$bad=Plan;$bad.Config.Prompt|Add-Member -NotePropertyName stream -NotePropertyValue @($false)
Assert ($a.Invoke('OpenAI','SendMessage',$signal,$bad,$signal).Failure() -and $global:ImageRestCalls -eq $calls) 'singleton stream array dispatched'
foreach($native in @(
    ([pscustomobject]@{model='fixture-image-edit';prompt='p';images=@([pscustomobject]@{image_url='file:///local.png'})}),
    ([pscustomobject]@{model='fixture-image-edit';prompt='p';images=@([pscustomobject]@{file_id=@('file-abc123')})}),
    ([pscustomobject]@{model='fixture-image-edit';prompt='p';images=@([pscustomobject]@{image_url='https://user:secret@example.test/image.png';file_id='bad'})}),
    ([pscustomobject]@{model='fixture-image-edit';prompt='p';images=$null}),
    ([pscustomobject]@{model='fixture-image-edit';prompt='p';images=@([pscustomobject]@{file_id=''})})
)) {
    $edit=Plan 'ArtEdit' $native
    $before=$edit.Config.Prompt|ConvertTo-Json -Depth 100 -Compress
    $previous=$global:ImageRestCalls
    Assert (-not $a.Invoke('OpenAI','SendMessage',$signal,$edit,$signal).Failure() -and $global:ImageRestCalls -eq ($previous+1)) 'native edit payload rejected before REST'
    Assert (($global:ImageRestRequest.Plan.Config.Body|ConvertTo-Json -Depth 100 -Compress) -ceq $before) 'native edit body changed'
    Assert (($edit.Config.Prompt|ConvertTo-Json -Depth 100 -Compress) -ceq $before) 'caller edit prompt changed'
}
$global:ImageRestFail=$true
Assert ($a.Invoke('OpenAI','SendMessage',$signal,$plan,$signal).Failure()) 'REST failure not propagated'
$global:ImageRestFail=$false
$duplicate=Jacket 'dummy';$duplicate.Routes[2].Key='generate'
Assert ((Resolve-Intelligence_OpenAI).Construct($duplicate).Failure()) 'duplicate route accepted'
$missing=Jacket 'dummy';$missing.Profiles[1].RouteKey='absent'
Assert ((Resolve-Intelligence_OpenAI).Construct($missing).Failure()) 'missing route accepted'
$duplicateResource=Jacket 'dummy';$duplicateResource.Resource+=([pscustomobject]@{Key='openai';Credentials='other'})
Assert ((Resolve-Intelligence_OpenAI).Construct($duplicateResource).Failure()) 'duplicate resource accepted'
$alternate=Jacket 'dummy-C'
$alternate.Profiles[1].Key='SolarCanvas';$alternate.Profiles[1].Model='solar-model'
$alternate.Profiles[2].Key='SolarRetouch';$alternate.Profiles[2].Model='solar-edit-model'
$c=Resolve-Intelligence_OpenAI
Assert (-not $c.Construct($alternate).Failure()) 'alternate registration rejected'
$alternatePlan=Plan 'SolarCanvas' ([pscustomobject]@{model='solar-model';prompt='native alternate';n=4})
Assert (-not $c.Invoke('OpenAI','SendMessage',$signal,$alternatePlan,$signal).Failure() -and
    $global:ImageRestRequest.Plan.Config.Uri -ceq 'https://api.openai.com/v1/images/generations' -and
    $global:ImageRestRequest.Plan.Config.Headers.Authorization -ceq 'Bearer dummy-C') 'alternate registration generation binding'
$alternateEdit=Plan 'SolarRetouch' ([pscustomobject]@{model='solar-edit-model';prompt='retouch';images=@([pscustomobject]@{file_id='file-1'},[pscustomobject]@{image_url='https://example.test/2.png'})})
Assert (-not $c.Invoke('OpenAI','SendMessage',$signal,$alternateEdit,$signal).Failure() -and
    $global:ImageRestRequest.Plan.Config.Uri -ceq 'https://api.openai.com/v1/images/edits' -and
    $global:ImageRestRequest.Plan.Config.Body.images.Count -eq 2) 'alternate registration edit binding'
$actualRest=& $module {
    param($request,$context)
    & (Get-Module SovereignTrust.Foundation) {
        param($request,$context)
        Set-Item Function:script:Invoke-RestMethod -Value {
            param($Uri,$Method,$Headers,$Body)
            $global:ActualRestBody=$Body
            [pscustomobject]@{data=@([pscustomobject]@{b64_json='offline'})}
        }
        Invoke-RestCondenserCore -RestCondenser $null -Activity 'POST' -Slot '' -Signal $context -ItemSignal $context -Plan $request | Select-Object -Last 1
    } $request $context
} $restPlan $signal
Assert (-not $actualRest.Failure() -and ($global:ActualRestBody|ConvertFrom-Json|ConvertTo-Json -Depth 100 -Compress) -ceq
    ($plan.Config.Prompt|ConvertTo-Json -Depth 100 -Compress)) 'actual REST serialization changed native body'
$calls=$global:ImageRestCalls
foreach($change in @('auth','origin','path','resource','profile')) {
    $invalid=Jacket 'dummy'
    switch($change) {
        'auth' {$invalid.Routes[1].AuthMode='None'}
        'origin' {$invalid.Routes[1].Address='https://attacker.test/v1/images/generations'}
        'path' {$invalid.Routes[1].Address='https://api.openai.com/v1/images/edits'}
        'resource' {$invalid.Routes[1].ResourceKey='absent'}
        'profile' {$invalid.Profiles[2].Key=$invalid.Profiles[1].Key}
    }
    Assert ((Resolve-Intelligence_OpenAI).Construct($invalid).Failure()) "invalid registration accepted: $change"
}
$bad=Plan;$bad.Config.Prompt|Add-Member -NotePropertyName stream -NotePropertyValue $true
Assert ($a.Invoke('OpenAI','SendMessage',$signal,$bad,$signal).Failure() -and $global:ImageRestCalls -eq $calls) 'stream true dispatched'
$bad=Plan;$bad.Config.Prompt|Add-Member -NotePropertyName stream -NotePropertyValue $null
Assert ($a.Invoke('OpenAI','SendMessage',$signal,$bad,$signal).Failure() -and $global:ImageRestCalls -eq $calls) 'null stream dispatched'
$oversize=Plan 'ArtGenerate' ([pscustomobject]@{model='fixture-image-generation';items=([int[]]::new(260000))})
$compact=$oversize.Config.Prompt|ConvertTo-Json -Depth 100 -Compress
$expanded=$oversize.Config.Prompt|ConvertTo-Json -Depth 100
Assert ([Text.Encoding]::UTF8.GetByteCount($compact) -lt 1MB -and [Text.Encoding]::UTF8.GetByteCount($expanded) -gt 1MB) 'size fixture does not straddle boundary'
Assert ($a.Invoke('OpenAI','SendMessage',$signal,$oversize,$signal).Failure() -and $global:ImageRestCalls -eq $calls) 'REST-sized body dispatched'
$nested=[pscustomobject]@{value='leaf'}
for($i=0;$i -lt 105;$i++) { $nested=[pscustomobject]@{next=$nested} }
$deep=Plan 'ArtGenerate' ([pscustomobject]@{model='fixture-image-generation';options=$nested})
Assert ($a.Invoke('OpenAI','SendMessage',$signal,$deep,$signal).Failure() -and $global:ImageRestCalls -eq $calls) 'depth overflow dispatched'
'OpenAI REST image send fixture: PASS'
