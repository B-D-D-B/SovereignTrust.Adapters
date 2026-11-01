using module SignalGraph
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '../Src/Intelligence/OpenAI/PowerShell/Intelligence_OpenAI.psd1') -Force
Import-Module (Join-Path $PSScriptRoot '../../SovereignTrust.Foundation/Src/PowerShell/SovereignTrust.Foundation.psd1') -Force
function Assert([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }

$jacket = [pscustomobject]@{
    ApiKind='OpenAIResponses'; DefaultModelKey='default'
    Profiles=@([pscustomobject]@{ ModelKey='default'; Model='fixture-model'; MaxOutputTokens=256 },
        [pscustomobject]@{ ModelKey='other'; Model='fixture-other'; ReasoningEffort='low' })
    Resource=@('dummy-native-key'); Addresses=@('https://api.openai.com/v1/responses')
}
$adapter = Resolve-Intelligence_OpenAI
Assert (-not $adapter.Construct($jacket).Failure()) 'valid jacket rejected'
$signal = [Signal]::Start('fixture') | Select-Object -Last 1
$global:OpenAIHttpCalls = 0
& (Get-Module -All Intelligence_OpenAI | Select-Object -Last 1) {
    Set-Item Function:script:Invoke-WebRequest -Value {
        param($Uri,$Method,$Headers,$Body,$ContentType,$MaximumRetryCount,$MaximumRedirection,$ConnectionTimeoutSeconds,$OperationTimeoutSeconds,[switch]$SkipHttpErrorCheck,$ErrorAction,$Verbose,$Debug,$WarningAction)
        $global:OpenAIHttpCalls++
        $global:OpenAIRequest = [pscustomobject]@{Uri=$Uri;Method=$Method;Headers=$Headers;Body=$Body;Retry=$MaximumRetryCount;Redirect=$MaximumRedirection;Connect=$ConnectionTimeoutSeconds;Operation=$OperationTimeoutSeconds;Skip=$SkipHttpErrorCheck.IsPresent}
        return [pscustomobject]@{ StatusCode=200; Content='{"status":"completed","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"fixture answer"}]}]}' }
    }
}
$plan = [pscustomobject]@{ Config=[pscustomobject]@{ Prompt=[pscustomobject]@{System='system';Texts=@('hello');Media=@()} } }
$planBefore=$plan | ConvertTo-Json -Depth 30 -Compress
$result = $adapter.Invoke('OpenAI','SendMessage',$signal,$plan,$signal)
Assert (-not $result.Failure() -and $result.HasResult()) 'valid response rejected'
Assert (($result.GetResult() | ConvertFrom-Json).choices[0].message.content -ceq 'fixture answer') 'normalized content differs'
Assert ($global:OpenAIHttpCalls -eq 1 -and $global:OpenAIRequest.Uri -ceq 'https://api.openai.com/v1/responses' -and $global:OpenAIRequest.Method -ceq 'Post') 'native endpoint/count differs'
Assert ($global:OpenAIRequest.Headers.Authorization -ceq 'Bearer dummy-native-key' -and -not $global:OpenAIRequest.Headers.ContainsKey('api-key')) 'native authentication differs'
Assert ($global:OpenAIRequest.Retry -eq 0 -and $global:OpenAIRequest.Redirect -eq 0 -and $global:OpenAIRequest.Connect -eq 30 -and $global:OpenAIRequest.Operation -eq 60 -and $global:OpenAIRequest.Skip) 'transport controls differ'
$body = $global:OpenAIRequest.Body | ConvertFrom-Json
Assert ($body.model -ceq 'fixture-model' -and $body.max_output_tokens -eq 256 -and $null -eq $body.reasoning) 'default profile differs'
Assert ($body.input[0].role -ceq 'system' -and $body.input[1].content[0].type -ceq 'input_text') 'request input differs'
Assert (($plan | ConvertTo-Json -Depth 30 -Compress) -ceq $planBefore) 'caller plan was mutated'
$jacket2=[pscustomobject]@{ApiKind='OpenAIResponses';DefaultModelKey='other';Profiles=@([pscustomobject]@{ModelKey='other';Model='second-model'});Resource=@('second-dummy-key');Addresses=@('https://api.openai.com/v1/responses')}
$adapter2=Resolve-Intelligence_OpenAI
Assert (-not $adapter2.Construct($jacket2).Failure()) 'second slot construction failed'
$second=$adapter2.Invoke('Second','SendMessage',$signal,$plan,$signal)
Assert (-not $second.Failure() -and $global:OpenAIRequest.Headers.Authorization -ceq 'Bearer second-dummy-key' -and
    ($global:OpenAIRequest.Body | ConvertFrom-Json).model -ceq 'second-model' -and
    $null -eq ($global:OpenAIRequest.Body | ConvertFrom-Json).max_output_tokens) 'second slot leaked first profile or key'
$firstAgain=$adapter.Invoke('OpenAI','SendMessage',$signal,$plan,$signal)
Assert (-not $firstAgain.Failure() -and $global:OpenAIRequest.Headers.Authorization -ceq 'Bearer dummy-native-key' -and
    ($global:OpenAIRequest.Body | ConvertFrom-Json).model -ceq 'fixture-model') 'first slot changed after second construction'
$plan.Config | Add-Member -NotePropertyName ModelKey -NotePropertyValue other
$original = $adapter.Invoke('OpenAI','SendMessageOriginal',$signal,$plan,$signal)
Assert (-not $original.Failure() -and ($global:OpenAIRequest.Body | ConvertFrom-Json).reasoning.effort -ceq 'low') 'explicit profile/original differs'
$plan.Config.ModelKey = 'unknown'; $before = $global:OpenAIHttpCalls
Assert ($adapter.Invoke('OpenAI','SendMessage',$signal,$plan,$signal).Failure() -and $global:OpenAIHttpCalls -eq $before) 'unknown profile sent HTTP'
$plan.Config.ModelKey = 'default'
& (Get-Module -All Intelligence_OpenAI | Select-Object -Last 1) {
    Set-Item Function:script:Invoke-WebRequest -Value {
        param($Uri,$Method,$Headers,$Body,$ContentType,$MaximumRetryCount,$MaximumRedirection,$ConnectionTimeoutSeconds,$OperationTimeoutSeconds,[switch]$SkipHttpErrorCheck,$ErrorAction,$Verbose,$Debug,$WarningAction)
        $global:OpenAIHttpCalls++
        return [pscustomobject]@{ StatusCode=429; Content='secret-sentinel' }
    }
}
$failed = $adapter.Invoke('OpenAI','SendMessage',$signal,$plan,$signal)
Assert ($failed.Failure() -and -not $failed.HasResult() -and $global:OpenAIHttpCalls -eq ($before + 1)) '429 failure/count differs'
Assert (-not (($failed.Entries | Out-String) -match 'secret-sentinel|dummy-native-key')) 'failure diagnostic leaked content'
$bad = [pscustomobject]@{ApiKind='OpenAIResponses';DefaultModelKey='default';Profiles=$jacket.Profiles;Resource=@('dummy');Addresses=@('https://azure.example/openai/v1/responses')}
Assert ((Resolve-Intelligence_OpenAI).Construct($bad).Failure()) 'non-native address accepted'
foreach($badJacket in @(
    [pscustomobject]@{ApiKind='Azure';DefaultModelKey='default';Profiles=$jacket.Profiles;Resource=@('dummy');Addresses=$jacket.Addresses},
    [pscustomobject]@{ApiKind='OpenAIResponses';DefaultModelKey='default';Profiles=$jacket.Profiles;Resource=@();Addresses=$jacket.Addresses},
    [pscustomobject]@{ApiKind='OpenAIResponses';DefaultModelKey='default';Profiles=$jacket.Profiles;Resource=@('dummy');Addresses=@('https://api.openai.com/v1/responses?x=1')},
    [pscustomobject]@{ApiKind='OpenAIResponses';DefaultModelKey='missing';Profiles=$jacket.Profiles;Resource=@('dummy');Addresses=$jacket.Addresses},
    [pscustomobject]@{ApiKind='OpenAIResponses';DefaultModelKey='default';Profiles=@($jacket.Profiles[0],$jacket.Profiles[0]);Resource=@('dummy');Addresses=$jacket.Addresses}
)) { Assert ((Resolve-Intelligence_OpenAI).Construct($badJacket).Failure()) 'invalid jacket/profile accepted' }
$before=$global:OpenAIHttpCalls
Assert ($adapter.Invoke('OpenAI','Delete',$signal,$plan,$signal).Failure() -and $global:OpenAIHttpCalls -eq $before) 'unsupported activity sent HTTP'
$plan.Config | Add-Member -NotePropertyName Model -NotePropertyValue 'forbidden-override'
Assert ($adapter.Invoke('OpenAI','SendMessage',$signal,$plan,$signal).Failure() -and $global:OpenAIHttpCalls -eq $before) 'Config.Model override sent HTTP'
$plan.Config.PSObject.Properties.Remove('Model')
$plan.Config | Add-Member -NotePropertyName Content -NotePropertyValue 'ambiguous'
Assert ($adapter.Invoke('OpenAI','SendMessage',$signal,$plan,$signal).Failure() -and $global:OpenAIHttpCalls -eq $before) 'ambiguous prompt/content sent HTTP'
$plan.Config.PSObject.Properties.Remove('Content')
$item=[Signal]::Start('item') | Select-Object -Last 1
$item.SetResult('chosen') | Out-Null
$handled=$adapter.Invoke('OpenAI','HandleMessage',$signal,[pscustomobject]@{Path='@'},$item)
Assert (-not $handled.Failure() -and $handled.HasResult() -and $handled.GetResult() -ceq 'chosen') 'HandleMessage native selection differs'
$emptyItem=[Signal]::Start('empty-item') | Select-Object -Last 1
$emptyHandled=$adapter.Invoke('OpenAI','HandleMessage',$signal,[pscustomobject]@{Path='@'},$emptyItem)
Assert (-not $emptyHandled.Failure() -and -not $emptyHandled.HasResult()) 'HandleMessage empty Signal result differs'
$badHandle=$adapter.Invoke('OpenAI','HandleMessage',$signal,[pscustomobject]@{Path='not-present'},$item)
Assert ($badHandle.Failure() -and -not $badHandle.HasResult()) 'HandleMessage missing path accepted'
& (Get-Module -All Intelligence_OpenAI | Select-Object -Last 1) {
    Set-Item Function:script:Invoke-CondenserAdapter -Value {
        param($Slot,$Activity,$Plan,$Signal,$ItemSignal)
        $r=[Signal]::Start('format-fixture') | Select-Object -Last 1
        $r.SetResult([pscustomobject]@{Selected='chosen'}) | Out-Null
        return $r
    }
}
$formatted=$adapter.Invoke('OpenAI','HandleMessage',$signal,[pscustomobject]@{Path='@';Format='Json'},$item)
Assert (-not $formatted.Failure() -and $formatted.GetResult().Selected -ceq 'chosen') 'HandleMessage format result differs'
& (Get-Module -All Intelligence_OpenAI | Select-Object -Last 1) {
    Set-Item Function:script:Invoke-CondenserAdapter -Value {
        param($Slot,$Activity,$Plan,$Signal,$ItemSignal)
        $r=[Signal]::Start('format-failed') | Select-Object -Last 1
        $null=$r.LogCritical('fixture failure')
        return $r
    }
}
$formatFailed=$adapter.Invoke('OpenAI','HandleMessage',$signal,[pscustomobject]@{Path='@';Format='Json'},$item)
Assert ($formatFailed.Failure() -and -not $formatFailed.HasResult()) 'HandleMessage format failure accepted'
& (Get-Module -All Intelligence_OpenAI | Select-Object -Last 1) { Remove-Item Function:Invoke-CondenserAdapter -Force -ErrorAction SilentlyContinue }
$plan.Config.Prompt.Media = @([pscustomobject]@{MediaType='image';MediaUrl='https://example.org/red.png';Detail='high'})
& (Get-Module -All Intelligence_OpenAI | Select-Object -Last 1) {
    Set-Item Function:script:Invoke-WebRequest -Value {
        param($Uri,$Method,$Headers,$Body,$ContentType,$MaximumRetryCount,$MaximumRedirection,$ConnectionTimeoutSeconds,$OperationTimeoutSeconds,[switch]$SkipHttpErrorCheck,$ErrorAction,$Verbose,$Debug,$WarningAction)
        $global:OpenAIHttpCalls++
        $global:OpenAIRequest = [pscustomobject]@{Body=$Body}
        return [pscustomobject]@{StatusCode=200;Content='{"status":"completed","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"RED"}]}]}' }
    }
}
$image = $adapter.Invoke('OpenAI','SendMessage',$signal,$plan,$signal)
Assert (-not $image.Failure() -and ($global:OpenAIRequest.Body | ConvertFrom-Json).input[1].content[1].image_url -ceq 'https://example.org/red.png') 'image URL mapping differs'
$plan.Config.Prompt.Media[0].MediaUrl = 'http://example.org/red.png'; $before=$global:OpenAIHttpCalls
Assert ($adapter.Invoke('OpenAI','SendMessage',$signal,$plan,$signal).Failure() -and $global:OpenAIHttpCalls -eq $before) 'invalid image URL sent HTTP'
$mediaFile=Join-Path ([IO.Path]::GetTempPath()) ("openai-test-$([guid]::NewGuid()).png")
try {
    [IO.File]::WriteAllBytes($mediaFile,[Convert]::FromBase64String('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII='))
    $plan.Config.Prompt.Media=@([pscustomobject]@{MediaType='image';MediaPath=$mediaFile})
    $local=$adapter.Invoke('OpenAI','SendMessage',$signal,$plan,$signal)
    Assert (-not $local.Failure() -and ($global:OpenAIRequest.Body | ConvertFrom-Json).input[1].content[1].image_url.StartsWith('data:image/png;base64,')) 'local PNG data URL differs'
    [IO.File]::WriteAllBytes($mediaFile,[byte[]](0x47,0x49,0x46,0x38))
    $before=$global:OpenAIHttpCalls
    Assert ($adapter.Invoke('OpenAI','SendMessage',$signal,$plan,$signal).Failure() -and $global:OpenAIHttpCalls -eq $before) 'bad signature sent HTTP'
    $plan.Config.Prompt.Media=@(1..11 | ForEach-Object { [pscustomobject]@{MediaType='image';MediaUrl='https://example.org/red.png'} })
    Assert ($adapter.Invoke('OpenAI','SendMessage',$signal,$plan,$signal).Failure() -and $global:OpenAIHttpCalls -eq $before) '11 images sent HTTP'
    $plan.Config.Prompt.Media=@(1..10 | ForEach-Object { [pscustomobject]@{MediaType='image';MediaUrl='https://example.org/red.png'} })
    Assert (-not $adapter.Invoke('OpenAI','SendMessage',$signal,$plan,$signal).Failure() -and $global:OpenAIHttpCalls -eq $before+1) '10 images rejected'
    $before=$global:OpenAIHttpCalls
    $large=[byte[]]::new(10MB+1)
    [Array]::Copy([byte[]]@(0x89,0x50,0x4E,0x47,0x0D,0x0A,0x1A,0x0A),$large,8)
    [IO.File]::WriteAllBytes($mediaFile,$large)
    $plan.Config.Prompt.Media=@([pscustomobject]@{MediaType='image';MediaPath=$mediaFile})
    Assert ($adapter.Invoke('OpenAI','SendMessage',$signal,$plan,$signal).Failure() -and $global:OpenAIHttpCalls -eq $before) 'over 10 MiB image sent HTTP'
    [Array]::Resize([ref]$large,10MB)
    [IO.File]::WriteAllBytes($mediaFile,$large)
    Assert (-not $adapter.Invoke('OpenAI','SendMessage',$signal,$plan,$signal).Failure() -and $global:OpenAIHttpCalls -eq $before+1) 'exactly 10 MiB image rejected'
    $before=$global:OpenAIHttpCalls
    [Array]::Resize([ref]$large,8MB)
    [IO.File]::WriteAllBytes($mediaFile,$large)
    $plan.Config.Prompt.Media=@([pscustomobject]@{MediaType='image';MediaPath=$mediaFile},[pscustomobject]@{MediaType='image';MediaPath=$mediaFile})
    Assert ($adapter.Invoke('OpenAI','SendMessage',$signal,$plan,$signal).Failure() -and $global:OpenAIHttpCalls -eq $before) 'over 20 MiB aggregate request sent HTTP'
    $gifPath=[IO.Path]::ChangeExtension($mediaFile,'.gif')
    $frame=[byte[]]@(0x2C,0,0,0,0,1,0,1,0,0,2,1,0,0)
    $gif=[byte[]]@(0x47,0x49,0x46,0x38,0x39,0x61,1,0,1,0,0,0,0)+$frame+[byte[]]@(0x3B)
    [IO.File]::WriteAllBytes($gifPath,$gif)
    $plan.Config.Prompt.Media=@([pscustomobject]@{MediaType='image';MediaPath=$gifPath})
    Assert (-not $adapter.Invoke('OpenAI','SendMessage',$signal,$plan,$signal).Failure()) 'static GIF rejected'
    [IO.File]::WriteAllBytes($gifPath,([byte[]]@(0x47,0x49,0x46,0x38,0x39,0x61,1,0,1,0,0,0,0)+$frame+$frame+[byte[]]@(0x3B)))
    $before=$global:OpenAIHttpCalls
    Assert ($adapter.Invoke('OpenAI','SendMessage',$signal,$plan,$signal).Failure() -and $global:OpenAIHttpCalls -eq $before) 'animated GIF sent HTTP'
} finally { Remove-Item -LiteralPath $mediaFile -ErrorAction SilentlyContinue; if($gifPath){Remove-Item -LiteralPath $gifPath -ErrorAction SilentlyContinue} }
$plan.Config.Prompt.Media=@(); $plan.Config.Prompt.Texts=@('hello')
foreach($payload in @(
    '{"status":"incomplete","output":[]}',
    '{"status":"completed","output":[{"type":"message","role":"assistant","content":[{"type":"refusal","refusal":"no"}]}]}',
    '{"status":"completed","output":[]}',
    '{invalid-json'
)) {
    & (Get-Module -All Intelligence_OpenAI | Select-Object -Last 1) {
        param($content)
        $global:OpenAIFixtureContent=$content
        Set-Item Function:script:Invoke-WebRequest -Value {
            param($Uri,$Method,$Headers,$Body,$ContentType,$MaximumRetryCount,$MaximumRedirection,$ConnectionTimeoutSeconds,$OperationTimeoutSeconds,[switch]$SkipHttpErrorCheck,$ErrorAction,$Verbose,$Debug,$WarningAction)
            $global:OpenAIHttpCalls++
            return [pscustomobject]@{StatusCode=200;Content=$global:OpenAIFixtureContent}
        }
    } $payload
    $before=$global:OpenAIHttpCalls
    $failure=$adapter.Invoke('OpenAI','SendMessage',$signal,$plan,$signal)
    Assert ($failure.Failure() -and -not $failure.HasResult() -and $global:OpenAIHttpCalls -eq $before+1) 'invalid provider envelope accepted'
}
& (Get-Module -All Intelligence_OpenAI | Select-Object -Last 1) {
    Set-Item Function:script:Invoke-WebRequest -Value {
        param($Uri,$Method,$Headers,$Body,$ContentType,$MaximumRetryCount,$MaximumRedirection,$ConnectionTimeoutSeconds,$OperationTimeoutSeconds,[switch]$SkipHttpErrorCheck,$ErrorAction,$Verbose,$Debug,$WarningAction)
        $global:OpenAIHttpCalls++
        throw 'transport-sentinel dummy-native-key'
    }
}
$before=$global:OpenAIHttpCalls
$captured=@($adapter.Invoke('OpenAI','SendMessage',$signal,$plan,$signal) 6>&1 5>&1 4>&1 3>&1 2>&1)
$transportFailure=@($captured | Where-Object {$_ -is [Signal]}) | Select-Object -Last 1
Assert ($transportFailure.Failure() -and -not $transportFailure.HasResult() -and $global:OpenAIHttpCalls -eq $before+1 -and
    -not (($captured | Out-String) -match 'transport-sentinel|dummy-native-key') -and
    -not (($transportFailure.Entries | Out-String) -match 'transport-sentinel|dummy-native-key')) 'thrown transport error leaked or retried'
& (Get-Module -All Intelligence_OpenAI | Select-Object -Last 1) { Remove-Item Function:Invoke-WebRequest -Force -ErrorAction SilentlyContinue }
Assert ((& (Get-Module -All Intelligence_OpenAI | Select-Object -Last 1) { (Get-Command Invoke-WebRequest).CommandType }) -eq 'Cmdlet') 'HTTP stub remained active'
$portProbe = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0)
$portProbe.Start(); $port=$portProbe.LocalEndpoint.Port; $portProbe.Stop()
$prefix = "http://127.0.0.1:$port/"
$listener = Start-ThreadJob -ArgumentList $prefix -ScriptBlock {
    param($prefix)
    $server=[Net.HttpListener]::new(); $server.Prefixes.Add($prefix); $server.Start()
    try {
        $first=$server.GetContext()
        $first.Response.StatusCode=429
        $bytes=[Text.Encoding]::UTF8.GetBytes('rate-limited-sentinel')
        $first.Response.OutputStream.Write($bytes,0,$bytes.Length)
        $first.Response.Close()
        $second=$server.GetContextAsync()
        $followed=$second.Wait(1500)
        if($followed){$second.Result.Response.StatusCode=200;$second.Result.Response.Close()}
        [pscustomobject]@{Count=(1+[int]$followed)}
    } finally {$server.Stop();$server.Close()}
}
Start-Sleep -Milliseconds 150
$settings=[pscustomobject]@{Address=$prefix;Credential='dummy-loopback-key';DefaultModelKey='default';Profiles=$adapter.Settings.Profiles}
$loopback=& (Get-Module -All Intelligence_OpenAI | Select-Object -Last 1) {param($st,$pl,$sg) Invoke-OpenAIResponses -Settings $st -Plan $pl -ConductionSignal $sg | Select-Object -Last 1} $settings $plan $signal
$completed=Wait-Job $listener -Timeout 5
if(-not $completed){Stop-Job $listener;throw 'Loopback listener received no request.'}
$listenerResult=Receive-Job $listener -Wait -AutoRemoveJob
Assert ($loopback.Failure() -and -not $loopback.HasResult() -and $listenerResult.Count -eq 1) 'real HTTP 429 retried or succeeded'
Assert (-not (($loopback.Entries | Out-String) -match 'rate-limited-sentinel|dummy-loopback-key')) 'real HTTP diagnostic leaked content'
function Invoke-LoopbackCase([int]$Status,[int]$DelaySeconds=0) {
    $probe=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0)
    $probe.Start();$port=$probe.LocalEndpoint.Port;$probe.Stop()
    $address="http://127.0.0.1:$port/"
    $job=Start-ThreadJob -ArgumentList $address,$Status,$DelaySeconds -ScriptBlock {
        param($address,$status,$delay)
        $server=[Net.HttpListener]::new();$server.Prefixes.Add($address);$server.Start()
        try {
            $first=$server.GetContext();$count=1
            if($delay){Start-Sleep -Seconds $delay}
            try {
                $first.Response.StatusCode=$status
                if($status -eq 302){$first.Response.RedirectLocation=$address}
                $content=if($status -eq 200){'{"status":"completed","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"one"},{"type":"output_text","text":"two"}]}]}'}else{'provider-sentinel'}
                $bytes=[Text.Encoding]::UTF8.GetBytes($content)
                $first.Response.OutputStream.Write($bytes,0,$bytes.Length)
                $first.Response.Close()
            } catch {}
            $next=$server.GetContextAsync();$followed=$next.Wait(1200)
            if($followed){$count++;$next.Result.Response.StatusCode=200;$next.Result.Response.Close()}
            return $count
        } finally {$server.Stop();$server.Close()}
    }
    Start-Sleep -Milliseconds 150
    $localSettings=[pscustomobject]@{Address=$address;Credential='dummy-loopback-key';DefaultModelKey='default';Profiles=$adapter.Settings.Profiles}
    $out=& (Get-Module -All Intelligence_OpenAI | Select-Object -Last 1) {param($st,$pl,$sg,$timeout) if($timeout){Invoke-OpenAIResponses -Settings $st -Plan $pl -ConductionSignal $sg -FixtureTimeoutSeconds $timeout | Select-Object -Last 1}else{Invoke-OpenAIResponses -Settings $st -Plan $pl -ConductionSignal $sg | Select-Object -Last 1}} $localSettings $plan $signal $(if($DelaySeconds){1}else{0})
    if(-not (Wait-Job $job -Timeout 5)){Stop-Job $job;throw 'Loopback fixture received no request.'}
    $count=Receive-Job $job -Wait -AutoRemoveJob
    return [pscustomobject]@{Signal=$out;Count=$count}
}
$successCase=Invoke-LoopbackCase 200
Assert (-not $successCase.Signal.Failure() -and $successCase.Count -eq 1 -and
    ($successCase.Signal.GetResult() | ConvertFrom-Json).choices[0].message.content -ceq "one`ntwo") 'real HTTP success/order differs'
foreach($status in @(500,302)) {
    $case=Invoke-LoopbackCase $status
    Assert ($case.Signal.Failure() -and -not $case.Signal.HasResult() -and $case.Count -eq 1 -and
        -not (($case.Signal.Entries | Out-String) -match 'provider-sentinel|dummy-loopback-key')) "real HTTP $status retry/redirect/leak differs"
}
$timeoutCase=Invoke-LoopbackCase 200 2
Assert ($timeoutCase.Signal.Failure() -and -not $timeoutCase.Signal.HasResult() -and $timeoutCase.Count -eq 1) 'real HTTP timeout/retry differs'
$bootstrap=[Signal]::Start('OpenAI.Mapped.Bootstrap') | Select-Object -Last 1
$bootstrap.SetResult([pscustomobject]@{}) | Out-Null
$conductorSignal=New-Conductor -HostConductor $null -ConductionSignal $bootstrap | Select-Object -Last 1
Assert (-not $conductorSignal.Failure() -and $conductorSignal.HasResult()) 'mapped conductor construction failed'
$conductor=$conductorSignal.GetResult()
$control=[Signal]::Start('OpenAI.Mapped.Control') | Select-Object -Last 1
$control.SetJacket($conductor.Signal) | Out-Null
$control.SetPointer($conductor.Signal.GetPointer()) | Out-Null
$mappedRun=[Signal]::Start('OpenAI.Mapped.Run') | Select-Object -Last 1
$mappedRun.SetControl($control) | Out-Null
$mappedRun.SetJacket($control) | Out-Null
$mappedRun.SetPointer($conductor.Signal.GetPointer()) | Out-Null
$mappedItem=[Signal]::Start('OpenAI.Mapped.Item') | Select-Object -Last 1
$mappedItem.SetPointer($conductor.Signal.GetPointer()) | Out-Null
$mappedItem.SetResult('mapped-value') | Out-Null
$moduleRoot=(Resolve-Path (Join-Path $PSScriptRoot '../..')).ProviderPath
$rootJacket=[pscustomobject]@{Kind='Storage';Slot='ModuleRoots';VirtualPath='SovereignTrust.Adapters.Storage.EmbeddedFileSystem.ModuleRoots.Persistent.Read';Addresses=@($moduleRoot)}
$moduleRootAdapter=& (Get-Module SovereignTrust.Foundation) { [Storage_EmbeddedFileSystem]::new() }
Assert (-not $moduleRootAdapter.Construct($rootJacket).Failure()) 'ModuleRoots construction failed'
$rootRegistration=Register-AdapterToMappedSlot -ConductorJacketSignal $conductor.Signal -Signal $mappedRun -ConductionContext $conductor.Signal -Adapter $moduleRootAdapter | Select-Object -Last 1
Assert (-not $rootRegistration.Failure()) 'ModuleRoots registration failed'
$condenserRegistration=& (Get-Module SovereignTrust.Foundation) {
    param($conductorSignal)
    $resolved=Resolve-PathFromDictionary -Dictionary $conductorSignal -Path '*.#.Adapters.*.#.MappedCondenser.@' | Select-Object -Last 1
    if($resolved.Failure() -or -not $resolved.HasResult()){return $false}
    $mapped=$resolved.GetResult()
    foreach($name in @('Merge','Hydration')){
        $type="${name}Condenser"
        $r=$mapped.RegisterAdapter((New-Object $type),$name) | Select-Object -Last 1
        if($r.Failure()){return $false}
    }
    return $true
} $conductor.Signal
Assert $condenserRegistration 'Merge/Hydration registration failed'
$nativeJacket=[Signal]::Start('OpenAI.Native.Jacket') | Select-Object -Last 1
$nativeJacket.SetResult([pscustomobject]@{Name='OpenAI';VirtualPath='SovereignTrust.Adapters.Intelligence.OpenAI.OpenAI.Persistent.Run';ApiKind='OpenAIResponses';DefaultModelKey='mapped';Profiles=@([pscustomobject]@{ModelKey='mapped';Model='mapped-model'});Resource=@('dummy-mapped-key');Addresses=@('https://api.openai.com/v1/responses')}) | Out-Null
$loaded=& (Get-Module SovereignTrust.Foundation) {param($run,$jacket) Resolve-AdapterFromJacket -Signal $run -ConductionContext $run -Jacket $jacket | Select-Object -Last 1} $mappedRun $nativeJacket
Assert (-not $loaded.Failure() -and $loaded.HasResult() -and $loaded.GetResult().GetType().Name -ceq 'Intelligence_OpenAI' -and $loaded.GetResult().Settings.Credential -ceq 'dummy-mapped-key') 'real module/jacket/merge/hydration loader failed'
$registration=& (Get-Module SovereignTrust.Foundation) {
    param($conductorSignal,$instance)
    $resolved=Resolve-PathFromDictionary -Dictionary $conductorSignal -Path '*.#.Adapters.*.#.MappedIntelligence.@' | Select-Object -Last 1
    if($resolved.Failure() -or -not $resolved.HasResult()){return $resolved}
    return $resolved.GetResult().RegisterAdapter($instance,'OpenAI') | Select-Object -Last 1
} $conductor.Signal $loaded.GetResult()
Assert (-not $registration.Failure()) 'loaded OpenAI instance mapped registration failed'
$mappedHandled=Invoke-MappedAdapter -Adapter 'Intelligence.OpenAI' -Activity 'HandleMessage' -Signal $mappedRun -Plan ([pscustomobject]@{Path='@'}) -ItemSignal $mappedItem | Select-Object -Last 1
Assert (-not $mappedHandled.Failure() -and $mappedHandled.HasResult() -and $mappedHandled.GetResult() -ceq 'mapped-value') 'real mapped HandleMessage route failed'
& (Get-Module -All Intelligence_OpenAI | Select-Object -Last 1) {
    Set-Item Function:script:Invoke-WebRequest -Value {
        param($Uri,$Method,$Headers,$Body,$ContentType,$MaximumRetryCount,$MaximumRedirection,$ConnectionTimeoutSeconds,$OperationTimeoutSeconds,[switch]$SkipHttpErrorCheck,$ErrorAction,$Verbose,$Debug,$WarningAction)
        $global:OpenAIHttpCalls++
        return [pscustomobject]@{StatusCode=200;Content='{"status":"completed","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"mapped answer"}]}]}' }
    }
}
$mappedPlan=[pscustomobject]@{Adapter='Intelligence.OpenAI';Activity='SendMessage';Config=[pscustomobject]@{Prompt=[pscustomobject]@{Texts=@('mapped prompt')}}}
$mappedSent=Invoke-MappedAdapter -Adapter $mappedPlan.Adapter -Activity $mappedPlan.Activity -Signal $mappedRun -Plan $mappedPlan -ItemSignal $mappedItem | Select-Object -Last 1
Assert (-not $mappedSent.Failure() -and $mappedSent.HasResult() -and ($mappedSent.GetResult() | ConvertFrom-Json).choices[0].message.content -ceq 'mapped answer') 'real mapped SendMessage route failed'
'OpenAI offline contract: PASS'
