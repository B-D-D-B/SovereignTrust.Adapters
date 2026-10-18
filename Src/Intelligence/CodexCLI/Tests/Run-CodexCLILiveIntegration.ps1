using module SignalGraph

$ErrorActionPreference = 'Stop'
if ($env:CODEXCLI_LIVE_READY -cne '1' -or [string]::IsNullOrWhiteSpace($env:CODEXCLI_LIVE_WORKSPACE) -or
    [string]::IsNullOrWhiteSpace($env:CODEXCLI_LIVE_MODEL) -or
    [string]::IsNullOrWhiteSpace($env:CODEXCLI_LIVE_EXECUTABLE) -or
    $env:CODEXCLI_LIVE_AUTH_MODE -cnotin @('Saved','ApiKey')) {
    Write-Output 'SKIP: live CodexCLI prerequisites are not explicitly ready.'
    exit 77
}
if (($env:CODEXCLI_LIVE_AUTH_MODE -ceq 'Saved' -and [string]::IsNullOrWhiteSpace($env:CODEXCLI_LIVE_CODEX_HOME)) -or
    ($env:CODEXCLI_LIVE_AUTH_MODE -ceq 'ApiKey' -and [string]::IsNullOrWhiteSpace($env:CODEXCLI_LIVE_API_KEY))) {
    Write-Output 'SKIP: live CodexCLI authentication prerequisite is absent.'
    exit 77
}
$manifest = Join-Path $PSScriptRoot '../PowerShell/Intelligence_CodexCLI.psd1'
Import-Module $manifest -Force
$jacket = [pscustomobject]@{
    Name='CodexCLILive'; VirtualPath='SovereignTrust.Adapters.Intelligence.CodexCLI.AI.Persistent.Run'; IsMapped=$true
    Kind='Intelligence'; Slot='AI'
    DefaultModelKey='live'; Profiles=@([pscustomobject]@{ ModelKey='live'; Model=$env:CODEXCLI_LIVE_MODEL; ReasoningEffort='medium' })
    CodexCLI=[pscustomobject]@{
        ExecutablePath=$env:CODEXCLI_LIVE_EXECUTABLE; Workspace=$env:CODEXCLI_LIVE_WORKSPACE
        AuthenticationMode=$env:CODEXCLI_LIVE_AUTH_MODE; CodexHome=$env:CODEXCLI_LIVE_CODEX_HOME
        ApiKey=$env:CODEXCLI_LIVE_API_KEY
    }
}
$adapter = Resolve-Intelligence_CodexCLI
if ($adapter.Construct($jacket).Failure()) { throw 'Live adapter construction failed.' }
$signal = [Signal]::Start('CodexCLI.Live') | Select-Object -Last 1
$plain = $adapter.Invoke('AI','SendMessage',$signal,[pscustomobject]@{Config=[pscustomobject]@{Prompt='Reply with one short greeting.'}},$signal)
if ($plain.Failure() -or -not $plain.HasResult()) { throw 'Live text request failed.' }
$plainChoice = $plain.GetResult() | ConvertFrom-Json -Depth 20
if ([string]::IsNullOrWhiteSpace($plainChoice.choices[0].message.content)) { throw 'Live text response was empty.' }
$schema = [pscustomobject]@{ type='object'; properties=[pscustomobject]@{ answer=[pscustomobject]@{ type='string' } }; required=@('answer'); additionalProperties=$false }
$structured = $adapter.Invoke('AI','SendMessage',$signal,[pscustomobject]@{Config=[pscustomobject]@{Prompt='Return an object with answer set to ok.';OutputSchema=$schema}},$signal)
if ($structured.Failure() -or -not $structured.HasResult()) { throw 'Live structured request failed.' }
$answer = (($structured.GetResult() | ConvertFrom-Json -Depth 20).choices[0].message.content | ConvertFrom-Json -Depth 20)
if ($answer.answer -isnot [string]) { throw 'Live structured answer failed schema extraction.' }
Write-Output 'PASS: live CodexCLI text and structured responses.'
