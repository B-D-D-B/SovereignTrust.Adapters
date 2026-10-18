using module SignalGraph

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$manifest = Join-Path $root 'PowerShell/Network_CodexCLI.psd1'
$foundationManifest = Join-Path $PSScriptRoot '../../../../../SovereignTrust.Foundation/Src/PowerShell/SovereignTrust.Foundation.psd1'
$project = Join-Path $PSScriptRoot 'FixtureCli/FixtureCli.csproj'
$output = Join-Path $PSScriptRoot 'FixtureCli/out'
$workspace = Join-Path $PSScriptRoot 'FixtureWorkspace'
[IO.Directory]::CreateDirectory($workspace) | Out-Null
& dotnet build $project -c Release -o $output --nologo | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Fixture build failed.' }
Import-Module (Resolve-Path $foundationManifest).Path -Force
Import-Module $manifest -Force
Add-Type -Path (Join-Path $PSScriptRoot 'FixtureHttps.cs') -ErrorAction Stop
function Assert([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
$jacket = [pscustomobject]@{
    Name = 'CodexCLIFixture'; VirtualPath = 'SovereignTrust.Adapters.Network.CodexCLI.AI.Persistent.Run'; IsMapped = $true
    Kind = 'Network'; Slot = 'AI'
    DefaultModelKey = 'fixture'
    Profiles = @(@('fixture','fixture-output-first','fixture-never-read','fixture-descendant','fixture-stdout-flood','fixture-stderr-flood') | ForEach-Object { [pscustomobject]@{ ModelKey = $_; Model = $_; ReasoningEffort = 'medium' } })
    CodexCLI = [pscustomobject]@{
        ExecutablePath = Join-Path $output 'FixtureCli.exe'; Workspace = $workspace
        AuthenticationMode = 'ApiKey'; ApiKey = 'fixture-key'; TimeoutSeconds = 3
    }
}
$adapter = Resolve-Network_CodexCLI
$construction = $adapter.Construct($jacket)
Assert (-not $construction.Failure() -and $construction.GetResult() -eq $adapter) 'Construct failed or did not return adapter.'
Assert ($adapter.Configuration -eq $jacket -and $adapter.Signal.GetJacket().GetResult() -eq $jacket) 'Construct lost jacket.'
$duplicateJacket = $jacket | ConvertTo-Json -Depth 20 | ConvertFrom-Json -Depth 20
$duplicateJacket.Profiles += [pscustomobject]@{ ModelKey='fixture'; Model='other'; ReasoningEffort='medium' }
$duplicateResult = & (Get-Module Network_CodexCLI) { param($j) Resolve-CodexCLIRuntime $j | Select-Object -Last 1 } $duplicateJacket
Assert ($duplicateResult.Failure()) 'Duplicate profile key was accepted.'
$legacyJacket = $jacket | ConvertTo-Json -Depth 20 | ConvertFrom-Json -Depth 20
$legacyJacket.CodexCLI | Add-Member -NotePropertyName Model -NotePropertyValue 'fixture'
$legacyResult = & (Get-Module Network_CodexCLI) { param($j) Resolve-CodexCLIRuntime $j | Select-Object -Last 1 } $legacyJacket
Assert ($legacyResult.Failure()) 'Legacy jacket model was accepted.'
$signal = [Signal]::Start('CodexCLI.Test') | Select-Object -Last 1
function Send([object]$Config) {
    $plan = [pscustomobject]@{ Config = $Config }
    return $adapter.Invoke('AI','SendMessage',$signal,$plan,$signal)
}
$savedHome = Join-Path $workspace ('saved-home-' + [guid]::NewGuid().ToString('N'))
$plugins = Join-Path $savedHome 'plugins'
$emptyNested = Join-Path $plugins 'empty'
$pluginFile = Join-Path $emptyNested 'plugin.txt'
$hooksFile = Join-Path $savedHome 'hooks.json'
[IO.Directory]::CreateDirectory($emptyNested) | Out-Null
$jacket.CodexCLI.AuthenticationMode = 'Saved'
$jacket.CodexCLI | Add-Member -NotePropertyName CodexHome -NotePropertyValue $savedHome
try {
    $emptyHome = & (Get-Module Network_CodexCLI) { param($j) Resolve-CodexCLIRuntime $j | Select-Object -Last 1 } $jacket
    Assert (-not $emptyHome.Failure() -and $emptyHome.HasResult()) 'Empty plugins directories blocked Saved mode.'
    [IO.File]::WriteAllText($pluginFile,'fixture plugin')
    $populatedHome = & (Get-Module Network_CodexCLI) { param($j) Resolve-CodexCLIRuntime $j | Select-Object -Last 1 } $jacket
    Assert ($populatedHome.Failure() -and ((@($populatedHome.GetEntries() | ForEach-Object Message) -join ' | ') -match 'disallowed hooks or plugins')) 'Populated plugins directory was accepted.'
    $jacket.CodexCLI | Add-Member -NotePropertyName AllowSavedHomeExtensions -NotePropertyValue $true
    $allowedPlugins = & (Get-Module Network_CodexCLI) { param($j) Resolve-CodexCLIRuntime $j | Select-Object -Last 1 } $jacket
    Assert (-not $allowedPlugins.Failure() -and $allowedPlugins.HasResult()) 'Jacket opt-in did not allow plugin content.'
    $jacket.CodexCLI.AllowSavedHomeExtensions = 'true'
    $invalidOptIn = & (Get-Module Network_CodexCLI) { param($j) Resolve-CodexCLIRuntime $j | Select-Object -Last 1 } $jacket
    Assert ($invalidOptIn.Failure() -and ((@($invalidOptIn.GetEntries() | ForEach-Object Message) -join ' | ') -match 'must be a Boolean')) 'Non-Boolean saved-home opt-in was accepted.'
    $jacket.CodexCLI.AllowSavedHomeExtensions = $false
    [IO.File]::Delete($pluginFile)
    [IO.File]::WriteAllText($hooksFile,'{}')
    $hookHome = & (Get-Module Network_CodexCLI) { param($j) Resolve-CodexCLIRuntime $j | Select-Object -Last 1 } $jacket
    Assert ($hookHome.Failure()) 'Saved home hooks.json was accepted.'
    $jacket.CodexCLI.AllowSavedHomeExtensions = $true
    $allowedHooks = & (Get-Module Network_CodexCLI) { param($j) Resolve-CodexCLIRuntime $j | Select-Object -Last 1 } $jacket
    Assert (-not $allowedHooks.Failure() -and $allowedHooks.HasResult()) 'Jacket opt-in did not allow hooks.json.'
}
finally {
    $jacket.CodexCLI.AuthenticationMode = 'ApiKey'
    $jacket.CodexCLI.PSObject.Properties.Remove('CodexHome')
    $jacket.CodexCLI.PSObject.Properties.Remove('AllowSavedHomeExtensions')
    if ([IO.File]::Exists($hooksFile)) { [IO.File]::Delete($hooksFile) }
    if ([IO.File]::Exists($pluginFile)) { [IO.File]::Delete($pluginFile) }
    if ([IO.Directory]::Exists($emptyNested)) { [IO.Directory]::Delete($emptyNested) }
    if ([IO.Directory]::Exists($plugins)) { [IO.Directory]::Delete($plugins) }
    if ([IO.Directory]::Exists($savedHome)) { [IO.Directory]::Delete($savedHome) }
}
$exitFailure = & (Get-Module Network_CodexCLI) {
    param($a)
    Invoke-CodexCLIExecution $a ([pscustomobject]@{ Prompt='[fixture:exit-fail]' })
} $adapter
Assert $exitFailure.Failure() 'Nonzero child exit was accepted.'
$exitEntries = @($exitFailure.GetEntries())
Assert (@($exitEntries | Where-Object { $_.Level -eq 'Critical' -and $_.Message -match 'exit code 23' }).Count -gt 0) 'Nonzero child exit code was lost.'
Assert (@($exitEntries | Where-Object { $_.Level -eq 'Critical' -and $_.Message -match 'fixture child failure detail' }).Count -gt 0) 'Stderr was not logged as critical.'
Assert (@($exitEntries | Where-Object { $_.Level -eq 'Information' -and $_.Message -match 'thread.started' }).Count -gt 0) 'Normal JSONL event was not logged as information.'
$eventFailure = & (Get-Module Network_CodexCLI) { param($a) Invoke-CodexCLIExecution $a ([pscustomobject]@{ Prompt='[fixture:fail]' }) } $adapter
Assert (@($eventFailure.GetEntries() | Where-Object { $_.Level -eq 'Critical' -and $_.Message -match 'turn.failed' }).Count -gt 0) 'Terminal JSONL event was not logged as critical.'

& (Get-Module Network_CodexCLI) {
    param($fixtureExecutable,$fixtureWorkspace)
    $fields = [pscustomobject]@{ Null=$null; False=$false; Empty=@(); One=@('one'); Many=@('one','two') }
    $missingMember = Test-CodexCLIMember $fields 'Missing' | Select-Object -Last 1
    $nullMember = Test-CodexCLIMember $fields 'Null' | Select-Object -Last 1
    Assert (-not $missingMember.Failure() -and -not $nullMember.Failure() -and -not $missingMember.GetResult() -and $nullMember.GetResult()) 'Missing and explicit-null membership collapsed.'
    $missingField = Resolve-PathFromDictionary -Dictionary $fields -Path 'Missing' -SignalLevel Information | Select-Object -Last 1
    $nullField = Resolve-PathFromDictionary -Dictionary $fields -Path 'Null' -SignalLevel Information | Select-Object -Last 1
    Assert (-not $missingField.HasResult() -and -not $nullField.HasResult()) 'Missing/null resolver behavior changed.'
    $falseField = Resolve-PathFromDictionary -Dictionary $fields -Path 'False' -SignalLevel Information | Select-Object -Last 1
    Assert ($falseField.HasResult() -and $falseField.GetResult() -ceq $false) 'False resolver value was lost.'
    foreach ($name in @('Empty','One','Many')) {
        $fieldSignal = Resolve-PathFromDictionary -Dictionary $fields -Path $name -SignalLevel Information | Select-Object -Last 1
        Assert (-not $fieldSignal.Failure() -and $fieldSignal.HasResult()) "Resolver failed for $name."
        $value = $fieldSignal.GetResult()
        Assert ($value -is [array] -and $value.Count -eq @{ Empty=0; One=1; Many=2 }[$name]) "Resolver array shape changed for $name."
    }
    $defaultLimit = Get-CodexCLILimit ([pscustomobject]@{}) 'TimeoutSeconds' 120 600 | Select-Object -Last 1
    Assert (-not $defaultLimit.Failure() -and $defaultLimit.GetResult() -eq 120) 'Absent limit did not use its default.'
    $invalidNullLimit = Get-CodexCLILimit ([pscustomobject]@{TimeoutSeconds=$null}) 'TimeoutSeconds' 120 600 | Select-Object -Last 1
    Assert $invalidNullLimit.Failure() 'Explicit-null limit was defaulted.'
    $literalSchema = [pscustomobject]@{ type='object'; properties=@{ 'a.b,c^d'=[pscustomobject]@{type='string'} }; required=@('a.b,c^d'); additionalProperties=$false }
    $literalSchemaSignal = Resolve-CodexCLISchema $literalSchema | Select-Object -Last 1
    Assert (-not $literalSchemaSignal.Failure() -and (($literalSchemaSignal.GetResult() | ConvertFrom-Json -Depth 10).required[0] -ceq 'a.b,c^d')) 'Literal schema property name was parsed as a path.'
    $emptyKeys = Get-CodexCLIKeys ([pscustomobject]@{}) | Select-Object -Last 1
    Assert (-not $emptyKeys.Failure() -and $emptyKeys.HasResult() -and $emptyKeys.GetResult() -is [array] -and $emptyKeys.GetResult().Count -eq 0) 'Empty key enumeration lost its array result.'
    $badRuntime = Resolve-CodexCLIRuntime ([pscustomobject]@{CodexCLI=[pscustomobject]@{
        ExecutablePath=$fixtureExecutable; Workspace=$fixtureWorkspace; AuthenticationMode='ApiKey'; ApiKey=$null
    }})
    Assert ($badRuntime.Failure() -and ((@($badRuntime.GetEntries() | ForEach-Object Message) -join ' | ') -match 'CodexCLI API key is unavailable')) 'Runtime auth diagnostics changed.'
    $promptRuntime = [pscustomobject]@{
        DefaultModelKey='fixture'
        Profiles=@{ fixture=[pscustomobject]@{ Model='fixture'; ReasoningEffort='medium' } }
        Limits=[pscustomobject]@{ MaxPromptBytes=1024 }
    }
    foreach ($breakValue in @($true, $false, 'true', 'false', $null)) {
        $breakPrompt = Resolve-CodexCLIPrompt ([pscustomobject]@{Prompt='valid-prompt';Break=$breakValue}) $promptRuntime | Select-Object -Last 1
        Assert (-not $breakPrompt.Failure() -and $breakPrompt.HasResult() -and $breakPrompt.GetResult().Text -ceq 'valid-prompt') 'Config.Break blocked or changed a valid prompt.'
    }
    $badPrompt = Resolve-CodexCLIPrompt ([pscustomobject]@{Prompt='sensitive-prompt';Content='conflicting-content'}) $null
    Assert ($badPrompt.Failure() -and ((@($badPrompt.GetEntries() | ForEach-Object Message) -join ' | ') -match 'Config.Prompt and Config.Content are ambiguous' -and
        (@($badPrompt.GetEntries() | ForEach-Object Message) -join ' | ') -notmatch 'sensitive-prompt')) 'Prompt policy diagnostics changed or leaked input.'
} (Join-Path $output 'FixtureCli.exe') $workspace
$result = Send ([pscustomobject]@{ Prompt = 'héllo $() ; & `n' })
Assert (-not $result.Failure() -and $result.HasResult()) 'Basic transport failed.'
$choice = $result.GetResult() | ConvertFrom-Json -Depth 10
Assert ($choice.choices[0].message.role -ceq 'assistant' -and $choice.choices[0].message.content -ceq 'héllo $() ; & `n') 'Final choice is not exact.'
$largePrompt = 'p' * 200000
$outputFirst = Send ([pscustomobject]@{ Prompt=$largePrompt; ModelKey='fixture-output-first' })
Assert (-not $outputFirst.Failure() -and (($outputFirst.GetResult() | ConvertFrom-Json).choices[0].message.content -ceq $largePrompt)) 'Output-before-stdin transport deadlocked or changed input.'
Assert (Send ([pscustomobject]@{ Prompt=$largePrompt; ModelKey='fixture-never-read' })).Failure() 'Never-read-stdin child did not time out.'
Assert (Send ([pscustomobject]@{ Prompt='descendant'; ModelKey='fixture-descendant' })).Failure() 'Descendant child did not time out.'
$descendantMarker = Join-Path $workspace 'descendant.pid'
Assert ([IO.File]::Exists($descendantMarker)) 'Descendant fixture did not launch.'
$descendantId = [int][IO.File]::ReadAllText($descendantMarker)
Start-Sleep -Milliseconds 250
Assert ($null -eq (Get-Process -Id $descendantId -ErrorAction SilentlyContinue)) 'Process-tree termination left the descendant alive.'
[IO.File]::Delete($descendantMarker)
$jacket.CodexCLI | Add-Member -NotePropertyName MaxEventBytes -NotePropertyValue 4096
Assert (Send ([pscustomobject]@{ Prompt='x'; ModelKey='fixture-stdout-flood' })).Failure() 'Stdout capture limit was not enforced.'
$stdoutReason = & (Get-Module Network_CodexCLI) { param($a) $s = Invoke-CodexCLIExecution $a ([pscustomobject]@{Prompt='x';ModelKey='fixture-stdout-flood'}); @($s.GetEntries() | ForEach-Object Message) -join ' | ' } $adapter
Assert ($stdoutReason -match 'output limit exceeded') 'Stdout flood failed for a reason other than its bound.'
$jacket.CodexCLI.PSObject.Properties.Remove('MaxEventBytes')
$jacket.CodexCLI | Add-Member -NotePropertyName MaxStderrBytes -NotePropertyValue 4096
Assert (Send ([pscustomobject]@{ Prompt='x'; ModelKey='fixture-stderr-flood' })).Failure() 'Stderr capture limit was not enforced.'
$stderrReason = & (Get-Module Network_CodexCLI) { param($a) $s = Invoke-CodexCLIExecution $a ([pscustomobject]@{Prompt='x';ModelKey='fixture-stderr-flood'}); @($s.GetEntries() | ForEach-Object Message) -join ' | ' } $adapter
Assert ($stderrReason -match 'output limit exceeded') 'Stderr flood failed for a reason other than its bound.'
$jacket.CodexCLI.PSObject.Properties.Remove('MaxStderrBytes')
$module = Get-Module Network_CodexCLI

& $module {
    Assert-CodexCLIEvents "{`"type`":`"thread.started`"}`n{`"type`":`"future.event`"}`n{`"type`":`"turn.completed`"}" 0
    foreach ($stream in @('{','{"type":"turn.failed"}','{"type":"error"}','{"type":"thread.started"}')) {
        $failed = $false
        try { Assert-CodexCLIEvents $stream 0 } catch { $failed = $true }
        Assert $failed 'Malformed/incomplete/terminal stream was accepted.'
    }
}
foreach ($mode in @('fail','malformed','no-final','zero-final','blank-final','flood','timeout')) {
    $failed = Send ([pscustomobject]@{ Prompt = "[fixture:$mode]" })
    Assert $failed.Failure() "Fixture mode $mode was accepted."
}
$schema = [pscustomobject]@{ type='object'; properties=[pscustomobject]@{ answer=[pscustomobject]@{ type='string' } }; required=@('answer'); additionalProperties=$false }
$valid = Send ([pscustomobject]@{ Prompt='[fixture:schema-valid]'; OutputSchema=$schema })
Assert (-not $valid.Failure() -and (($valid.GetResult() | ConvertFrom-Json).choices[0].message.content -ceq '{"answer":"ok"}')) 'Schema-valid result failed.'
$schemaWithUri = $schema | ConvertTo-Json -Depth 10 | ConvertFrom-Json -Depth 10
$schemaWithUri | Add-Member -NotePropertyName '$schema' -NotePropertyValue 'https://json-schema.org/draft/2020-12/schema'
$validWithUri = Send ([pscustomobject]@{ Prompt='[fixture:schema-valid]'; OutputSchema=$schemaWithUri })
Assert (-not $validWithUri.Failure() -and (($validWithUri.GetResult() | ConvertFrom-Json).choices[0].message.content -ceq '{"answer":"ok"}')) 'Exact schema URI was rejected.'
$schemaCases = @(
    [pscustomobject]@{ Name='property-array'; Change={ param($s) $s.properties.answer.type = @('string') } },
    [pscustomobject]@{ Name='top-array'; Change={ param($s) $s.type = @('object') } },
    [pscustomobject]@{ Name='closed-array'; Change={ param($s) $s.additionalProperties = @($false) } },
    [pscustomobject]@{ Name='closed-string'; Change={ param($s) $s.additionalProperties = 'False' } },
    [pscustomobject]@{ Name='uri-array'; Change={ param($s) $s | Add-Member -NotePropertyName '$schema' -NotePropertyValue @('https://json-schema.org/draft/2020-12/schema') } },
    [pscustomobject]@{ Name='uri-null'; Change={ param($s) $s | Add-Member -NotePropertyName '$schema' -NotePropertyValue $null } }
)
foreach ($case in $schemaCases) {
    $candidate = $schema | ConvertTo-Json -Depth 10 | ConvertFrom-Json -Depth 10
    & $case.Change $candidate
    $preflight = & (Get-Module Network_CodexCLI) { param($value) Resolve-CodexCLISchema $value | Select-Object -Last 1 } $candidate
    Assert ($preflight.Failure() -and -not $preflight.HasResult()) "Schema $($case.Name) passed direct preflight."
    $invocationLog = Join-Path $workspace 'fixture-invocations.log'
    $beforeCalls = if ([IO.File]::Exists($invocationLog)) { [IO.File]::ReadAllLines($invocationLog).Count } else { 0 }
    $rejected = Send ([pscustomobject]@{ Prompt="r06-secret-$($case.Name)"; OutputSchema=$candidate })
    $afterCalls = if ([IO.File]::Exists($invocationLog)) { [IO.File]::ReadAllLines($invocationLog).Count } else { 0 }
    Assert ($rejected.Failure() -and -not $rejected.HasResult() -and $afterCalls -eq $beforeCalls) "Schema $($case.Name) reached model execution or was accepted."
    Assert ((@($rejected.GetEntries() | ForEach-Object Message) -join ' | ') -notmatch 'r06-secret-|fixture-key') "Schema $($case.Name) leaked input in diagnostics."
}
$invalid = Send ([pscustomobject]@{ Prompt='[fixture:schema-invalid]'; OutputSchema=$schema })
Assert $invalid.Failure() 'Schema-invalid result was accepted.'
Assert (Send ([pscustomobject]@{ Prompt='[fixture:malformed-schema-final]'; OutputSchema=$schema })).Failure() 'Malformed schema final was accepted.'
$jacket.CodexCLI | Add-Member -NotePropertyName MaxFinalBytes -NotePropertyValue 128
Assert (Send ([pscustomobject]@{ Prompt='[fixture:oversize-final]' })).Failure() 'Oversized final file was accepted.'
$jacket.CodexCLI.PSObject.Properties.Remove('MaxFinalBytes')
$badSchema = [pscustomobject]@{ type='object'; properties=[pscustomobject]@{ answer=[pscustomobject]@{ type='object' } }; required=@('answer'); additionalProperties=$false }
Assert (Send ([pscustomobject]@{ Prompt='x'; OutputSchema=$badSchema })).Failure() 'Unsupported schema was accepted.'
Assert (Send ([pscustomobject]@{ Prompt='x'; Temperature=0.5 })).Failure() 'Unsupported option was accepted.'
Assert (Send ([pscustomobject]@{ Prompt='x'; ModelKey='other' })).Failure() 'Unknown model key was accepted.'
$secretProbe = Send ([pscustomobject]@{ Prompt='codexcli-secret-probe'; ModelKey='other' })
Assert ((@($secretProbe.GetEntries() | ForEach-Object Message) -join ' | ') -notmatch 'codexcli-secret-probe|fixture-key') 'Secret input reached Signal diagnostics.'
Assert (Send ([pscustomobject]@{ Prompt='x'; Content='y' })).Failure() 'Ambiguous content was accepted.'
Assert (Send ([pscustomobject]@{ Prompt='x'; Unexpected=@('') })).Failure() 'Single-item unknown option array was treated as blank text.'
Assert (Send ([pscustomobject]@{ Prompt=[pscustomobject]@{ System=@('system'); Texts=@('text') } })).Failure() 'Single-item System array was accepted as text.'
Assert (Send ([pscustomobject]@{ Prompt=[pscustomobject]@{ Media=@([pscustomobject]@{ MediaUrl=@('https://allowed.example/image.png'); MediaType='image' }) } })).Failure() 'Single-item MediaUrl array was accepted as text.'
$before = [pscustomobject]@{ Prompt=[pscustomobject]@{ System='system'; Texts=@('one','','two'); Media=@([pscustomobject]@{MediaUrl='';MediaType='image'}) }; Break=$false }
$serialized = $before | ConvertTo-Json -Depth 10 -Compress
$ordered = Send $before
Assert (-not $ordered.Failure()) 'Ordered prompt failed.'
Assert (($ordered.GetResult() | ConvertFrom-Json).choices[0].message.content -ceq "System:`nsystem`n`none`n`ntwo") 'Ordered prompt text changed.'
Assert (($before | ConvertTo-Json -Depth 10 -Compress) -ceq $serialized) 'Caller config was mutated.'
Assert (Send ([pscustomobject]@{ Prompt=[pscustomobject]@{Media=@([pscustomobject]@{MediaUrl='';MediaType='image'})} })).Failure() 'Blank media-only prompt was accepted.'
$bootstrap = [Signal]::Start('CodexCLI.Routing.Bootstrap') | Select-Object -Last 1
$bootstrap.SetResult([pscustomobject]@{}) | Out-Null
$conductorResult = New-Conductor -HostConductor $null -ConductionSignal $bootstrap | Select-Object -Last 1
Assert (-not $conductorResult.Failure() -and $conductorResult.HasResult()) 'Routing conductor failed.'
$conductor = $conductorResult.GetResult()
$mappedProbe = Resolve-PathFromDictionary -Dictionary $conductor.Signal -Path '*.#.Adapters.*.#.MappedNetwork' | Select-Object -Last 1
Assert (-not $mappedProbe.Failure() -and $mappedProbe.HasResult()) 'MappedNetwork unavailable.'
$typedConstructed = & (Get-Module Network_CodexCLI) { param($mapped) [Network_CodexCLI]::new($mapped) } $mappedProbe.GetResult($true)
Assert ($typedConstructed.MappedAdapter -eq $mappedProbe.GetResult($true)) 'MappedNetworkAdapter constructor failed.'
$conductorJacket = [Signal]::Start('CodexCLI.Routing.Conductor') | Select-Object -Last 1
$conductorJacket.SetJacket($conductor.Signal) | Out-Null
$conductorJacket.SetPointer($conductor.Signal.GetPointer()) | Out-Null
$runSignal = [Signal]::Start('CodexCLI.Routing.Run') | Select-Object -Last 1
$runSignal.SetControl($conductorJacket) | Out-Null
$runSignal.SetPointer($conductor.Signal.GetPointer()) | Out-Null
$itemSignal = [Signal]::Start('CodexCLI.Routing.Item') | Select-Object -Last 1
$itemSignal.SetPointer($conductor.Signal.GetPointer()) | Out-Null
$registration = Register-AdapterToMappedSlot -ConductorJacketSignal $conductor.Signal -Signal $runSignal -ConductionContext $conductor.Signal -Adapter $adapter | Select-Object -Last 1
Assert (-not $registration.Failure()) 'Network.AI registration failed.'
$routedPlan = [pscustomobject]@{ Adapter='Network.AI'; Activity='SendMessage'; Config=[pscustomobject]@{ Prompt='routed' } }
$routed = Invoke-MappedAdapter -Adapter $routedPlan.Adapter -Activity $routedPlan.Activity -Signal $runSignal -Plan $routedPlan -ItemSignal $itemSignal | Select-Object -Last 1
Assert (-not $routed.Failure() -and $routed.HasResult()) 'Network.AI mapped route failed.'
Assert (($routed.GetResult() | ConvertFrom-Json).choices[0].message.content -ceq 'routed') 'Mapped route lost result.'
$imageFile = Join-Path $workspace 'pixel.png'
[IO.File]::WriteAllBytes($imageFile, [Convert]::FromBase64String('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Y9O3wAAAABJRU5ErkJggg=='))
$jacket.CodexCLI | Add-Member -NotePropertyName AllowedLocalImageRoots -NotePropertyValue @($workspace)
try {
    $imagePlan = [pscustomobject]@{ Prompt=[pscustomobject]@{ Media=@([pscustomobject]@{MediaPath=$imageFile;MediaType='image'}) } }
    $jacket.CodexCLI.AllowedLocalImageRoots = @()
    Assert (Send $imagePlan).Failure() 'Empty local roots accepted an image.'
    $jacket.CodexCLI.AllowedLocalImageRoots = @('*')
    $wildcardImage = Send $imagePlan
    Assert (-not $wildcardImage.Failure() -and $wildcardImage.HasResult()) 'Wildcard local roots rejected an image.'
    $jacket.CodexCLI.AllowedLocalImageRoots = @($workspace)
    $imageOnly = Send $imagePlan
    Assert (-not $imageOnly.Failure() -and (($imageOnly.GetResult() | ConvertFrom-Json).choices[0].message.content -ceq 'Respond to the attached image(s).')) 'Image-only fallback failed.'
    Assert (Send ([pscustomobject]@{ Prompt=[pscustomobject]@{Media=@([pscustomobject]@{MediaPath=$imageFile;MediaType='image';Detail='high'})} })).Failure() 'Unsupported image detail was accepted.'
    Assert (Send ([pscustomobject]@{ Prompt=[pscustomobject]@{Media=@([pscustomobject]@{MediaUrl='http://example.com/a.png';MediaType='image'})} })).Failure() 'HTTP media URL was accepted.'
}
finally { [IO.File]::Delete($imageFile) }
$allowedRoot = Join-Path $workspace 'allowed-images'
$outsideRoot = Join-Path $workspace 'outside-images'
$inside = Join-Path $allowedRoot 'link'
[IO.Directory]::CreateDirectory($allowedRoot) | Out-Null
[IO.Directory]::CreateDirectory((Join-Path $outsideRoot 'nested')) | Out-Null
$outsideImage = Join-Path $outsideRoot 'nested/pixel.png'
[IO.File]::WriteAllBytes($outsideImage, [Convert]::FromBase64String('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Y9O3wAAAABJRU5ErkJggg=='))
try {
    New-Item -ItemType Junction -Path $inside -Target $outsideRoot -ErrorAction Stop | Out-Null
    $jacket.CodexCLI.AllowedLocalImageRoots = @($allowedRoot)
    $linkedImage = Join-Path $inside 'nested/pixel.png'
    Assert (Send ([pscustomobject]@{ Prompt=[pscustomobject]@{ Media=@([pscustomobject]@{MediaPath=$linkedImage;MediaType='image'}) } })).Failure() 'Nested junction escaped local image root.'
}
finally {
    foreach ($target in @($allowedRoot,$outsideRoot)) {
        Assert ([IO.Path]::GetFullPath($target).StartsWith(([IO.Path]::GetFullPath($workspace).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar), [StringComparison]::OrdinalIgnoreCase)) 'Fixture cleanup target escaped workspace.'
    }
    if ([IO.Directory]::Exists($inside)) { [IO.Directory]::Delete($inside) }
    if ([IO.Directory]::Exists($allowedRoot)) { [IO.Directory]::Delete($allowedRoot,$true) }
    if ([IO.Directory]::Exists($outsideRoot)) { [IO.Directory]::Delete($outsideRoot,$true) }
    $jacket.CodexCLI.AllowedLocalImageRoots = @($workspace)
}
$utility = Get-Content 'C:/GitHub/SiliconDreamArtists/SDAFusion-Content/SDA/Plans/SDAUtility.Json' -Raw | ConvertFrom-Json -Depth 100
$artifact = Get-Content 'C:/GitHub/SiliconDreamArtists/SDAFusion-Content/SDA/SDA/Artifact_Curation.Json' -Raw | ConvertFrom-Json -Depth 100
$utilitySteps = @($utility.Phases | Where-Object Name -eq 'AskAIQuestion' | Select-Object -First 1).Steps
$utilitySend = @($utilitySteps | Where-Object Name -eq 'SendAIprompt')[0]
$utilityHandle = @($utilitySteps | Where-Object Name -eq 'ProcessAIRequest')[0]
$artifactSteps = @($artifact.Phases | Where-Object Name -eq 'AskAIQuestion' | Select-Object -First 1).Steps
$artifactSend = @($artifactSteps | Where-Object Name -eq 'SendAIprompt')[0]
$artifactHandle = @($artifactSteps | Where-Object Name -eq 'ProcessAIRequest')[0]
Assert ($utilitySend.Adapter -ceq 'Network.AI' -and $utilityHandle.Activity -ceq 'HandleMessage' -and $artifactSend.Adapter -ceq 'Network.AI' -and $artifactHandle.Activity -ceq 'HandleMessage') 'Named source steps changed.'
$utilitySend.Config.Prompt.System = 'system'
$utilitySend.Config.Prompt.Texts = @('one','','two','')
$utilitySend.Config.Prompt.Media = @([pscustomobject]@{ MediaUrl=''; MediaType='image' })
$utilityResult = Invoke-MappedAdapter -Adapter $utilitySend.Adapter -Activity $utilitySend.Activity -Signal $runSignal -Plan $utilitySend -ItemSignal $itemSignal | Select-Object -Last 1
Assert (-not $utilityResult.Failure() -and (($utilityResult.GetResult() | ConvertFrom-Json).choices[0].message.content -ceq "System:`nsystem`n`none`n`ntwo")) 'SDAUtility named SendMessage failed.'
$artifactSend.Config.PSObject.Properties.Remove('Model')
$artifactSend.Config | Add-Member -NotePropertyName ModelKey -NotePropertyValue 'fixture' -Force
$artifactSend.Config.Prompt = [pscustomobject]@{ System='artifact system'; Texts=@('artifact prompt'); Media=@() }
$normalizedArtifact = & (Get-Module Network_CodexCLI) {
    param($config,$jacket)
    $runtimeSignal = Resolve-CodexCLIRuntime $jacket
    Assert (-not $runtimeSignal.Failure() -and $runtimeSignal.HasResult()) 'Runtime normalization failed.'
    $promptSignal = Resolve-CodexCLIPrompt $config $runtimeSignal.GetResult()
    Assert (-not $promptSignal.Failure() -and $promptSignal.HasResult()) 'Prompt normalization failed.'
    $promptSignal.GetResult()
} $artifactSend.Config $jacket
Assert ($normalizedArtifact.Text -ceq "System:`nartifact system`n`nartifact prompt" -and $normalizedArtifact.Model -ceq 'fixture') 'Artifact hydrated prompt/model normalization failed.'
$artifactResult = Invoke-MappedAdapter -Adapter $artifactSend.Adapter -Activity $artifactSend.Activity -Signal $runSignal -Plan $artifactSend -ItemSignal $itemSignal | Select-Object -Last 1
Assert (-not $artifactResult.Failure() -and (($artifactResult.GetResult() | ConvertFrom-Json).choices[0].message.content -ceq '{"answer":"ok"}')) 'Artifact_Curation named SendMessage failed.'
$graph = $itemSignal.GetPointer()
$graph.RegisterResultAsSignal('AIResponse',($artifactResult.GetResult() | ConvertFrom-Json -Depth 10)) | Out-Null
$handled = Invoke-MappedAdapter -Adapter $artifactHandle.Adapter -Activity $artifactHandle.Activity -Signal $runSignal -Plan $artifactHandle -ItemSignal $itemSignal | Select-Object -Last 1
Assert (-not $handled.Failure() -and $handled.HasResult()) 'Artifact_Curation named HandleMessage failed.'
Assert ($handled.GetResult().answer -ceq 'ok') 'Artifact_Curation Json formatting changed content.'
$utilityHandle.Path = $utilityHandle.Path.Replace('[Memory.Plan.Config.AttributePath/][Memory.Plan.Config.AttributeName/]', 'Utility')
$graph.RegisterResultAsSignal('Utility_Response',($artifactResult.GetResult() | ConvertFrom-Json -Depth 10)) | Out-Null
$utilityHandled = Invoke-MappedAdapter -Adapter $utilityHandle.Adapter -Activity $utilityHandle.Activity -Signal $runSignal -Plan $utilityHandle -ItemSignal $itemSignal | Select-Object -Last 1
Assert (-not $utilityHandled.Failure() -and $utilityHandled.GetResult().answer -ceq 'ok') 'SDAUtility named extraction/Json formatting failed.'
& (Get-Module Network_CodexCLI) {
    param($jacket,$workspace)
    $initSignal = Initialize-CodexCLIHttpType | Select-Object -Last 1
    Assert (-not $initSignal.Failure() -and $initSignal.HasResult()) 'HTTPS type initialization failed.'
    foreach ($address in @('127.0.0.1','10.0.0.1','169.254.1.1','192.168.1.1','::1','::','fc00::1','::ffff:127.0.0.1')) {
        Assert (-not [CodexCLIPinnedImageDownload]::IsAllowedAddress([Net.IPAddress]::Parse($address))) 'Private image address was allowed.'
    }
    Assert ([CodexCLIPinnedImageDownload]::IsAllowedAddress([Net.IPAddress]::Parse('8.8.8.8'))) 'Public image address was rejected.'
    $runtimeSignal = Resolve-CodexCLIRuntime $jacket
    Assert (-not $runtimeSignal.Failure() -and $runtimeSignal.HasResult()) 'Argument fixture runtime failed.'
    $runtime = $runtimeSignal.GetResult()
    $owned = Join-Path $workspace 'argument-fixture'
    [IO.Directory]::CreateDirectory($owned) | Out-Null
    try {
        $request = [pscustomobject]@{ Text='secret prompt'; Model='fixture'; ReasoningEffort='medium'; SchemaJson=$null }
        $start = New-CodexCLIProcess $runtime $request @() $owned
        $args = @($start.ArgumentList)
        $expected = @('-a','never','exec','--ignore-user-config','--ignore-rules','--strict-config','--json','--ephemeral','--sandbox','read-only','--color','never','--skip-git-repo-check','--cd',$workspace,'--output-last-message',(Join-Path $owned 'final.txt'),'--model','fixture','--config','model_reasoning_effort="medium"','-')
        Assert (($args -join [char]0) -ceq ($expected -join [char]0)) 'Fixed ArgumentList differs.'
        Assert (-not ($args -contains 'secret prompt') -and $start.UseShellExecute -eq $false) 'Prompt reached arguments or shell.'
        Assert ($start.Environment['CODEX_API_KEY'] -ceq 'fixture-key' -and $start.Environment['CODEX_HOME'] -ceq $owned -and -not $start.Environment.ContainsKey('OPENAI_API_KEY')) 'ApiKey child environment differs.'
        $runtime.AuthenticationMode = 'Saved'; $runtime.CodexHome = $workspace
        $saved = New-CodexCLIProcess $runtime $request @() $owned
        Assert ($saved.Environment['CODEX_HOME'] -ceq $workspace -and -not $saved.Environment.ContainsKey('CODEX_API_KEY')) 'Saved child environment differs.'
    }
    finally { [IO.Directory]::Delete($owned,$true) }
} $jacket $workspace
& (Get-Module Network_CodexCLI) {
    $initSignal = Initialize-CodexCLIHttpType | Select-Object -Last 1
    Assert (-not $initSignal.Failure() -and $initSignal.HasResult()) 'Repeated HTTPS type initialization failed.'
    $hosts = [string[]]@('allowed.example')
    $public = [Net.IPAddress]::Parse('8.8.8.8')
    $url = 'https://allowed.example/image.png'
    foreach ($allowedHosts in @(@(), @('other.example'), @('*'), @('other.example','*'))) {
        $wildcardServer = [CodexCLIFixtureHttps]::new('ok')
        try {
            $mime = $null
            $failed = $false
            try { $null = [CodexCLIPinnedImageDownload]::GetForTest($url,[string[]]$allowedHosts,1024,2,[Net.IPAddress[]]@($public),$wildcardServer.Port,$wildcardServer.Thumbprint,0,[ref]$mime) } catch { $failed = $true }
            Assert ($failed -eq ('*' -cnotin $allowedHosts)) 'Host wildcard or explicit host restriction failed.'
        }
        finally { $wildcardServer.Dispose() }
    }
    foreach ($mode in @('ok','redirect','missingmime','wrongmime','oversize','chunkedoversize','stallheaders','stallbody')) {
        $server = [CodexCLIFixtureHttps]::new($mode)
        try {
            $mime = $null
            $failed = $false
            $deadlineWatch = [Diagnostics.Stopwatch]::StartNew()
            try {
                $bytes = [CodexCLIPinnedImageDownload]::GetForTest($url,$hosts,1024,2,[Net.IPAddress[]]@($public),$server.Port,$server.Thumbprint,0,[ref]$mime)
                $signatureSignal = Assert-CodexCLIImageMimeSignature $bytes $mime | Select-Object -Last 1
                if ($signatureSignal.Failure()) { $failed = $true }
            }
            catch { $failed = $true }
            $deadlineWatch.Stop()
            if ($mode -eq 'ok') {
                Assert (-not $failed -and $bytes.Length -gt 0 -and $mime -ceq 'image/png') 'Pinned HTTPS image failed.'
                Assert ([CodexCLIPinnedImageDownload]::LastTestSelectedAddress -ceq '8.8.8.8:443' -and
                    [CodexCLIPinnedImageDownload]::LastTestForwardedAddress -ceq "127.0.0.1:$($server.Port)" -and
                    $server.Sni -ceq 'allowed.example' -and $server.Host -ceq 'allowed.example') 'Selected endpoint, forwarded socket, SNI, or Host changed.'
            }
            else {
                Assert $failed "HTTPS image $mode was accepted."
                if ($mode -in @('stallheaders','stallbody')) { Assert ($deadlineWatch.Elapsed.TotalSeconds -lt 4) "HTTPS image $mode exceeded one deadline." }
            }
        }
        finally { $server.Dispose() }
    }
    $server = [CodexCLIFixtureHttps]::new('ok')
    try {
        $mime = $null
        $failed = $false
        try { $null = [CodexCLIPinnedImageDownload]::GetForTest($url,$hosts,1024,2,[Net.IPAddress[]]@($public,[Net.IPAddress]::Loopback),$server.Port,$server.Thumbprint,0,[ref]$mime) } catch { $failed = $true }
        Assert $failed 'Rebound/private DNS answer was accepted.'
        Assert ($null -eq [CodexCLIPinnedImageDownload]::LastTestSelectedAddress) 'Rejected DNS answer reached the connector.'
        $failed = $false
        $dnsWatch = [Diagnostics.Stopwatch]::StartNew()
        try { $null = [CodexCLIPinnedImageDownload]::GetForTest($url,$hosts,1024,1,[Net.IPAddress[]]@($public),$server.Port,$server.Thumbprint,3000,[ref]$mime) } catch { $failed = $true }
        $dnsWatch.Stop()
        Assert ($failed -and $dnsWatch.Elapsed.TotalSeconds -lt 2.5) 'Stalled DNS exceeded the image deadline.'
    }
    finally { $server.Dispose() }
}
& (Get-Module Network_CodexCLI) {
    param($adapter,$signal,$jacket)
    $jacket.CodexCLI | Add-Member -NotePropertyName AllowedImageHosts -NotePropertyValue @('*')
    $jacket.CodexCLI | Add-Member -NotePropertyName MaxImageBytes -NotePropertyValue 1024
    $jacket.CodexCLI | Add-Member -NotePropertyName MaxDownloadSeconds -NotePropertyValue 2
    $originalDownload = (Get-Command Invoke-CodexCLIImageDownload).ScriptBlock
    Set-Item -Path Function:script:Invoke-CodexCLIImageDownload -Value {
        param($Url,$AllowedHosts,$MaxBytes,$Seconds,[ref]$Mime)
        $opSignal = [Signal]::Start('CodexCLI.ImageFixtureDownload') | Select-Object -Last 1
        try {
            $server = $global:CodexCLIImageFixtureServer
            $bytes = [CodexCLIPinnedImageDownload]::GetForTest($Url,[string[]]$AllowedHosts,$MaxBytes,$Seconds,
                [Net.IPAddress[]]@([Net.IPAddress]::Parse('8.8.8.8')),$server.Port,$server.Thumbprint,0,$Mime)
            $opSignal.SetResult($bytes) | Out-Null
        }
        catch { $null = $opSignal.LogCritical('Fixture HTTPS image download failed.') }
        return $opSignal
    }
    try {
        $before = @([IO.Directory]::GetDirectories([IO.Path]::GetTempPath(),'codexcli-*'))
        foreach ($mode in @('ok','redirect','missingmime','wrongmime','oversize','chunkedoversize','stallbody')) {
            $global:CodexCLIImageFixtureServer = [CodexCLIFixtureHttps]::new($mode)
            try {
                $plan = [pscustomobject]@{Config=[pscustomobject]@{Prompt=[pscustomobject]@{Media=@([pscustomobject]@{MediaUrl='https://allowed.example/image.png';MediaType='image'})}}}
                $response = $adapter.Invoke('AI','SendMessage',$signal,$plan,$signal)
                if ($mode -eq 'ok') {
                    Assert (-not $response.Failure() -and (($response.GetResult() | ConvertFrom-Json).choices[0].message.content -ceq 'Respond to the attached image(s).')) 'Remote image normalization failed.'
                }
                else { Assert $response.Failure() "Remote image $mode was accepted." }
            }
            finally { $global:CodexCLIImageFixtureServer.Dispose() }
        }
        $after = @([IO.Directory]::GetDirectories([IO.Path]::GetTempPath(),'codexcli-*'))
        Assert (@($after | Where-Object { $_ -notin $before }).Count -eq 0) 'Remote image invocation directory was not cleaned.'
    }
    finally {
        Set-Item -Path Function:script:Invoke-CodexCLIImageDownload -Value $originalDownload
        $jacket.CodexCLI.PSObject.Properties.Remove('AllowedImageHosts')
        $jacket.CodexCLI.PSObject.Properties.Remove('MaxImageBytes')
        $jacket.CodexCLI.PSObject.Properties.Remove('MaxDownloadSeconds')
        Remove-Variable CodexCLIImageFixtureServer -Scope Global -ErrorAction SilentlyContinue
    }
} $adapter $signal $jacket
& (Get-Module Network_CodexCLI) {
    param($adapter,$signal)
    $originalCleanup = (Get-Command Remove-CodexCLIInvocationDirectory).ScriptBlock
    $global:CodexCLICleanupFixturePaths = @()
    Set-Item -Path Function:script:Remove-CodexCLIInvocationDirectory -Value {
        param($Directory)
        $global:CodexCLICleanupFixturePaths += $Directory
        throw 'synthetic cleanup failure'
    }
    try {
        $primarySignal = Invoke-CodexCLIExecution $adapter ([pscustomobject]@{ Prompt='[fixture:fail]' })
        Assert $primarySignal.Failure() 'Primary execution failure was accepted.'
        $primary = @($primarySignal.GetEntries() | ForEach-Object Message) -join ' | '
        Assert ($primary -match 'terminal failure' -and $primary -notmatch 'cleanup') 'Cleanup masked primary execution failure.'
        $cleanupOnlySignal = Invoke-CodexCLIExecution $adapter ([pscustomobject]@{ Prompt='cleanup-only-secret' })
        Assert $cleanupOnlySignal.Failure() 'Cleanup-only error did not fail execution.'
        $cleanupOnly = @($cleanupOnlySignal.GetEntries() | ForEach-Object Message) -join ' | '
        Assert ($cleanupOnly -match 'invocation cleanup failed' -and $cleanupOnly -notmatch 'synthetic cleanup failure|cleanup-only-secret') 'Cleanup-only diagnostics were not sanitized.'
        $public = $adapter.Invoke('AI','SendMessage',$signal,[pscustomobject]@{Config=[pscustomobject]@{Prompt='cleanup-only-secret'}},$signal)
        Assert $public.Failure() 'Cleanup-only error did not fail Signal.'
        Assert ((@($public.GetEntries() | ForEach-Object Message) -join ' | ') -notmatch 'cleanup-only-secret|synthetic cleanup failure') 'Public cleanup diagnostics leaked internal content.'
    }
    finally {
        Set-Item -Path Function:script:Remove-CodexCLIInvocationDirectory -Value $originalCleanup
        $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
        foreach ($owned in $global:CodexCLICleanupFixturePaths) {
            if ($null -ne $owned -and [IO.Path]::GetFullPath($owned).StartsWith($tempRoot,[StringComparison]::OrdinalIgnoreCase) -and
                [IO.Path]::GetFileName($owned) -match '^codexcli-[0-9a-f]{32}$' -and [IO.Directory]::Exists($owned)) {
                [IO.Directory]::Delete($owned,$true)
            }
        }
        Remove-Variable CodexCLICleanupFixturePaths -Scope Global -ErrorAction SilentlyContinue
    }
} $adapter $signal
$invocationLog = Join-Path $workspace 'fixture-invocations.log'
if ([IO.File]::Exists($invocationLog)) {
    $invocationDirs = @([IO.File]::ReadAllLines($invocationLog) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    Assert ($invocationDirs.Count -gt 2 -and @($invocationDirs | Select-Object -Unique).Count -eq $invocationDirs.Count) 'Invocation directories were reused.'
    foreach ($owned in $invocationDirs) { Assert (-not [IO.Directory]::Exists($owned)) 'Invocation directory was not cleaned.' }
    [IO.File]::Delete($invocationLog)
}
& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'Run-CodexCLILoaderHydration.ps1')
if ($LASTEXITCODE -ne 0) { throw 'Fresh-process production loader integration failed.' }
Write-Output 'PASS: offline CodexCLI transport, final response, schema, failures, bounds, ordered prompt and caller isolation.'
