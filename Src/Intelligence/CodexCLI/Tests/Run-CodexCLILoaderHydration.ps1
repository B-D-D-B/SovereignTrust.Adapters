using module SignalGraph

$ErrorActionPreference = 'Stop'
$foundationManifest = Join-Path $PSScriptRoot '../../../../../SovereignTrust.Foundation/Src/PowerShell/SovereignTrust.Foundation.psd1'
$adapterManifest = Join-Path $PSScriptRoot '../PowerShell/Intelligence_CodexCLI.psd1'
$fixtureExe = Join-Path $PSScriptRoot 'FixtureCli/out/FixtureCli.exe'
$workspace = Join-Path $PSScriptRoot 'FixtureWorkspace'
if (-not [IO.File]::Exists($fixtureExe)) { throw 'Build the offline fixture before loader checks.' }
Import-Module (Resolve-Path $foundationManifest).Path -Force
Import-Module $adapterManifest -Force
function Assert([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }

$foundation = Get-Module SovereignTrust.Foundation
$originalCondenser = & $foundation { (Get-Command Invoke-CondenserAdapter).ScriptBlock }
$global:CodexCLIHydrationCount = 0
& $foundation {
    Set-Item -Path Function:script:Resolve-DependencyModuleFromGraph -Value {
        param([Signal]$Signal, [object]$ConductionContext, [string]$WirePath)
        if ($WirePath -cnotin @(
            'SovereignTrust.Adapters.Intelligence.CodexCLI.CodexCLI.Persistent.Run',
            'SovereignTrust.Adapters.Intelligence.CodexCLI.AI.Persistent.Run')) { throw 'Unexpected CodexCLI loader wire path.' }
        return Resolve-ModulePathSignal -WirePath $WirePath
    }
    Set-Item -Path Function:script:Invoke-CondenserAdapter -Value {
        param([string]$Slot, [string]$Activity, [object]$Plan, [Signal]$Signal, [object]$ItemSignal)
        if ($Slot -cne 'Hydration' -or $Activity -cne 'Invoke' -or
            $Plan.HydrationStyle -cne 'Deferred' -or $Plan.Path -cne '%.@') { throw 'Unexpected loader hydration boundary.' }
        $global:CodexCLIHydrationCount++
        $merged = $ItemSignal.GetJacket().GetResult()
        if ($merged.CodexCLI.ApiKey -cne '[Storage.Secrets.Read.fixture-key|]') { throw 'Merged jacket lost deferred API key token.' }
        $hydrated = [pscustomobject]@{
            Name=$merged.Name; VirtualPath=$merged.VirtualPath; IsMapped=$merged.IsMapped
            DefaultModelKey=$merged.DefaultModelKey; Profiles=$merged.Profiles
            Kind='Intelligence'; Slot=$merged.Slot; HydrationMarker='synthetic-deferred'
            CodexCLI=[pscustomobject]@{
                ExecutablePath=$merged.CodexCLI.ExecutablePath; Workspace=$merged.CodexCLI.Workspace
                AuthenticationMode='ApiKey'; ApiKey='fixture-key'; TimeoutSeconds=3
            }
        }
        $result = [Signal]::Start('CodexCLI.Hydration') | Select-Object -Last 1
        $result.SetResult($hydrated) | Out-Null
        return $result
    }
}

$bootstrap = [Signal]::Start('CodexCLI.Loader.Bootstrap') | Select-Object -Last 1
$bootstrap.SetResult([pscustomobject]@{}) | Out-Null
$conductorResult = New-Conductor -HostConductor $null -ConductionSignal $bootstrap | Select-Object -Last 1
Assert (-not $conductorResult.Failure() -and $conductorResult.HasResult()) 'Loader conductor failed.'
$conductor = $conductorResult.GetResult()
$conductorJacket = [Signal]::Start('CodexCLI.Loader.Conductor') | Select-Object -Last 1
$conductorJacket.SetJacket($conductor.Signal) | Out-Null
$conductorJacket.SetPointer($conductor.Signal.GetPointer()) | Out-Null
$runSignal = [Signal]::Start('CodexCLI.Loader.Run') | Select-Object -Last 1
$runSignal.SetJacket($conductor.Signal) | Out-Null
$runSignal.SetControl($conductorJacket) | Out-Null
$runSignal.SetPointer($conductor.Signal.GetPointer()) | Out-Null
$itemSignal = [Signal]::Start('CodexCLI.Loader.Item') | Select-Object -Last 1
$itemSignal.SetPointer($conductor.Signal.GetPointer()) | Out-Null

foreach ($slot in @('CodexCLI','AI')) {
    $source = [pscustomobject]@{
        Name="CodexCLI$slot"; VirtualPath="SovereignTrust.Adapters.Intelligence.CodexCLI.$slot.Persistent.Run"
        IsMapped=$true; Kind='Intelligence'; Slot=$slot
        DefaultModelKey='fixture'; Profiles=@([pscustomobject]@{ ModelKey='fixture'; Model='fixture'; ReasoningEffort='medium' })
        CodexCLI=[pscustomobject]@{
            ExecutablePath=$fixtureExe; Workspace=$workspace; AuthenticationMode='ApiKey'
            ApiKey='[Storage.Secrets.Read.fixture-key|]'
        }
    }
    $sourceBefore = $source | ConvertTo-Json -Depth 20 -Compress
    $sourceSignal = [Signal]::Start("CodexCLI.Loader.Source.$slot") | Select-Object -Last 1
    $sourceSignal.SetResult($source) | Out-Null
    $resolved = & $foundation {
        param($loaderSignal,$context,$selectedJacket)
        Resolve-AdapterFromJacket -Signal $loaderSignal -ConductionContext $context -Jacket $selectedJacket | Select-Object -Last 1
    } $runSignal $runSignal $sourceSignal
    if ($resolved.Failure()) { Write-Output (@($resolved.GetEntries() | ForEach-Object Message) -join ' | ') }
    Assert (-not $resolved.Failure() -and $resolved.HasResult()) "Production loader failed for $slot."
    $adapter = $resolved.GetResult()
    Assert ($adapter.GetType().Name -ceq 'Intelligence_CodexCLI' -and $adapter.Configuration.HydrationMarker -ceq 'synthetic-deferred') "Hydrated Construct failed for $slot."
    Assert ($adapter.Configuration.CodexCLI.ApiKey -ceq 'fixture-key' -and $adapter.Configuration.CodexCLI.ExecutablePath -ceq $fixtureExe) 'Nested hydrated settings were lost.'
    Assert (($source | ConvertTo-Json -Depth 20 -Compress) -ceq $sourceBefore) 'Loader mutated source jacket.'
    $registered = Register-AdapterToMappedSlot -ConductorJacketSignal $conductor.Signal -Signal $runSignal -ConductionContext $conductor.Signal -Adapter $adapter | Select-Object -Last 1
    Assert (-not $registered.Failure()) "Mapped registration failed for $slot."
    $plan = [pscustomobject]@{ Adapter="Intelligence.$slot"; Activity='SendMessage'; Config=[pscustomobject]@{ Prompt="loader $slot" } }
    $sent = Invoke-MappedAdapter -Adapter $plan.Adapter -Activity $plan.Activity -Signal $runSignal -Plan $plan -ItemSignal $itemSignal | Select-Object -Last 1
    Assert (-not $sent.Failure() -and (($sent.GetResult() | ConvertFrom-Json).choices[0].message.content -ceq "loader $slot")) "Mapped route failed for $slot."
}
Assert ($global:CodexCLIHydrationCount -eq 2) 'Deferred hydration did not run exactly once per jacket.'

# Restore the real Foundation hydration route before exercising named consumer steps.
& $foundation { param($original) Set-Item -Path Function:script:Invoke-CondenserAdapter -Value $original } $originalCondenser
$utilityPath = 'C:/GitHub/SiliconDreamArtists/SDAFusion-Content/SDA/Plans/SDAUtility.Json'
$artifactPath = 'C:/GitHub/SiliconDreamArtists/SDAFusion-Content/SDA/SDA/Artifact_Curation.Json'
$utilityBytes = [IO.File]::ReadAllBytes($utilityPath)
$artifactBytes = [IO.File]::ReadAllBytes($artifactPath)
$utility = [Text.Encoding]::UTF8.GetString($utilityBytes) | ConvertFrom-Json -Depth 100
$artifact = [Text.Encoding]::UTF8.GetString($artifactBytes) | ConvertFrom-Json -Depth 100
$utilitySteps = @($utility.Phases | Where-Object Name -eq 'AskAIQuestion' | Select-Object -First 1).Steps
$artifactSteps = @($artifact.Phases | Where-Object Name -eq 'AskAIQuestion' | Select-Object -First 1).Steps
$utilitySend = @($utilitySteps | Where-Object Name -eq 'SendAIprompt')[0]
$utilityHandle = @($utilitySteps | Where-Object Name -eq 'ProcessAIRequest')[0]
$artifactSend = @($artifactSteps | Where-Object Name -eq 'SendAIprompt')[0]
$artifactHandle = @($artifactSteps | Where-Object Name -eq 'ProcessAIRequest')[0]
$sourceSteps = @($utilitySend,$utilityHandle,$artifactSend,$artifactHandle)
$sourceBefore = @($sourceSteps | ForEach-Object { $_ | ConvertTo-Json -Depth 40 -Compress })
Assert ($utilitySend.Adapter -ceq 'Network.AI' -and $artifactSend.Adapter -ceq 'Network.AI') 'Original source routes changed.'
$originalRoute = Invoke-MappedAdapter -Adapter $utilitySend.Adapter -Activity $utilitySend.Activity -Signal $runSignal -Plan $utilitySend -ItemSignal $itemSignal | Select-Object -Last 1
Assert ($originalRoute.Failure()) 'Original Network.AI route unexpectedly succeeded.'
$utilitySend = $utilitySend | ConvertTo-Json -Depth 40 | ConvertFrom-Json -Depth 40
$utilityHandle = $utilityHandle | ConvertTo-Json -Depth 40 | ConvertFrom-Json -Depth 40
$artifactSend = $artifactSend | ConvertTo-Json -Depth 40 | ConvertFrom-Json -Depth 40
$artifactHandle = $artifactHandle | ConvertTo-Json -Depth 40 | ConvertFrom-Json -Depth 40
$utilitySend.Adapter = 'Intelligence.AI'
$artifactSend.Adapter = 'Intelligence.AI'
$utilityHandle.Adapter = 'Intelligence.AI'
$artifactHandle.Adapter = 'Intelligence.AI'
$graph = $itemSignal.GetPointer()
$graph.RegisterResultAsSignal('Utility_Result','%AI') | Out-Null
$graph.RegisterResultAsSignal('Utility_Prompt','') | Out-Null
$graph.RegisterResultAsSignal('AIPrompt',([pscustomobject]@{ System='artifact'; Texts=@('artifact prompt'); Media=@() })) | Out-Null

function Hydrate-NamedStep($Step, $Config) {
    $copy = $Step | ConvertTo-Json -Depth 40 -Compress | ConvertFrom-Json -Depth 40
    $source = [Signal]::Start('CodexCLI.NamedStep.Source') | Select-Object -Last 1
    $source.SetResult($copy) | Out-Null
    $hydrationItem = [Signal]::Start('CodexCLI.NamedStep.Item') | Select-Object -Last 1
    $hydrationItem.SetJacket($source) | Out-Null
    $hydrationItem.SetPointer($itemSignal.GetPointer()) | Out-Null
    foreach ($style in @('Standard','Deferred')) {
        $hydrationPlan = [pscustomobject]@{ Path='%.@'; HydrationPlan='@'; HydrationStyle=$style; Config=$Config }
        $resolved = & $foundation {
            param($plan,$signal,$item)
            Invoke-CondenserAdapter -Slot 'Hydration' -Activity 'Invoke' -Plan $plan -Signal $signal -ItemSignal $item | Select-Object -Last 1
        } $hydrationPlan $runSignal $hydrationItem
        if ($resolved.Failure()) { Write-Output (@($resolved.GetEntries() | ForEach-Object Message) -join ' | ') }
        Assert (-not $resolved.Failure() -and $resolved.HasResult()) "Named $($Step.Name) $style hydration failed."
        $source.SetResult($resolved.GetResult()) | Out-Null
    }
    return $source.GetResult()
}

$utilityConfig = [pscustomobject]@{ SystemPrompt='system'; StaticPrompt='first'; CanonicalResources='second'; DynamicPrompt=''; MediaUrl=''; MediaType='image'; AttributePath='Utility'; AttributeName='' }
$artifactConfig = [pscustomobject]@{ ModelKey='fixture' }
$hydratedUtilitySend = Hydrate-NamedStep $utilitySend $utilityConfig
Assert ($hydratedUtilitySend.Config.Prompt.System -ceq 'system' -and
    (@($hydratedUtilitySend.Config.Prompt.Texts) -join '|') -ceq 'first|second||' -and
    $hydratedUtilitySend.Config.Prompt.Media[0].MediaUrl -ceq '' -and
    $hydratedUtilitySend.Config.Prompt.Media[0].MediaType -ceq 'image') 'SDAUtility ordered prompt or media hydration differs.'
$utilityResult = Invoke-MappedAdapter -Adapter $hydratedUtilitySend.Adapter -Activity $hydratedUtilitySend.Activity -Signal $runSignal -Plan $hydratedUtilitySend -ItemSignal $itemSignal | Select-Object -Last 1
Assert (-not $utilityResult.Failure() -and (($utilityResult.GetResult() | ConvertFrom-Json).choices[0].message.content -ceq "System:`nsystem`n`nfirst`n`nsecond")) 'Loaded AI route did not run SDAUtility step.'
$hydratedArtifactSend = Hydrate-NamedStep $artifactSend $artifactConfig
Assert ($hydratedArtifactSend.Config.ModelKey -ceq 'fixture' -and $hydratedArtifactSend.Config.Prompt.System -ceq 'artifact' -and
    (@($hydratedArtifactSend.Config.Prompt.Texts) -join '|') -ceq 'artifact prompt' -and
    @($hydratedArtifactSend.Config.Prompt.Media).Count -eq 0) 'Artifact_Curation model or prompt hydration differs.'
$artifactResult = Invoke-MappedAdapter -Adapter $hydratedArtifactSend.Adapter -Activity $hydratedArtifactSend.Activity -Signal $runSignal -Plan $hydratedArtifactSend -ItemSignal $itemSignal | Select-Object -Last 1
Assert (-not $artifactResult.Failure() -and (($artifactResult.GetResult() | ConvertFrom-Json).choices[0].message.content -ceq '{"answer":"ok"}')) 'Loaded AI route did not run Artifact_Curation step.'
$graph.RegisterResultAsSignal('AIResponse',($artifactResult.GetResult() | ConvertFrom-Json -Depth 20)) | Out-Null
$hydratedArtifactHandle = Hydrate-NamedStep $artifactHandle $artifactConfig
Assert ($hydratedArtifactHandle.Path -ceq '*.#.AIResponse.@.choices.0.message.content') 'Artifact_Curation extraction path hydration differs.'
$artifactHandled = Invoke-MappedAdapter -Adapter $hydratedArtifactHandle.Adapter -Activity $hydratedArtifactHandle.Activity -Signal $runSignal -Plan $hydratedArtifactHandle -ItemSignal $itemSignal | Select-Object -Last 1
Assert (-not $artifactHandled.Failure() -and $artifactHandled.GetResult().answer -ceq 'ok') 'Artifact_Curation extraction/Json formatting failed.'
$graph.RegisterResultAsSignal('Utility_Response',($artifactResult.GetResult() | ConvertFrom-Json -Depth 20)) | Out-Null
$hydratedUtilityHandle = Hydrate-NamedStep $utilityHandle $utilityConfig
Assert ($hydratedUtilityHandle.Path -ceq '*.#.Utility_Response.@.choices.0.message.content') 'SDAUtility extraction path hydration differs.'
$utilityHandled = Invoke-MappedAdapter -Adapter $hydratedUtilityHandle.Adapter -Activity $hydratedUtilityHandle.Activity -Signal $runSignal -Plan $hydratedUtilityHandle -ItemSignal $itemSignal | Select-Object -Last 1
Assert (-not $utilityHandled.Failure() -and $utilityHandled.GetResult().answer -ceq 'ok') 'SDAUtility extraction/Json formatting failed.'
for ($index=0; $index -lt $sourceSteps.Count; $index++) {
    Assert (($sourceSteps[$index] | ConvertTo-Json -Depth 40 -Compress) -ceq $sourceBefore[$index]) 'Named consumer source step was mutated.'
}
Assert ([Linq.Enumerable]::SequenceEqual([byte[]]$utilityBytes,[byte[]][IO.File]::ReadAllBytes($utilityPath))) 'SDAUtility source file changed.'
Assert ([Linq.Enumerable]::SequenceEqual([byte[]]$artifactBytes,[byte[]][IO.File]::ReadAllBytes($artifactPath))) 'Artifact_Curation source file changed.'
if ([IO.File]::Exists((Join-Path $workspace 'fixture-invocations.log'))) { [IO.File]::Delete((Join-Path $workspace 'fixture-invocations.log')) }
Write-Output 'PASS: production loader deferred hydration, Construct, both mapped routes, and named consumer steps.'
