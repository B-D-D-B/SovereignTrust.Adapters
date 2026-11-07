using module ../../SovereignTrust.Foundation/Src/PowerShell/SovereignTrust.Foundation.psd1
param([string]$ConfigPath)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '../Src/Storage/AzureStorageAccount/PowerShell/Storage_AzureStorageAccount.psd1') -Force
Import-Module (Join-Path $PSScriptRoot '../Src/Storage/LocalFileSystem/PowerShell/SovereignTrust.Adapters.Storage.LocalFileSystem.psd1') -Force
function Assert([bool]$condition, [string]$message) { if (-not $condition) { throw $message } }
$passes = 0

$azure = Get-Module Storage_AzureStorageAccount
& $azure {
    $script:realHttpCalls = 0
    function Invoke-RestMethod { $script:realHttpCalls++; throw 'Real HTTP boundary reached.' }
    function Invoke-WebRequest { $script:realHttpCalls++; throw 'Real HTTP boundary reached.' }
    function Invoke-MappedAdapter {
        param($Adapter, $Activity, $Signal, $Plan, $ItemSignal)
        $script:requests += [pscustomobject]@{ Adapter = $Adapter; Activity = $Activity; Uri = $Plan.Config.Uri; Method = $Plan.Config.Method }
        $r = [Signal]::Start('MockStorageRequest', $ItemSignal) | Select-Object -Last 1
        $r.SetResult('mock-content')
        return $r
    }
    $script:requests = @()
    $v1 = [pscustomobject]@{ Resource = 'box'; Addresses = @('https://account.blob.core.windows.net') }
    $v2 = [pscustomobject]@{ SchemaVersion = 2; Resource = @([pscustomobject]@{ Key = 'container'; Container = 'box' }); Routes = @([pscustomobject]@{ Key = 'primary'; Address = 'https://account.blob.core.windows.net'; ResourceKey = 'container' }) }
    foreach ($j in @($v1,$v2)) {
        $adapter = [Storage_AzureStorageAccount]::new()
        $construct = $adapter.Construct($j)
        if ($construct.Failure()) { throw 'Azure direct construction failed.' }
        $signal = [Signal]::Start('AzureRR') | Select-Object -Last 1
        $read = $adapter.Invoke('RemoteContent','Read',$signal,[pscustomobject]@{ Config = [pscustomobject]@{ VirtualPath = 'file.txt' } },$signal)
        if ($read.Failure() -or $read.GetResult() -ne 'mock-content') { throw 'Azure mocked Read result differs.' }
    }
    if ($script:requests.Count -ne 2 -or $script:requests[0].Uri -cne $script:requests[1].Uri -or
        $script:requests[0].Uri -cne 'https://account.blob.core.windows.net/box/file.txt') { throw 'Azure v1/v2 selected URI differs.' }
    $before = $script:requests.Count
    foreach ($bad in @(
        [pscustomobject]@{ SchemaVersion = 2; Resource = @([pscustomobject]@{ Key = 'container'; Container = 'box' }); Routes = @([pscustomobject]@{ Key = 'wrong'; Address = 'https://account.blob.core.windows.net'; ResourceKey = 'container' }) },
        [pscustomobject]@{ SchemaVersion = 2; Resource = @([pscustomobject]@{ Key = 'container'; Container = 'box' }); Routes = @([pscustomobject]@{ Key = 'primary'; Address = 'https://account.blob.core.windows.net'; ResourceKey = 'missing' }) },
        [pscustomobject]@{ SchemaVersion = 2; Resource = @([pscustomobject]@{ Key = 'container'; Container = '[Memory.Container|]' }); Routes = @([pscustomobject]@{ Key = 'primary'; Address = 'https://account.blob.core.windows.net'; ResourceKey = 'container' }) },
        [pscustomobject]@{ SchemaVersion = 2; Resource = @([pscustomobject]@{ Key = 'container'; Container = 'box' }); Routes = @([pscustomobject]@{ Key = 'primary'; Address = 'https://account.blob.core.windows.net'; ResourceKey = 'container' }); Addresses = @('https://wrong') },
        [pscustomobject]@{ SchemaVersion = 2; Resource = @([pscustomobject]@{ Key = 'container'; Container = 'box'; Credentials = $null }); Routes = @([pscustomobject]@{ Key = 'primary'; Address = 'https://account.blob.core.windows.net'; ResourceKey = 'container' }) },
        [pscustomobject]@{ SchemaVersion = 2; Resource = @([pscustomobject]@{ Key = 'container'; Container = 'box' }); Routes = @([pscustomobject]@{ Key = 'primary'; Address = 'https://account.blob.core.windows.net'; ResourceKey = 'container'; ApiKind = $null }) }
    )) {
        $adapter = [Storage_AzureStorageAccount]::new()
        if (-not $adapter.Construct($bad).Failure()) { throw 'Malformed Azure direct v2 was admitted.' }
    }
    if ($script:requests.Count -ne $before) { throw 'Malformed Azure v2 reached mocked request.' }

    $script:helperCalls = @()
    function New-HelperResult($operation,$resource,$addresses,$virtualPath) {
        $script:helperCalls += [pscustomobject]@{ Operation=$operation; Resource=$resource; Address=@($addresses)[0]; VirtualPath=$virtualPath }
        $r = [Signal]::Start("Mock$operation") | Select-Object -Last 1
        $r.SetResult("$operation-result")
        return $r
    }
    function Invoke-AzureStorageAccount_WriteObject { param($ConductionSignal,$Signal,$ItemSignal,$Plan,$Content,$VirtualPath,$Resource,$Addresses) New-HelperResult 'Write' $Resource $Addresses $VirtualPath }
    function Invoke-AzureStorageAccount_ListObject { param($ConductionSignal,$ItemSignal,$Plan,$VirtualPath,$Resource,$Addresses) New-HelperResult 'List' $Resource $Addresses $VirtualPath }
    function Invoke-AzureStorageAccount_ExistsObject { param($ConductionSignal,$Signal,$ItemSignal,$Plan,$VirtualPath,$Resource,$Addresses) New-HelperResult 'Exists' $Resource $Addresses $VirtualPath }
    function Invoke-AzureStorageAccount_DeleteObject { param($ConductionSignal,$Signal,$ItemSignal,$Plan,$VirtualPath,$Resource,$Addresses) New-HelperResult 'Delete' $Resource $Addresses $VirtualPath }
    $fixtures = @($v1,$v2)
    foreach ($activity in @('Write','List','Exists','Delete')) {
        $start = $script:helperCalls.Count
        foreach ($j in $fixtures) {
            $adapter = [Storage_AzureStorageAccount]::new()
            if ($adapter.Construct($j).Failure()) { throw "Azure $activity construction failed." }
            $signal = [Signal]::Start("Azure$activity") | Select-Object -Last 1
            $plan = [pscustomobject]@{ Config = [pscustomobject]@{ VirtualPath = 'file.txt'; Content = 'content' } }
            $result = $adapter.Invoke('RemoteContent',$activity,$signal,$plan,$signal)
            if ($result.Failure() -or $result.GetResult() -cne "$activity-result") { throw "Azure $activity mocked result differs." }
        }
        $a=$script:helperCalls[$start]; $b=$script:helperCalls[$start+1]
        if ($a.Operation -cne $activity -or $a.Resource -cne $b.Resource -or $a.Address -cne $b.Address -or $a.VirtualPath -cne $b.VirtualPath -or $b.Resource -cne 'box') { throw "Azure $activity v1/v2 helper arguments differ." }
    }
    if ($script:helperCalls.Count -ne 8 -or $script:requests.Count -ne 2 -or $script:realHttpCalls -ne 0) { throw 'Azure provider guard/call count changed.' }
} 
$passes += 18

$foundation = Get-Module SovereignTrust.Foundation
& $foundation {
    . $args[0]
    $adapter = New-Object Storage_AzureStorageAccount
    $jacket = [pscustomobject]@{ SchemaVersion = 2; Resource = @([pscustomobject]@{ Key = 'container'; Container = 'box' }); Routes = @([pscustomobject]@{ Key = 'primary'; Address = 'https://account.blob.core.windows.net'; ResourceKey = 'container' }) }
    $construct = $adapter.Construct($jacket)
    if ($construct.Failure() -or $adapter.Signal.GetJacket().GetResult().Resource -cne 'box' -or @($adapter.Signal.GetJacket().GetResult().Addresses)[0] -cne 'https://account.blob.core.windows.net') { throw 'Alternate Azure class direct v2 Construct failed.' }
} (Join-Path $PSScriptRoot '../Src/Storage/AzureStorageAccount/PowerShell/Storage_AzureStorageAccount.ps1')
$passes++

$local = Get-Module SovereignTrust.Adapters.Storage.LocalFileSystem
Assert ($null -ne $local) 'LocalFileSystem module failed to import.'
$root = Join-Path ([IO.Path]::GetTempPath()) ('st-rr-local-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null
try {
    [IO.File]::WriteAllText((Join-Path $root 'sample.json'), '{"value":7}')
    [IO.File]::WriteAllText((Join-Path $root 'sample.xml'), '<root><value>7</value></root>')
    & $local {
        $root = $args[0]
        $adapter = [Storage_LocalFileSystem]::new()
        $v2 = [pscustomobject]@{ SchemaVersion = 2; Routes = @([pscustomobject]@{ Key = 'primary'; Address = (Join-Path $root 'unused-route') }) }
        if ($adapter.Construct($v2).Failure()) { throw 'LocalFileSystem direct v2 construction failed.' }
        $read = $adapter.ReadObjectAsJson($root,'sample.json')
        if ($read.Failure() -or $read.GetResult().value -ne 7) { throw 'LocalFileSystem caller-folder JSON read changed.' }
        $xml = $adapter.ReadObjectAsXml($root,'sample.xml')
        if ($xml.Failure() -or $xml.GetResult().root.value -ne '7') { throw 'LocalFileSystem caller-folder XML read changed.' }
        $legacy = [Storage_LocalFileSystem]::new()
        if ($legacy.Construct([pscustomobject]@{ Address = $root }).Failure() -or $legacy.ReadObjectAsJson($root,'sample.json').GetResult().value -ne 7 -or $legacy.ReadObjectAsXml($root,'sample.xml').GetResult().root.value -ne '7') { throw 'LocalFileSystem v1/v2 JSON/XML parity failed.' }
        $listed = $adapter.ListDirectoryObjects($root)
        if ($listed.Failure() -or 'sample.json' -notin @($listed.GetResult()) -or 'sample.xml' -notin @($legacy.ListDirectoryObjects($root).GetResult())) { throw 'LocalFileSystem caller-folder list changed.' }
        $deleted = $adapter.DeleteFile($root,'sample.json')
        if ($deleted.Failure() -or (Test-Path -LiteralPath (Join-Path $root 'sample.json'))) { throw 'LocalFileSystem caller-folder delete changed.' }
        $bad = [pscustomobject]@{ SchemaVersion = 2; Routes = @([pscustomobject]@{ Key = 'primary'; Address = '' }) }
        if (-not ([Storage_LocalFileSystem]::new()).Construct($bad).Failure()) { throw 'LocalFileSystem malformed v2 admitted.' }
        if (-not (Test-Path -LiteralPath (Join-Path $root 'sample.xml'))) { throw 'Malformed LocalFileSystem v2 modified file.' }
    } $root
    $passes += 8
}
finally { Remove-Item -LiteralPath $root -Recurse -Force }

if ($ConfigPath) {
    $config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json -Depth 100
    foreach ($name in @('RemoteMedia','RemoteContent')) {
        $slot = $config.Agents[0].Roles[0].Adapters | Where-Object Name -CEQ $name | Select-Object -First 1
        $normalized = Resolve-StorageResourceRoutesJacket -Jacket $slot -Family AzureStorageAccount -AllowUnresolved
        Assert ($normalized.Success() -and $normalized.HasResult()) "Config Azure v2 invalid: $name"
        $passes++
    }
}
"PASS $passes/$passes Adapters storage Resource/Routes assertions (mocked Azure; local filesystem)"
