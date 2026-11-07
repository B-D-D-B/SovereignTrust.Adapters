using module SignalGraph

$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$project=Join-Path $PSScriptRoot 'FixtureCli/FixtureCli.csproj'
$output=Join-Path $PSScriptRoot 'FixtureCli/out'
& dotnet build $project -c Release -o $output --nologo | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Fixture build failed.' }
Import-Module (Join-Path $root 'PowerShell/Intelligence_CodexCLI.psd1') -Force
function Assert([bool]$Condition,[string]$Message) { if (-not $Condition) { throw $Message } }
$workspace=Join-Path 'C:/GitHub' ('codexcli-v2-fixture-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($workspace) | Out-Null
try {
    $jacket=[pscustomobject]@{SchemaVersion=2;Name='CodexV2Fixture';Kind='Intelligence';Slot='AI';
        Profiles=@([pscustomobject]@{Key='arbitrary-text';IsDefault=$true;Model='fixture';ReasoningEffort='medium'},
                   [pscustomobject]@{Key='alternate-name';IsDefault=$false;Model='fixture-output-first';ReasoningEffort='high'});
        CodexCLI=[pscustomobject]@{ExecutablePath=(Join-Path $output 'FixtureCli.exe');Workspace=$workspace;
            AuthenticationMode='ApiKey';ApiKey='fixture-secret';TimeoutSeconds=3} }
    $adapter=Resolve-Intelligence_CodexCLI
    Assert (-not $adapter.Construct($jacket).Failure()) 'V2 adapter construction failed.'
    $runtime=& (Get-Module Intelligence_CodexCLI) {param($j) Resolve-CodexCLIRuntime $j | Select-Object -Last 1} $jacket
    Assert (-not $runtime.Failure() -and $runtime.HasResult()) 'V2 runtime failed.'
    $config=[pscustomobject]@{Profile=[pscustomobject]@{Key='alternate-name'};Prompt="  leading`ninner`ntrailing  "}
    $request=& (Get-Module Intelligence_CodexCLI) {param($c,$r) Resolve-CodexCLIPrompt $c $r | Select-Object -Last 1} $config $runtime.GetResult()
    Assert (-not $request.Failure() -and $request.GetResult().Text -ceq $config.Prompt -and
        $request.GetResult().Model -ceq 'fixture-output-first' -and $request.GetResult().ReasoningEffort -ceq 'high' -and
        @($request.GetResult().Media).Count -eq 0) 'V2 selection or scalar changed.'
    $signal=[Signal]::Start('CodexV2.Tests') | Select-Object -Last 1
    $plan=[pscustomobject]@{Config=$config}
    $result=$adapter.Invoke('AI','SendMessage',$signal,$plan,$signal)
    Assert (-not $result.Failure() -and (($result.GetResult() | ConvertFrom-Json -Depth 20).choices[0].message.content -ceq $config.Prompt)) 'V2 stdin or text result changed.'
    $global:RemovedCodexExecutionCalls=0
    $codexModule=Get-Module Intelligence_CodexCLI
    & $codexModule {
        $script:originalCodexExecution=(Get-Item Function:script:Invoke-CodexCLIExecution).ScriptBlock
        Set-Item Function:script:Invoke-CodexCLIExecution -Value {
            $global:RemovedCodexExecutionCalls++
            throw 'Removed activity reached CLI execution.'
        }
    }
    try {
        $removed=$adapter.Invoke('AI','SendMessageOriginal',$signal,$plan,$signal)
        Assert ($removed.Failure() -and -not $removed.HasResult() -and $global:RemovedCodexExecutionCalls -eq 0) 'Removed Codex activity reached CLI execution.'
    } finally {
        & $codexModule { Set-Item Function:script:Invoke-CodexCLIExecution -Value $script:originalCodexExecution }
    }
    foreach ($mode in @('[fixture:exit-fail]','[fixture:timeout]')) {
        $failure=$adapter.Invoke('AI','SendMessage',$signal,([pscustomobject]@{Config=[pscustomobject]@{Profile=[pscustomobject]@{Key='arbitrary-text'};Prompt=$mode}}),$signal)
        Assert ($failure.Failure() -and -not $failure.HasResult()) 'V2 process failure was accepted.'
    }
    foreach ($bad in @(
        [pscustomobject]@{Prompt='missing selector'},
        [pscustomobject]@{Profile=[pscustomobject]@{Key='missing'};Prompt='bad key'},
        [pscustomobject]@{Profile=[pscustomobject]@{Key='arbitrary-text';Extra=1};Prompt='override'},
        [pscustomobject]@{Profile=[pscustomobject]@{Key='arbitrary-text'};Prompt='x';Body=@{evil=$true}},
        [pscustomobject]@{Profile=[pscustomobject]@{Key='arbitrary-text'};Prompt=[pscustomobject]@{Texts=@('x')}},
        [pscustomobject]@{Profile=[pscustomobject]@{Key='arbitrary-text'};Prompt='   '}
    )) {
        $s=& (Get-Module Intelligence_CodexCLI) {param($c,$r) Resolve-CodexCLIPrompt $c $r | Select-Object -Last 1} $bad $runtime.GetResult()
        Assert $s.Failure() 'Invalid v2 envelope was accepted.'
    }
    $duplicate=$jacket | ConvertTo-Json -Depth 20 | ConvertFrom-Json -Depth 20
    $duplicate.Profiles += [pscustomobject]@{Key='arbitrary-text';IsDefault=$false;Model='fixture';ReasoningEffort='medium'}
    Assert (& (Get-Module Intelligence_CodexCLI) {param($j) (Resolve-CodexCLIRuntime $j | Select-Object -Last 1).Failure()} $duplicate) 'Duplicate v2 key was accepted.'
    $duplicate=$jacket | ConvertTo-Json -Depth 20 | ConvertFrom-Json -Depth 20
    $duplicate.Profiles[1].IsDefault=$true
    Assert (& (Get-Module Intelligence_CodexCLI) {param($j) (Resolve-CodexCLIRuntime $j | Select-Object -Last 1).Failure()} $duplicate) 'Duplicate v2 default was accepted.'
    $duplicate=$jacket | ConvertTo-Json -Depth 20 | ConvertFrom-Json -Depth 20
    $duplicate.Profiles[0].IsDefault=$false
    Assert (& (Get-Module Intelligence_CodexCLI) {param($j) (Resolve-CodexCLIRuntime $j | Select-Object -Last 1).Failure()} $duplicate) 'Missing v2 default was accepted.'
    Write-Output 'PASS: CodexCLI v2 scalar stdin, arbitrary profile, text result and negatives.'
} finally {
    $resolved=[IO.Path]::GetFullPath($workspace)
    if (-not $resolved.StartsWith('C:\GitHub\codexcli-v2-fixture-',[StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe fixture cleanup path.' }
    if ([IO.Directory]::Exists($resolved)) { [IO.Directory]::Delete($resolved,$true) }
}
