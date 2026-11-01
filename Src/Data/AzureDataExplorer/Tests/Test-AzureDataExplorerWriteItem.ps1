using module SignalGraph

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '../../../..')).ProviderPath
$sibling = (Resolve-Path (Join-Path $root '..')).ProviderPath
$env:PSModulePath = (Join-Path $sibling 'SignalGraph/Src/PowerShell') + [IO.Path]::PathSeparator +
    (Join-Path $sibling 'SovereignTrust.Foundation/Src/PowerShell') + [IO.Path]::PathSeparator + $env:PSModulePath
Import-Module (Join-Path $PSScriptRoot '../PowerShell/Data_AzureDataExplorer.psd1') -Force
$module = Get-Module Data_AzureDataExplorer
$pass = 0
function Assert-Case([string]$Name, [bool]$Condition) {
    if (-not $Condition) { throw "FAIL: $Name" }
    $script:pass++
}
& $module {
    $script:RestCalls = 0
    $script:LastRest = $null
    function script:Invoke-MappedAdapter {
        param($Adapter, $Activity, $Signal, $Plan, $ItemSignal)
        $script:RestCalls++
        $script:LastRest = @{ Adapter=$Adapter; Activity=$Activity; Plan=$Plan }
        $out = [Signal]::Start('WriteItem.RestMock') | Select-Object -Last 1
        $out.SetResult('{"ok":true}')
        return $out
    }
}
$adapter = Resolve-Data_AzureDataExplorer
$null = $adapter.Construct(@{ Addresses=@('https://fixture.westus3.kusto.windows.net'); Resource='db' })
$graph = ([Graph]::Start('WriteItemGraph', $null, $false) | Select-Object -Last 1).GetResult()
$conduction = [Signal]::Start('WriteItem.Conduction') | Select-Object -Last 1
$null = $conduction.SetPointer($graph)
$item = [Signal]::Start('WriteItem.Item') | Select-Object -Last 1
$null = $item.SetPointer($graph)
$null = $graph.RegisterResultAsSignal('Content', @(@{ Source='Default' }))
$null = $graph.RegisterResultAsSignal('AlternateRows', @(@{ Source='Alternate' }))

$selected = @{ Config=@{ ADX=@{ TableName='T'; MappingName='M'; ContentKey='AlternateRows' } } }
$selectedBefore = $selected | ConvertTo-Json -Depth 30 -Compress
$result = $adapter.Invoke('ADX','WriteItem',$conduction,$selected,$item)
$rest = & $module { $script:LastRest }
Assert-Case 'nested selection delegates once' ($result.Success() -and (& $module { $script:RestCalls }) -eq 1)
Assert-Case 'nested selected payload and target' ($rest.Adapter -ceq 'Condenser.Rest' -and $rest.Activity -ceq 'Get' -and
    $rest.Plan.Config.Uri -like '*/v1/rest/ingest/db/T' -and $rest.Plan.Config.Querystring -ceq '?streamFormat=json&mappingName=M' -and
    $rest.Plan.Config.Body -match 'Alternate' -and $rest.Plan.Config.Body -notmatch 'Default')
Assert-Case 'caller plan unchanged' (($selected | ConvertTo-Json -Depth 30 -Compress) -ceq $selectedBefore)

$default = @{ Config=@{ ADX=@{ TableName='T'; MappingName='M' } } }
$result = $adapter.Invoke('ADX','WriteItem',$conduction,$default,$item)
$rest = & $module { $script:LastRest }
Assert-Case 'absent ContentKey uses Content' ($result.Success() -and (& $module { $script:RestCalls }) -eq 2 -and
    $rest.Plan.Config.Body -match 'Default' -and $rest.Plan.Config.Body -notmatch 'Alternate')

foreach ($name in @('TableName','MappingName','ContentKey')) {
    $config = @{ ADX=@{ TableName='T'; MappingName='M' } }
    $config[$name] = if ($name -eq 'ContentKey') { 'AlternateRows' } else { 'Legacy' }
    $before = & $module { $script:RestCalls }
    $rejected = $adapter.Invoke('ADX','WriteItem',$conduction,@{ Config=$config },$item)
    Assert-Case "mixed flat $name rejected before delegation" (-not $rejected.Success() -and -not $rejected.HasResult() -and
        (& $module { $script:RestCalls }) -eq $before)
}
"Pass=$pass Fail=0 Total=$pass"
