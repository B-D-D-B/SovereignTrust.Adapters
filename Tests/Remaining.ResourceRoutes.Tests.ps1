using module ../../SovereignTrust.Foundation/Src/PowerShell/SovereignTrust.Foundation.psd1
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '../../SovereignTrust.Foundation/Src/PowerShell/SovereignTrust.Foundation.psd1') -Force
$modules = [ordered]@{
    Queue_AzureStorageQueue = '../Src/Queue/AzureStorageQueue/PowerShell/Queue_AzureStorageQueue.psd1'
    Satellite_AzureApplicationInsights = '../Src/Satellite/AzureApplicationInsights/PowerShell/Satellite_AzureApplicationInsights.psd1'
    Data_AzureDataExplorer = '../Src/Data/AzureDataExplorer/PowerShell/Data_AzureDataExplorer.psd1'
    Data_AzureSql = '../Src/Data/AzureSql/PowerShell/Data_AzureSql.psd1'
    Conduction_ST = '../Src/Conduction/ST/PowerShell/Conduction_ST.psd1'
}
foreach ($path in $modules.Values) { Import-Module (Join-Path $PSScriptRoot $path) -Force -ErrorAction Stop }
function Assert([bool]$ok,[string]$message) { if (-not $ok) { throw $message } }
$passed = 0
$cases = @(
    [pscustomobject]@{ Module='Queue_AzureStorageQueue'; Family='AzureStorageQueue'; ResourceKey='queue'; Field='QueuePath'; Resource='work/messages'; Address='https://queue.example'; Class='Queue_AzureStorageQueue' },
    [pscustomobject]@{ Module='Satellite_AzureApplicationInsights'; Family='AzureApplicationInsights'; ResourceKey='instrumentation'; Field='InstrumentationKey'; Resource='instrumentation'; Address='https://telemetry.example'; Class='Satellite_AzureApplicationInsights' },
    [pscustomobject]@{ Module='Data_AzureDataExplorer'; Family='AzureDataExplorer'; ResourceKey='database'; Field='Database'; Resource='media'; Address='https://adx.example'; Class='Data_AzureDataExplorer' },
    [pscustomobject]@{ Module='Data_AzureSql'; Family='AzureSql'; ResourceKey='database'; Field='Database'; Resource='sda_fusion'; Address='sql.database.windows.net'; Class='Data_AzureSql' },
    [pscustomobject]@{ Module='Conduction_ST'; Family='Conduction_ST'; ResourceKey=$null; Field=$null; Resource=$null; Address='C:/source'; Class='Conduction_ST' }
)
foreach ($case in $cases) {
    $legacy = if ($case.Family -eq 'Conduction_ST') {
        [pscustomobject]@{ Addresses=@($case.Address,'C:/modules') }
    } else { [pscustomobject]@{ Resource=$case.Resource; Addresses=@($case.Address) } }
    $v2 = if ($case.Family -eq 'Conduction_ST') {
        [pscustomobject]@{ SchemaVersion=2; Routes=@([pscustomobject]@{Key='source';Address=$case.Address},[pscustomobject]@{Key='modules';Address='C:/modules'}) }
    } else {
        $resource=[pscustomobject]@{Key=$case.ResourceKey}
        $resource | Add-Member NoteProperty $case.Field $case.Resource
        [pscustomobject]@{ SchemaVersion=2; Resource=@($resource); Routes=@([pscustomobject]@{Key='primary';Address=$case.Address;ResourceKey=$case.ResourceKey}) }
    }
    & (Get-Module $case.Module) {
        $case,$legacy,$v2=$args
        $type=$case.Class -as [type]
        if ($null -eq $type) { throw "$($case.Class) class unavailable." }
        $old=[Activator]::CreateInstance($type)
        $new=[Activator]::CreateInstance($type)
        $oldResult=$old.Construct($legacy) | Select-Object -Last 1
        $newResult=$new.Construct($v2) | Select-Object -Last 1
        if ($oldResult.Failure() -or $newResult.Failure()) { throw "$($case.Family) direct Construct failed." }
        $oldValue=if ($case.Family -eq 'AzureSql') { $old.Configuration } else { $old.Signal.GetJacket().GetResult() }
        $newValue=if ($case.Family -eq 'AzureSql') { $new.Configuration } else { $new.Signal.GetJacket().GetResult() }
        if ((@($oldValue.Addresses) -join [char]0) -cne (@($newValue.Addresses) -join [char]0) -or $oldValue.Resource -cne $newValue.Resource) { throw "$($case.Family) v1/v2 selected values differ." }
        $bad=$v2 | ConvertTo-Json -Depth 20 | ConvertFrom-Json -Depth 20
        $bad.Routes[0].Key='wrong'
        $broken=[Activator]::CreateInstance($type)
        if (-not ($broken.Construct($bad) | Select-Object -Last 1).Failure() -or $null -ne $broken.Signal) { throw "$($case.Family) malformed v2 reached adapter state." }
        if ($case.Family -in @('AzureStorageQueue','Conduction_ST')) {
            $alias=$v2 | ConvertTo-Json -Depth 20 | ConvertFrom-Json -Depth 20
            $alias | Add-Member NoteProperty $(if ($case.Family -eq 'Conduction_ST') { 'resource' } else { 'address' }) '[Memory.SecretAlias|]'
            $invalid=[Activator]::CreateInstance($type)
            $failure=$invalid.Construct($alias) | Select-Object -Last 1
            if (-not $failure.Failure() -or $null -ne $invalid.Signal -or (@($failure.Entries.Message) -join ',') -match 'SecretAlias') { throw "$($case.Family) native reserved alias reached state or leaked." }
        }
    } $case $legacy $v2
    $passed += 3
    if ($case.Family -in @('AzureStorageQueue','Conduction_ST')) { $passed++ }
}
$mappedConduction = & (Get-Module SovereignTrust.Foundation) { [MappedConductionAdapter]::new() }
$opaqueConduction = [pscustomobject]@{ Family='Conduction' }
foreach ($carrier in @($mappedConduction,$opaqueConduction)) {
    $held = & (Get-Module Conduction_ST) { param($value) [Conduction_ST]::new($value) } $carrier
    Assert ([object]::ReferenceEquals($held.MappedAdapter,$carrier)) 'Conduction constructor lost mapped carrier identity.'
    $passed++
}
& (Get-Module Data_AzureSql) {
    $v1=[pscustomobject]@{Resource='sda_fusion';Addresses=@('sql.database.windows.net')}
    $v2=[pscustomobject]@{SchemaVersion=2;Resource=@([pscustomobject]@{Key='database';Database='sda_fusion'});Routes=@([pscustomobject]@{Key='primary';Address='sql.database.windows.net';ResourceKey='database'})}
    $old=[Data_AzureSql]::new(); $new=[Data_AzureSql]::new()
    if ($old.Construct($v1).Failure() -or $new.Construct($v2).Failure()) { throw 'SQL builder fixtures did not construct.' }
    $a=New-AzureSqlConnectionBuilder -Adapter $old
    $b=New-AzureSqlConnectionBuilder -Adapter $new
    if ($a.DataSource -cne $b.DataSource -or $a.InitialCatalog -cne $b.InitialCatalog -or $a.Authentication -cne $b.Authentication) { throw 'SQL v1/v2 builder selected arguments differ.' }
    $bad=[pscustomobject]@{SchemaVersion=2;Resource=@([pscustomobject]@{Key='database';Database='Server=evil;Database=x'});Routes=@([pscustomobject]@{Key='primary';Address='sql.database.windows.net';ResourceKey='database'})}
    if (-not ([Data_AzureSql]::new().Construct($bad)).Failure()) { throw 'SQL v2 connection string entered builder mode.' }
    $connectionString=[pscustomobject]@{Resource='Data Source=legacy.database.windows.net;Initial Catalog=legacy_db;Authentication=Active Directory Default;Encrypt=True;Trust Server Certificate=False'}
    $legacy=[Data_AzureSql]::new()
    if ($legacy.Construct($connectionString).Failure()) { throw 'Native SQL v1 connection-string Construct failed.' }
    $parsed=New-AzureSqlConnectionBuilder -Adapter $legacy
    if ($parsed.DataSource -cne 'legacy.database.windows.net' -or $parsed.InitialCatalog -cne 'legacy_db' -or
        [string]$parsed.Authentication -cne 'ActiveDirectoryDefault' -or [string]$parsed.Encrypt -eq 'False' -or
        $parsed.TrustServerCertificate -or -not [string]::IsNullOrEmpty($parsed.Password)) { throw 'Native SQL v1 connection-string builder changed parsed/security outcome.' }
}
$passed += 3
& (Get-Module Queue_AzureStorageQueue) {
    $script:rrRequests=@()
    $script:rrRealCalls=0
    function Invoke-RestMethod { $script:rrRealCalls++; throw 'Real HTTP reached.' }
    function Invoke-WebRequest { $script:rrRealCalls++; throw 'Real HTTP reached.' }
    function Invoke-MappedAdapter {
        param($Adapter,$Activity,$Signal,$Plan,$ItemSignal)
        $script:rrRequests += [pscustomobject]@{Activity=$Activity;Uri=$Plan.Config.Uri;Method=$Plan.Config.Method}
        $r=[Signal]::Start('RRQueueMock') | Select-Object -Last 1
        $r.SetResult('<QueueMessagesList><QueueMessage><MessageId>id</MessageId><PopReceipt>receipt</PopReceipt></QueueMessage></QueueMessagesList>')
        return $r
    }
    $v1=[pscustomobject]@{Resource='work/messages';Addresses=@('https://queue.example')}
    $v2=[pscustomobject]@{SchemaVersion=2;Resource=@([pscustomobject]@{Key='queue';QueuePath='work/messages'});Routes=@([pscustomobject]@{Key='primary';Address='https://queue.example';ResourceKey='queue'})}
    foreach ($jacket in @($v1,$v2)) {
        $adapter=[Queue_AzureStorageQueue]::new()
        if ($adapter.Construct($jacket).Failure()) { throw 'Queue operation fixture Construct failed.' }
        $signal=[Signal]::Start('RRQueueSignal') | Select-Object -Last 1
        $read=$adapter.Invoke('TestQueue','ReadBatch',$signal,[pscustomobject]@{Config=[pscustomobject]@{PeekDepth=1}},$signal)
        if ($read.Failure() -or @($read.GetResult()).Count -ne 1) { throw 'Queue mocked ReadBatch failed.' }
        $write=$adapter.Invoke('TestQueue','WriteItem',$signal,[pscustomobject]@{Config=[pscustomobject]@{MessageText='hello'}},$signal)
        if ($write.Failure() -or $write.GetResult().MessageId -cne 'id') { throw 'Queue mocked WriteItem failed.' }
    }
    if ($script:rrRequests.Count -ne 4 -or $script:rrRealCalls -ne 0 -or
        $script:rrRequests[0].Uri -cne $script:rrRequests[2].Uri -or
        $script:rrRequests[1].Uri -cne $script:rrRequests[3].Uri -or
        $script:rrRequests[0].Uri -cne 'https://queue.example/work/messages') { throw 'Queue v1/v2 selected request changed.' }
}
$passed += 3
& (Get-Module Satellite_AzureApplicationInsights) {
    $script:rrTelemetryRequests=@()
    $script:rrTelemetryRealCalls=0
    function Invoke-RestMethod { $script:rrTelemetryRealCalls++; throw 'Real telemetry HTTP reached.' }
    function Invoke-WebRequest { $script:rrTelemetryRealCalls++; throw 'Real telemetry HTTP reached.' }
    function Invoke-MappedAdapter {
        param($Adapter,$Activity,$Signal,$Plan,$ItemSignal)
        $r=[Signal]::Start('RRTelemetryMock') | Select-Object -Last 1
        if ($Adapter -eq 'Token.Memory') { $r.SetResult('{"name":"fixture"}') }
        elseif ($Adapter -eq 'Condenser.Rest') {
            $script:rrTelemetryRequests += [pscustomobject]@{Activity=$Activity;Uri=$Plan.Config.Uri;Body=$Plan.Config.Body}
            $r.SetResult([pscustomobject]@{itemsReceived=1;itemsAccepted=1;errors=@()})
        }
        else { return $r.LogCritical('Unexpected telemetry mapped route.') }
        return $r
    }
    $v1=[pscustomobject]@{Resource='instrumentation';Addresses=@('https://telemetry.example')}
    $v2=[pscustomobject]@{SchemaVersion=2;Resource=@([pscustomobject]@{Key='instrumentation';InstrumentationKey='instrumentation'});Routes=@([pscustomobject]@{Key='primary';Address='https://telemetry.example';ResourceKey='instrumentation'})}
    $script:rrTelemetryResults=@()
    foreach ($jacket in @($v1,$v2)) {
        $adapter=[Satellite_AzureApplicationInsights]::new()
        if ($adapter.Construct($jacket).Failure()) { throw 'Telemetry operation fixture Construct failed.' }
        $run=[Signal]::Start('RRTelemetryRun') | Select-Object -Last 1
        $item=[Signal]::Start('RRTelemetryItem') | Select-Object -Last 1
        $null=$item.CreateGraph()
        $plan=[pscustomobject]@{Config=[pscustomobject]@{CountKey='RRTelemetryCount'};Path='Fixture.Body'}
        $result=$adapter.Invoke('Telemetry','SendMessage',$run,$plan,$item)
        if ($result.Failure() -or -not $result.HasResult()) { throw 'Telemetry mocked SendMessage failed.' }
        $script:rrTelemetryResults += $result
    }
    if ($script:rrTelemetryResults.Count -ne 2 -or $script:rrTelemetryResults[0].Failure() -ne $script:rrTelemetryResults[1].Failure() -or
        $script:rrTelemetryResults[0].HasResult() -ne $script:rrTelemetryResults[1].HasResult() -or
        ($script:rrTelemetryResults[0].GetResult() | ConvertTo-Json -Depth 20 -Compress) -cne ($script:rrTelemetryResults[1].GetResult() | ConvertTo-Json -Depth 20 -Compress)) { throw 'Telemetry v1/v2 Signal result parity changed.' }
    if ($script:rrTelemetryRequests.Count -ne 2 -or $script:rrTelemetryRealCalls -ne 0 -or
        $script:rrTelemetryRequests[0].Uri -cne $script:rrTelemetryRequests[1].Uri -or
        $script:rrTelemetryRequests[0].Uri -cne 'https://telemetry.example' -or
        $script:rrTelemetryRequests[0].Body -cne $script:rrTelemetryRequests[1].Body) { throw 'Telemetry v1/v2 selected REST arguments differ.' }
}
$passed += 3
& (Get-Module Data_AzureDataExplorer) {
    $script:rrAdxRequests=@()
    $script:rrAdxRealCalls=0
    function Invoke-RestMethod { $script:rrAdxRealCalls++; throw 'Real ADX HTTP reached.' }
    function Invoke-WebRequest { $script:rrAdxRealCalls++; throw 'Real ADX HTTP reached.' }
    function Invoke-MappedAdapter {
        param($Adapter,$Activity,$Signal,$Plan,$ItemSignal)
        $script:rrAdxRequests += [pscustomobject]@{Activity=$Activity;Uri=$Plan.Config.Uri;Body=$Plan.Config.Body}
        $r=[Signal]::Start('RRAdxMock') | Select-Object -Last 1
        $r.SetResult('mock-adx-result')
        return $r
    }
    $v1=[pscustomobject]@{Resource='media';Addresses=@('https://adx.example')}
    $v2=[pscustomobject]@{SchemaVersion=2;Resource=@([pscustomobject]@{Key='database';Database='media'});Routes=@([pscustomobject]@{Key='primary';Address='https://adx.example';ResourceKey='database'})}
    $script:rrAdxResults=@()
    foreach ($jacket in @($v1,$v2)) {
        $adapter=[Data_AzureDataExplorer]::new()
        if ($adapter.Construct($jacket).Failure()) { throw 'ADX operation fixture Construct failed.' }
        $run=[Signal]::Start('RRAdxRun') | Select-Object -Last 1
        $item=[Signal]::Start('RRAdxItem') | Select-Object -Last 1
        $null=$item.CreateGraph()
        $null=$item.GetPointer().RegisterResultAsSignal('Content',@([pscustomobject]@{Value=1}))
        $plan=[pscustomobject]@{Config=[pscustomobject]@{ADX=[pscustomobject]@{TableName='Rows';MappingName='RowsMapping';ContentKey='Content'}}}
        $result=$adapter.Invoke('Media','WriteItem',$run,$plan,$item)
        if ($result.Failure()) { throw "ADX mocked WriteItem failed: $(@($result.Entries.Message) -join ',')" }
        $script:rrAdxResults += $result
    }
    if ($script:rrAdxResults.Count -ne 2 -or $script:rrAdxResults[0].Failure() -ne $script:rrAdxResults[1].Failure() -or
        $script:rrAdxResults[0].HasResult() -ne $script:rrAdxResults[1].HasResult() -or
        ($script:rrAdxResults[0].HasResult() -and
            ($script:rrAdxResults[0].GetResult() | ConvertTo-Json -Depth 20 -Compress) -cne ($script:rrAdxResults[1].GetResult() | ConvertTo-Json -Depth 20 -Compress))) { throw 'ADX v1/v2 Signal result parity changed.' }
    if ($script:rrAdxRequests.Count -ne 2 -or $script:rrAdxRealCalls -ne 0 -or
        $script:rrAdxRequests[0].Uri -cne $script:rrAdxRequests[1].Uri -or
        $script:rrAdxRequests[0].Uri -cne 'https://adx.example/v1/rest/ingest/media/Rows' -or
        $script:rrAdxRequests[0].Body -cne $script:rrAdxRequests[1].Body) { throw 'ADX v1/v2 selected request differs.' }
}
$passed += 3
Write-Output "PASS $passed/$passed Remaining ResourceRoutes Adapters direct-constructor assertions"
