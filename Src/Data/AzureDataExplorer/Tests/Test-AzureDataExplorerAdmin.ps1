using module ../../../../../SignalGraph/Src/PowerShell/SignalGraph/SignalGraph.psd1

$ErrorActionPreference = 'Stop'
$adapterRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../../..')).ProviderPath
$siblingRoot = (Resolve-Path (Join-Path $adapterRoot '..')).ProviderPath
$env:PSModulePath = (Join-Path $siblingRoot 'SignalGraph/Src/PowerShell') + [IO.Path]::PathSeparator +
    (Join-Path $siblingRoot 'SovereignTrust.Foundation/Src/PowerShell') + [IO.Path]::PathSeparator + $env:PSModulePath
$modulePath = Join-Path $PSScriptRoot '../PowerShell/Data_AzureDataExplorer.psd1'
$pass = 0; $fail = 0
function Assert-Case([string]$Name, [bool]$Condition) {
    if ($Condition) { $script:pass++ } else { $script:fail++; Write-Error "FAIL: $Name" -ErrorAction Continue }
}
try { Import-Module $modulePath -Force -ErrorAction Stop; Assert-Case 'fresh import' $true }
catch { Assert-Case 'fresh import' $false; "Pass=$pass Fail=$fail Total=$($pass+$fail)"; exit 1 }
$module = Get-Module Data_AzureDataExplorer
& $module {
    $script:TestCalls = 0; $script:TokenCalls = 0; $script:TestMode = 'success'
    $script:TestResponse = '{"Tables":[{"TableName":"PrimaryResult","Columns":[{"ColumnName":"Name","DataType":"String"}],"Rows":[["ok"]]}]}'
    function script:Get-ADXAdminToken { param([object]$Plan) $script:TokenCalls++; return 'fake-token' }
    function script:Send-ADXAdminHttp {
        param([string]$Uri,[string]$Database,[string]$Command,[string]$Token,[string]$RequestId)
        $script:TestCalls++
        $script:LastRequest = @{ Uri=$Uri; Database=$Database; Command=$Command; Token=$Token; RequestId=$RequestId }
        if ($script:TestMode -eq 'lost') { throw 'secret-command fake-token' }
        if ($script:TestMode -eq 'timeout') { throw [TimeoutException]::new('secret-command fake-token') }
        if ($script:TestMode -eq 'http') { return [pscustomobject]@{ StatusCode=403; Content='secret-command fake-token' } }
        return [pscustomobject]@{ StatusCode=200; Content=$script:TestResponse }
    }
}
$mocksInstalled = & $module {
    ((Get-Command Get-ADXAdminToken).ScriptBlock.ToString() -match 'fake-token') -and
    ((Get-Command Send-ADXAdminHttp).ScriptBlock.ToString() -match 'TestCalls')
}
if (-not $mocksInstalled) { 'FAIL: test doubles not installed'; exit 1 }
$requestFacts = & $module {
    $request = New-ADXAdminRequest -Uri 'https://free-test.westus3.kusto.windows.net/v1/rest/mgmt' -Database 'testdb' -Command '.show tables' -Token 'fake-token' -RequestId 'ADXAdmin;test'
    try {
        $body = $request.Content.ReadAsStringAsync().GetAwaiter().GetResult() | ConvertFrom-Json
        return @{ Method=$request.Method.Method; Uri=$request.RequestUri.AbsoluteUri; Database=$body.db; Command=$body.csl;
            Accept=[string]$request.Headers.Accept; ContentType=[string]$request.Content.Headers.ContentType;
            Scheme=$request.Headers.Authorization.Scheme; RequestId=[string]($request.Headers.GetValues('x-ms-client-request-id') | Select-Object -First 1) }
    }
    finally { $request.Dispose() }
}
Assert-Case 'management HTTP contract' ($requestFacts.Method -eq 'POST' -and $requestFacts.Uri -eq 'https://free-test.westus3.kusto.windows.net/v1/rest/mgmt' -and
    $requestFacts.Database -eq 'testdb' -and $requestFacts.Command -eq '.show tables' -and $requestFacts.Accept -eq 'application/json' -and
    $requestFacts.ContentType -eq 'application/json; charset=utf-8' -and $requestFacts.Scheme -eq 'Bearer' -and $requestFacts.RequestId -eq 'ADXAdmin;test')
$adapter = Resolve-Data_AzureDataExplorer
$jacket = [Signal]::Start('test.jacket') | Select-Object -Last 1
$jacket.SetResult(@{ Addresses=@('https://free-test.westus3.kusto.windows.net'); Resource='testdb' })
$constructed = $adapter.Construct($jacket.GetResult())
Assert-Case 'construct' ($constructed.Success() -and $null -ne $adapter.Signal)
$conduction = [Signal]::Start('test.conduction') | Select-Object -Last 1
$item = [Signal]::Start('test.item') | Select-Object -Last 1
$good = @{ Config=@{ CommandText='.show tables' } }
$signal = $adapter.Invoke('AdminFixture','Admin',$conduction,$good,$item)
Assert-Case 'admin result' ($signal.Success() -and $signal.HasResult() -and (($signal.GetResult() | ConvertFrom-Json).Operation -eq 'Admin'))
Assert-Case 'one management request' ((& $module { $script:TestCalls }) -eq 1 -and (& $module { $script:LastRequest.Uri }) -eq 'https://free-test.westus3.kusto.windows.net/v1/rest/mgmt')
$before = & $module { @($script:TestCalls,$script:TokenCalls) }
$bad = @{ Config=@{ CommandText='print 1' } }
$signal = $adapter.Invoke('AdminFixture','Admin',$conduction,$bad,$item)
Assert-Case 'query rejected before token' (-not $signal.Success() -and -not $signal.HasResult() -and (& $module { $script:TestCalls }) -eq $before[0] -and (& $module { $script:TokenCalls }) -eq $before[1])
$bad.Config.CommandText = '.show tables'; $bad.Config.Uri = 'https://other.kusto.windows.net/v1/rest/mgmt'
$signal = $adapter.Invoke('AdminFixture','Admin',$conduction,$bad,$item)
Assert-Case 'override rejected' (-not $signal.Success() -and (& $module { $script:TestCalls }) -eq $before[0])
$bad.Config.Remove('Uri'); $bad.Config.BearerToken = 'caller-supplied'
$signal = $adapter.Invoke('AdminFixture','Admin',$conduction,$bad,$item)
Assert-Case 'bearer override rejected' (-not $signal.Success() -and (& $module { $script:TokenCalls }) -eq $before[1])
$bad.Config.Remove('BearerToken')
$invalidCommands = @(
    @{ Name='missing command'; Value=$null; Remove=$true },
    @{ Name='nonstring command'; Value=7 },
    @{ Name='blank command'; Value='  ' },
    @{ Name='query command'; Value='print 1' }
)
foreach ($case in $invalidCommands) {
    $casePlan = @{ Config=@{} }
    if (-not ($case.ContainsKey('Remove') -and $case['Remove'])) { $casePlan.Config.CommandText = $case.Value }
    $beforeCalls = & $module { @($script:TokenCalls,$script:TestCalls) }
    $result = $adapter.Invoke('AdminFixture','Admin',$conduction,$casePlan,$item)
    Assert-Case $case.Name (-not $result.Success() -and -not $result.HasResult() -and
        (& $module { $script:TokenCalls }) -eq $beforeCalls[0] -and (& $module { $script:TestCalls }) -eq $beforeCalls[1])
}
$invalidTargets = @(
    @{ Name='ambiguous addresses'; Addresses=@('https://free-test.westus3.kusto.windows.net','https://other.westus3.kusto.windows.net') },
    @{ Name='insecure address'; Addresses=@('http://free-test.westus3.kusto.windows.net') },
    @{ Name='ingestion address'; Addresses=@('https://ingest-free-test.westus3.kusto.windows.net') },
    @{ Name='unexpected domain'; Addresses=@('https://free-test.westus3.example.net') },
    @{ Name='path address'; Addresses=@('https://free-test.westus3.kusto.windows.net/v1/rest/query') },
    @{ Name='query address'; Addresses=@('https://free-test.westus3.kusto.windows.net/?x=1') }
)
foreach ($case in $invalidTargets) {
    $targetAdapter = Resolve-Data_AzureDataExplorer
    $null = $targetAdapter.Construct(@{ Addresses=$case.Addresses; Resource='testdb' })
    $beforeCalls = & $module { @($script:TokenCalls,$script:TestCalls) }
    $result = $targetAdapter.Invoke('AdminFixture','Admin',$conduction,$good,$item)
    Assert-Case $case.Name (-not $result.Success() -and -not $result.HasResult() -and
        (& $module { $script:TokenCalls }) -eq $beforeCalls[0] -and (& $module { $script:TestCalls }) -eq $beforeCalls[1])
}
foreach ($name in @('ExpectedClusterUri','ExpectedDatabase')) {
    $override = @{ Config=@{ CommandText='.show tables' } }
    $override.Config[$name] = $null
    $beforeCalls = & $module { @($script:TokenCalls,$script:TestCalls) }
    $result = $adapter.Invoke('AdminFixture','Admin',$conduction,$override,$item)
    Assert-Case "$name override rejected" (-not $result.Success() -and -not $result.HasResult() -and
        (& $module { $script:TokenCalls }) -eq $beforeCalls[0] -and (& $module { $script:TestCalls }) -eq $beforeCalls[1])
}
& $module { $script:TestResponse = '{"Tables":[{"TableName":"One","Columns":[{"ColumnName":"A","DataType":"String"}],"Rows":[["x"]]},{"TableName":"Two","Columns":[{"ColumnName":"B","DataType":"Int32"}],"Rows":[[2]]}]}' }
$signal = $adapter.Invoke('AdminFixture','Admin',$conduction,$good,$item)
$parsed = $signal.GetResult() | ConvertFrom-Json
Assert-Case 'multi-table preservation' ($signal.Success() -and $parsed.Tables.Count -eq 2 -and $parsed.Tables[1].Rows[0][0] -eq 2)
& $module { $script:TestResponse = '{"Tables":[{"TableName":"T","Columns":[{"ColumnName":"Payload","DataType":"Dynamic"}],"Rows":[[{"error":"ordinary user data"}]]}]}' }
$signal = $adapter.Invoke('AdminFixture','Admin',$conduction,$good,$item)
$dynamic = $signal.GetResult() | ConvertFrom-Json
Assert-Case 'dynamic row error key preserved' ($signal.Success() -and $dynamic.Tables[0].Rows[0][0].error -eq 'ordinary user data')
& $module { $script:TestResponse = '{"Tables":[]}' }
$signal = $adapter.Invoke('AdminFixture','Admin',$conduction,$good,$item)
Assert-Case 'empty result' ($signal.Success() -and ($signal.GetResult() | ConvertFrom-Json).Tables.Count -eq 0)
& $module { $script:TestResponse = '{"Tables":[{"TableName":"QueryStatus","Columns":[{"ColumnName":"Severity","DataType":"Int32"}],"Rows":[[2]]}]}' }
$signal = $adapter.Invoke('AdminFixture','Admin',$conduction,$good,$item)
Assert-Case 'partial failure' (-not $signal.Success() -and -not $signal.HasResult())
& $module { $script:TestResponse = '{"Tables":[{"TableName":"T","Columns":[],"Rows":[[1]]}]}' }
$signal = $adapter.Invoke('AdminFixture','Admin',$conduction,$good,$item)
Assert-Case 'malformed row' (-not $signal.Success() -and -not $signal.HasResult())
& $module { $script:TestResponse = '{"Tables":[],"Errors":[{"message":"secret-command fake-token"}]}' }
$signal = $adapter.Invoke('AdminFixture','Admin',$conduction,$good,$item)
Assert-Case 'embedded error rejected' (-not $signal.Success() -and -not $signal.HasResult())
& $module { $script:TestResponse = '{"Tables":[{"TableName":"T","Columns":[],"Rows":[],"Errors":[{"message":"service failure"}]}]}' }
$signal = $adapter.Invoke('AdminFixture','Admin',$conduction,$good,$item)
Assert-Case 'table protocol error rejected' (-not $signal.Success() -and -not $signal.HasResult())
& $module { $script:TestMode = 'http' }
$signal = $adapter.Invoke('AdminFixture','Admin',$conduction,$good,$item)
Assert-Case 'http failure sanitized' (-not $signal.Success() -and -not $signal.HasResult() -and
    (@($signal.Entries | ForEach-Object Message) -join ' ') -notmatch 'secret-command|fake-token')
& $module { $script:TestMode = 'timeout' }
$beforeCalls = & $module { $script:TestCalls }
$signal = $adapter.Invoke('AdminFixture','Admin',$conduction,$good,$item)
Assert-Case 'timeout unknown and sanitized' (-not $signal.Success() -and -not $signal.HasResult() -and
    (& $module { $script:TestCalls }) -eq ($beforeCalls + 1) -and
    (@($signal.Entries | ForEach-Object Message) -join ' ') -match 'OutcomeUnknown; correlation ADXAdmin;' -and
    (@($signal.Entries | ForEach-Object Message) -join ' ') -notmatch 'secret-command|fake-token')
& $module { $script:TestMode = 'lost' }
$signal = $adapter.Invoke('AdminFixture','Admin',$conduction,$good,$item)
Assert-Case 'unknown outcome sanitized' (-not $signal.Success() -and -not $signal.HasResult() -and
    (@($signal.Entries | ForEach-Object Message) -join ' ') -notmatch 'secret-command|fake-token')
$signal = $adapter.Invoke('AdminFixture','Unknown',$conduction,$good,$item)
Assert-Case 'unsupported activity' (-not $signal.Success() -and -not $signal.HasResult())
"Pass=$pass Fail=$fail Total=$($pass+$fail)"
if ($fail) { exit 1 }
