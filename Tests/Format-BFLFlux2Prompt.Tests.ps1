using module SignalGraph
using module ../../SovereignTrust.Foundation/Src/PowerShell/SovereignTrust.Foundation.psd1

$ErrorActionPreference = 'Stop'
function Assert([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }

$planPath = Join-Path $PSScriptRoot '../../BDDB.Infrastructure/integration/sovereign-trust/content/test/plans/intelligence/format-bfl-flux2-prompt.json'
$fixturePath = Join-Path $PSScriptRoot 'Fixtures/BFLFlux2Prompt.json'
$raw = [IO.File]::ReadAllText((Resolve-Path $planPath).ProviderPath)
$plans = ConvertFrom-Json -InputObject $raw -Depth 80 -NoEnumerate
Assert ($plans.Count -eq 2 -and @($plans[1].PSObject.Properties).Count -eq 0) 'ST named-plan array sentinel is missing.'
$plan = @($plans | Where-Object Name -CEQ 'Format-BFLFlux2Prompt')[0]
Assert ($null -ne $plan -and @($plan.Phases | Where-Object Name -CEQ 'FormatFlux2Prompt').Count -eq 1) 'Named formatter phase is missing.'
Assert ($raw -notmatch '(?i)Storage\.Secrets|https?://|[A-Z]:[\\/]|Resource\.Credentials|Authorization|api-key') 'Portable plan contains an endpoint, absolute path or credential reference.'
foreach ($step in @($plan.Phases[0].Steps)) {
    Assert ($step.Adapter -cin @('Condenser.Transform','Condenser.Plan','Token.Dynamic')) "Unexpected adapter in portable formatter: $($step.Adapter)"
}
$cases = (Get-Content $fixturePath -Raw | ConvertFrom-Json -Depth 50).Cases

$bootstrap = [Signal]::Start('BFLFormat.Bootstrap') | Select-Object -Last 1
$bootstrap.SetResult([pscustomobject]@{}) | Out-Null
$started = New-Conductor -HostConductor $null -ConductionSignal $bootstrap | Select-Object -Last 1
Assert (-not $started.Failure() -and $started.HasResult()) 'Local ST conductor initialization failed.'
$conductor = $started.GetResult()
$control = [Signal]::Start('BFLFormat.Control') | Select-Object -Last 1
$control.SetJacket($conductor.Signal) | Out-Null
$control.SetPointer($conductor.Signal.GetPointer()) | Out-Null
$run = [Signal]::Start('BFLFormat.Run') | Select-Object -Last 1
$run.SetControl($control) | Out-Null
$run.SetJacket($control) | Out-Null
$run.SetPointer($conductor.Signal.GetPointer()) | Out-Null
$contentRoot = [IO.Path]::GetFullPath((Join-Path (Split-Path (Resolve-Path $planPath).Path) '../..'))
$localJacket = [pscustomobject]@{
    Kind='Storage'; Slot='LocalContent'
    VirtualPath='SovereignTrust.Adapters.Storage.EmbeddedFileSystem.LocalContent.Persistent.Read'
    Addresses=@($contentRoot)
}
$local = & (Get-Module SovereignTrust.Foundation) { [Storage_EmbeddedFileSystem]::new() }
$localConstruct = $local.Construct($localJacket) | Select-Object -Last 1
Assert (-not $localConstruct.Failure()) 'LocalContent construction failed.'
$localRegistration = Register-AdapterToMappedSlot -ConductorJacketSignal $conductor.Signal -Signal $run -ConductionContext $conductor.Signal -Adapter $local | Select-Object -Last 1
Assert (-not $localRegistration.Failure()) 'LocalContent registration failed.'
$loadItem = [Signal]::Start('BFLFormat.LoaderItem') | Select-Object -Last 1
$loadItem.SetPointer($conductor.Signal.GetPointer()) | Out-Null
$loadPlan = [pscustomobject]@{ Container='plans/intelligence'; Resource='format-bfl-flux2-prompt.json' }
$loadedSignal = Invoke-MappedAdapter -Adapter 'Storage.LocalContent' -Activity 'Read' -Signal $run -Plan $loadPlan -ItemSignal $loadItem | Select-Object -Last 1
Assert (-not $loadedSignal.Failure() -and $loadedSignal.HasResult()) 'LocalContent formatter load failed.'
$loadedText = [string]$loadedSignal.GetResult()
Assert ($loadedText -ceq $raw) 'LocalContent loaded bytes differ from the canonical formatter.'
$phase = @($plan.Phases | Where-Object Name -CEQ 'FormatFlux2Prompt')[0]

function Invoke-Formatter([object]$Case) {
    $item = [Signal]::Start("BFLFormat.$($Case.Name)") | Select-Object -Last 1
    $null = $item.CreateGraph()
    $null = $item.GetPointer().RegisterResultAsSignal('BFLFormatterPlan', $plan)
    $null = $item.GetPointer().RegisterResultAsSignal('BFLFormatInput', $Case)
    $result = & (Get-Module SovereignTrust.Foundation) { param($signal,$inputItem,$selectedPhase)
        Invoke-PlanPhase -ConductionSignal $signal -ItemSignal $inputItem -Phase $selectedPhase | Select-Object -Last 1
    } $run $item $phase
    return [pscustomobject]@{ Signal=$result; Item=$item }
}

$passed = 0
foreach ($name in @('ProText','FlexReference')) {
    $case = @($cases | Where-Object Name -CEQ $name)[0]
    $actual = Invoke-Formatter $case
    if ($actual.Signal.Failure()) { throw "ST formatter phase failed for $name : $((@($actual.Signal.GetEntries() | ForEach-Object Message) | Select-Object -Last 2) -join ' | ')" }
    $entry = $actual.Item.GetPointer().Grid['FormattedPrompt']
    Assert ($null -ne $entry -and $entry.HasResult()) "FormattedPrompt graph result missing for $name."
    $output = $entry.GetResult()
    $kindCheck = $actual.Item.GetPointer().Grid['ApiKindValid']
    Assert ($null -ne $kindCheck -and $kindCheck.HasResult() -and $kindCheck.GetResult() -is [bool] -and $kindCheck.GetResult()) "Native ordinal kind check missing for $name."
    Assert ($output.schemaVersion -eq 1 -and $output.formatKind -ceq 'BlackForestLabsFlux2' -and $output.profileKey -ceq $case.Selection.ProfileKey) "Formatter identity mismatch for $name."
    Assert ($output.selection.Slot -ceq 'Foundry' -and $output.selection.TargetActivity -ceq 'GenerateImage' -and $output.selection.RouteKey -ceq $case.Selection.RouteKey -and $output.selection.ApiKind -ceq 'BlackForestLabsFlux2') "Formatter selection mismatch for $name."
    Assert ($output.content.prompt -ceq $case.ExpectedPrompt) "Formatter prompt mismatch for $name."
    Assert (@($output.content.media).Count -eq @($case.Prompt.Media).Count) "Formatter media count mismatch for $name."
    if (@($case.Prompt.Media).Count -gt 0) {
        Assert ($output.content.media -is [array]) "Formatter media is not an array for $name."
        for ($index = 0; $index -lt $case.Prompt.Media.Count; $index++) {
            $expectedMedia = $case.Prompt.Media[$index]
            $actualMedia = $output.content.media[$index]
            Assert ($actualMedia.MediaType -ceq $expectedMedia.MediaType -and
                $actualMedia.MediaUrl -ceq $expectedMedia.MediaUrl -and
                $actualMedia.MediaPath -ceq $expectedMedia.MediaPath) "Formatter media order/fields differ at $name/$index."
        }
    }
    $passed++
}

$missing = @($cases | Where-Object Name -CEQ 'MissingText')[0]
$missingRun = Invoke-Formatter $missing
Assert ($missingRun.Signal.Failure() -or -not $missingRun.Item.GetPointer().Grid.Contains('FormattedPrompt')) 'Missing text unexpectedly produced a formatted prompt.'
$passed++
$acceptedInvalid = @()
foreach ($case in @($cases | Where-Object Name -CNotIn @('ProText','FlexReference','MissingText'))) {
    $name = $case.Name
    $actual = Invoke-Formatter $case
    if ($actual.Signal.Failure() -or -not $actual.Item.GetPointer().Grid.Contains('FormattedPrompt')) { $passed++ }
    else { $acceptedInvalid += $name }
}
if ($acceptedInvalid.Count -gt 0) { throw "ST phase accepted $($acceptedInvalid -join ', ') after $passed passing cases." }

$apiCheck = @($plan.Phases | Where-Object Name -CEQ 'ValidateInput')[0].Steps | Where-Object Name -CEQ 'CheckApiKind' | Select-Object -First 1
Assert ($null -ne $apiCheck) 'Ordinal ApiKind check step is missing.'
$savedPath = $apiCheck.Path
try {
    $apiCheck.Path = 'Dynamic.EqualsOrdinalString([Memory.Item.*.#.BFLFormatInput.@.Selection.ApiKind~],[Memory.Item.*.#.BFLFormatInput.@.Selection.ApiKind~])'
    $malformed = Invoke-Formatter (@($cases | Where-Object Name -CEQ 'ProText')[0])
    Assert ($malformed.Signal.Failure() -and -not $malformed.Item.GetPointer().Grid.Contains('FormattedPrompt')) 'Malformed ordinal comparator did not fail the actual phase closed.'
    $passed++
}
finally { $apiCheck.Path = $savedPath }

Write-Output "Format-BFLFlux2Prompt provider-free checks: $passed passed."
