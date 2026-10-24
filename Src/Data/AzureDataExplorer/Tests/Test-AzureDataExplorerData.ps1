using module ../../../../../SignalGraph/Src/PowerShell/SignalGraph/SignalGraph.psd1
$ErrorActionPreference = 'Stop'
$adapterRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../../..')).ProviderPath
$siblingRoot = (Resolve-Path (Join-Path $adapterRoot '..')).ProviderPath
$env:PSModulePath = (Join-Path $siblingRoot 'SignalGraph/Src/PowerShell') + [IO.Path]::PathSeparator +
    (Join-Path $siblingRoot 'SovereignTrust.Foundation/Src/PowerShell') + [IO.Path]::PathSeparator + $env:PSModulePath
$pass=0; $fail=0
function Assert-Case([string]$Name,[bool]$Condition) {
    if($Condition){$script:pass++}else{$script:fail++;Write-Error "FAIL: $Name" -ErrorAction Continue}
}
Import-Module (Join-Path $PSScriptRoot '../PowerShell/Data_AzureDataExplorer.psd1') -Force
$module=Get-Module Data_AzureDataExplorer
& $module {
    $script:Calls=0; $script:Tokens=0; $script:Mode='ok'
    $script:Response='{"Tables":[{"TableName":"PrimaryResult","Columns":[{"ColumnName":"RunId","DataType":"String"},{"ColumnName":"Id","DataType":"Int32"}],"Rows":[["abc",7]]}]}'
    function script:Get-ADXAdminToken {param($Plan) $script:Tokens++; 'fake-token'}
    function script:Send-ADXAdminHttp {
        param($Uri,$Database,$Command,$Token,$RequestId)
        $script:Calls++; $script:Last=@{Uri=$Uri;Database=$Database;Command=$Command;RequestId=$RequestId}
        if($script:Mode -eq 'timeout'){throw [TimeoutException]::new('secret fake-token')}
        if($script:Mode -eq 'http'){return [pscustomobject]@{StatusCode=403;Content='secret fake-token'}}
        [pscustomobject]@{StatusCode=200;Content=$script:Response}
    }
}
$adapter=Resolve-Data_AzureDataExplorer
$null=$adapter.Construct(@{Addresses=@('https://free-test.westus3.kusto.windows.net');Resource='testdb'})
$conduction=[Signal]::Start('data-test')|Select-Object -Last 1
$item=[Signal]::Start('data-item')|Select-Object -Last 1
$id='a'*32; $table="STData_$id"
$query=@{Config=@{CommandText="$table | count"}}
$write=@{Config=@{CommandText=".ingest inline into table $table <|`n$id,7,`"Sovereign Trust`",`"Records`""}}
$delete=@{Config=@{CommandText=".delete table $table records <| $table | where RunId == `"$id`""}}
$s=$adapter.Invoke('ADX','Query',$conduction,$query,$item)
$v=$s.GetResult()|ConvertFrom-Json
Assert-Case 'query typed rows and endpoint' ($s.Success() -and $v.Operation -eq 'Query' -and $v.ResultSets[0].Rows[0].Id -eq 7 -and (& $module {$script:Last.Uri}) -like '*/v1/rest/query')
foreach($case in @(@('Write',$write),@('Delete',$delete))){
    $s=$adapter.Invoke('ADX',$case[0],$conduction,$case[1],$item)
    $v=$s.GetResult()|ConvertFrom-Json
    Assert-Case "$($case[0]) management envelope" ($s.Success() -and $v.Operation -eq $case[0] -and (& $module {$script:Last.Uri}) -like '*/v1/rest/mgmt')
}
$alternate=@{Config=@{CommandText=".ingest inline into table AnotherFixture_01 <|`nother-run,19,`"Alternate Name`",`"Another Kind`""}}
$s=$adapter.Invoke('ADX','Write',$conduction,$alternate,$item)
Assert-Case 'alternate inline payload accepted' ($s.Success() -and $s.HasResult() -and (& $module {$script:Last.Command}) -ceq $alternate.Config.CommandText)
$before=& $module {@($script:Calls,$script:Tokens)}
foreach($case in @(
    @('management as query','Query',@{Config=@{CommandText='.show tables'}}),
    @('arbitrary write','Write',@{Config=@{CommandText='.set table T <| print 1'}}),
    @('unscoped delete','Delete',@{Config=@{CommandText=".delete table $table records <| $table"}}),
    @('caller token','Query',@{Config=@{CommandText='print 1';AccessToken='evil'}})
)){
    $s=$adapter.Invoke('ADX',$case[1],$conduction,$case[2],$item)
    Assert-Case $case[0] (-not $s.Success() -and -not $s.HasResult() -and (& $module {$script:Calls}) -eq $before[0] -and (& $module {$script:Tokens}) -eq $before[1])
}
& $module {$script:Response='{"Tables":[{"TableName":"QueryStatus","Columns":[{"ColumnName":"Severity","DataType":"Int32"}],"Rows":[[2]]}]}' }
$s=$adapter.Invoke('ADX','Query',$conduction,$query,$item)
Assert-Case 'partial response fails' (-not $s.Success() -and -not $s.HasResult())
& $module {$script:Response='{"Tables":[{"TableName":"X","Columns":[],"Rows":[[1]]}]}' }
$s=$adapter.Invoke('ADX','Query',$conduction,$query,$item)
Assert-Case 'malformed response fails' (-not $s.Success() -and -not $s.HasResult())
& $module {$script:Mode='http'}
$s=$adapter.Invoke('ADX','Query',$conduction,$query,$item)
Assert-Case 'http diagnostics sanitized' (-not $s.Success() -and -not $s.HasResult() -and (@($s.Entries|ForEach-Object Message)-join ' ') -notmatch 'secret|fake-token')
& $module {$script:Mode='timeout'}
$s=$adapter.Invoke('ADX','Delete',$conduction,$delete,$item)
Assert-Case 'unknown outcome no result' (-not $s.Success() -and -not $s.HasResult() -and (@($s.Entries|ForEach-Object Message)-join ' ') -match 'OutcomeUnknown')
"Pass=$pass Fail=$fail Total=$($pass+$fail)"
if($fail){exit 1}
