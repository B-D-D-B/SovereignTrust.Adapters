using module ../../SovereignTrust.Foundation/Src/PowerShell/SovereignTrust.Foundation.psd1

$ErrorActionPreference = 'Stop'
$modulePath = Join-Path $PSScriptRoot '../Src/Storage/AzureStorageAccount/PowerShell/Storage_AzureStorageAccount.psd1'
Import-Module $modulePath -Force -ErrorAction Stop

function Assert-Condition([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

$azureModule = Get-Module Storage_AzureStorageAccount
Assert-Condition ($null -ne $azureModule) 'Azure storage module did not import.'

$foundationModule = Get-Module SovereignTrust.Foundation
& $foundationModule {
    $adapter = [Storage_EmbeddedFileSystem]::new()
    $construct = $adapter.Construct([pscustomobject]@{ Addresses = @((Join-Path $PSScriptRoot '../../SovereignTrust.Foundation/Src/PowerShell')) })
    if (-not $construct.Success()) { throw 'Local storage adapter construction failed.' }

    $signal = [Signal]::Start('StorageExistsTest') | Select-Object -Last 1
    foreach ($case in @(
        @{ Path = 'SovereignTrust.Foundation.psd1'; Expected = $true },
        @{ Path = 'missing-st-storage-test-object.json'; Expected = $false }
    )) {
        $plan = [pscustomobject]@{ VirtualPath = $case.Path; Config = [pscustomobject]@{} }
        $result = $adapter.Invoke('Test', 'Exists', $signal, $plan, $signal)
        if (-not $result.Success() -or -not $result.HasResult() -or $result.GetResult() -isnot [bool] -or $result.GetResult() -ne $case.Expected) {
            throw "Local Exists returned an incorrect opSignal for '$($case.Path)'."
        }
    }
    $suffixPlan = [pscustomobject]@{
        VirtualPath = 'SovereignTrust.Foundation'
        Config = [pscustomobject]@{ PathSuffix = '.psd1' }
    }
    $suffixResult = $adapter.Invoke('Test', 'Exists', $signal, $suffixPlan, $signal)
    if (-not $suffixResult.Success() -or $suffixResult.GetResult() -ne $true) {
        throw 'Local Exists did not apply Config.PathSuffix.'
    }

    function Invoke-RestMethod {
        param($Uri, $Method, $Headers, [switch]$SkipHttpErrorCheck, [string]$StatusCodeVariable, [string]$ResponseHeadersVariable)
        if ($null -ne $script:mockHttpStatuses) {
            $script:mockHttpStatus = $script:mockHttpStatuses[$script:mockHttpCalls]
            $script:mockHttpCalls++
            $script:mockAuthorizationHeaders += $Headers['Authorization']
        }
        if ($StatusCodeVariable) {
            Set-Variable -Name $StatusCodeVariable -Value $script:mockHttpStatus -Scope 1
        }
        if ($ResponseHeadersVariable) {
            Set-Variable -Name $ResponseHeadersVariable -Value @{ 'x-ms-error-code' = 'BlobNotFound' } -Scope 1
        }
        return 'mock-response'
    }

    $restAdapter = [RestCondenser]::new()
    foreach ($case in @(
        @{ Status = 404; Method = 'Head' },
        @{ Status = 202; Method = 'Delete' }
    )) {
        $script:mockHttpStatus = $case.Status
        $restPlan = [pscustomobject]@{ Config = [pscustomobject]@{
            Host = 'https://storage.azure.com/'
            Uri = 'https://example.blob.core.windows.net/test/blob.json'
            Method = $case.Method
            Headers = @{ 'x-ms-version' = '2023-11-03' }
            SkipBearerToken = $true
            ReturnHttpStatus = $true
        } }
        $result = $restAdapter.Invoke('Test', $case.Method, $signal, $restPlan, $signal)
        if (-not $result.Success() -or -not $result.HasResult() -or $result.GetResult().StatusCode -ne $case.Status -or $result.GetResult().Headers['x-ms-error-code'] -ne 'BlobNotFound') {
            throw "REST status passthrough failed for HTTP $($case.Status)."
        }
    }
    $defaultPlan = [pscustomobject]@{ Config = [pscustomobject]@{
        Host = 'https://storage.azure.com/'
        Uri = 'https://example.blob.core.windows.net/test/blob.json'
        Method = 'Get'
        Headers = @{ 'x-ms-version' = '2023-11-03' }
        SkipBearerToken = $true
    } }
    $defaultResult = $restAdapter.Invoke('Test', 'Get', $signal, $defaultPlan, $signal)
    if (-not $defaultResult.Success() -or $defaultResult.GetResult() -ne 'mock-response') {
        throw 'Default REST result shape changed.'
    }

    $script:tokenRequests = 0
    function Resolve-BearerToken {
        param($Address)
        $script:tokenRequests++
        $tokenSignal = [Signal]::Start('MockBearerToken') | Select-Object -Last 1
        $tokenSignal.SetResult("token-$script:tokenRequests")
        return $tokenSignal
    }
    foreach ($case in @(
        @{ Statuses = @(401, 200); Failure = $false; Calls = 2 },
        @{ Statuses = @(401, 401); Failure = $true; Calls = 2 }
    )) {
        $script:mockHttpStatuses = $case.Statuses
        $script:mockHttpCalls = 0
        $script:mockAuthorizationHeaders = @()
        $authPlan = [pscustomobject]@{ Config = [pscustomobject]@{
            Host = 'https://storage.azure.com/'
            Uri = 'https://example.blob.core.windows.net/test/blob.json'
            Method = 'Head'
            Headers = @{ 'x-ms-version' = '2023-11-03' }
            ReturnHttpStatus = $true
        } }
        $authSignal = [Signal]::Start('RestAuthTest') | Select-Object -Last 1
        $authJacket = [Signal]::Start('RestAuthJacket') | Select-Object -Last 1
        $authGraph = ([Graph]::Start('RestAuthGraph', $authJacket, $false) | Select-Object -Last 1).GetResult()
        $null = $authJacket.SetPointer($authGraph)
        $null = $authSignal.SetJacket($authJacket)
        $tokenProbe = $restAdapter.ResolveBearerToken($authSignal, $authPlan, $false)
        if ($tokenProbe.Failure() -or -not $tokenProbe.HasResult()) {
            throw "Mock token setup failed: $($tokenProbe.Entries | Format-List * -Force | Out-String)"
        }
        $tokenRequestsBeforeInvoke = $script:tokenRequests
        $authResult = $restAdapter.Invoke('Test', 'Head', $authSignal, $authPlan, $authSignal)
        if ($authResult.Failure() -ne $case.Failure -or $script:mockHttpCalls -ne $case.Calls -or $script:tokenRequests -ne ($tokenRequestsBeforeInvoke + 1) -or $script:mockAuthorizationHeaders[0] -eq $script:mockAuthorizationHeaders[1]) {
            throw "REST authentication refresh failed for statuses $($case.Statuses): failure=$($authResult.Failure()) calls=$script:mockHttpCalls tokens=$script:tokenRequests entries=$($authResult.Entries | Format-List * -Force | Out-String)."
        }
        if (-not $case.Failure -and $authResult.GetResult().StatusCode -ne 200) {
            throw 'REST authentication retry did not return the successful status.'
        }
    }
    $script:mockHttpStatuses = $null
}

& $azureModule {
    $script:mockStatuses = @()
    $script:mockCalls = @()

    function Invoke-MappedAdapter {
        param($Adapter, $Activity, $Signal, $Plan, $ItemSignal)
        $script:mockCalls += [pscustomobject]@{
            Adapter = $Adapter
            Activity = $Activity
            Method = $Plan.Config.Method
            Uri = $Plan.Config.Uri
            ReturnHttpStatus = $Plan.Config.ReturnHttpStatus
            TargetPath = $Plan.Config.TargetPath
        }
        $status = $script:mockStatuses[$script:mockCalls.Count - 1]
        $result = [Signal]::Start('MockAzureRest', $ItemSignal) | Select-Object -Last 1
        if ($Activity -eq 'Get') {
            if ($script:mockReadFailure) {
                $result.LogCritical('Simulated download failure') | Out-Null
                return $result
            }
            $result.SetResult('mock-read-content')
            return $result
        }
        if ($status -eq 'transport') {
            $result.LogCritical('Simulated transport failure') | Out-Null
        }
        else {
            $statusCode = if ($status -eq 'container404') { 404 } else { [int]$status }
            $errorCode = if ($status -eq 'container404') { 'ContainerNotFound' } else { 'BlobNotFound' }
            $result.SetResult(@{ StatusCode = $statusCode; Headers = @{ 'x-ms-error-code' = $errorCode } })
        }
        return $result
    }

    $adapter = [Storage_AzureStorageAccount]::new()
    $construct = $adapter.Construct([pscustomobject]@{
        Addresses = @('https://first.blob.core.windows.net', 'https://second.blob.core.windows.net')
        Resource = 'test'
    })
    if (-not $construct.Success()) { throw 'Azure storage adapter construction failed.' }

    $signal = [Signal]::Start('AzureStorageTest') | Select-Object -Last 1
    $plan = [pscustomobject]@{ Config = [pscustomobject]@{ VirtualPath = 'folder/blob.json' } }
    $script:mockCalls = @()
    $readResult = $adapter.Invoke('Test', 'Read', $signal, $plan, $signal)
    if (-not $readResult.Success() -or -not $readResult.HasResult() -or $readResult.GetResult() -ne 'mock-read-content') {
        throw 'Azure Read did not return the mocked blob content.'
    }
    if ($script:mockCalls.Count -ne 1 -or $script:mockCalls[0].Adapter -ne 'Condenser.Rest' -or $script:mockCalls[0].Activity -ne 'Get' -or $script:mockCalls[0].Uri -ne 'https://first.blob.core.windows.net/test/folder/blob.json') {
        throw 'Azure Read did not include Resource in the REST URI.'
    }
    $targetPath = Join-Path ([IO.Path]::GetTempPath()) ('st-azure-target-' + [guid]::NewGuid().ToString('N') + '.bin')
    $targetPlan = [pscustomobject]@{ Config = [pscustomobject]@{ VirtualPath = 'folder/blob.json'; TargetPath = $targetPath; Content = 'fallback' } }
    $script:mockCalls = @()
    $script:mockReadFailure = $true
    $failedTarget = $adapter.Invoke('Test', 'Read', $signal, $targetPlan, $signal)
    if (-not $failedTarget.Failure() -or $failedTarget.HasResult() -or $script:mockCalls.Count -ne 2 -or $script:mockCalls[0].TargetPath -ne $targetPath) {
        throw 'Azure failed target read used fallback or did not forward TargetPath.'
    }
    $script:mockReadFailure = $false
    $script:mockCalls = @()
    $successfulTarget = $adapter.Invoke('Test', 'Read', $signal, $targetPlan, $signal)
    if (-not $successfulTarget.Success() -or $script:mockCalls[0].TargetPath -ne $targetPath) {
        throw 'Azure target read did not forward TargetPath.'
    }
    foreach ($case in @(
        @{ Activity = 'Exists'; Statuses = @(200); Expected = $true; Failure = $false; Calls = 1 },
        @{ Activity = 'Exists'; Statuses = @(404, 404); Expected = $false; Failure = $false; Calls = 2 },
        @{ Activity = 'Exists'; Statuses = @(404, 200); Expected = $true; Failure = $false; Calls = 2 },
        @{ Activity = 'Exists'; Statuses = @(403); Expected = $null; Failure = $true; Calls = 1 },
        @{ Activity = 'Exists'; Statuses = @('container404'); Expected = $null; Failure = $true; Calls = 1 },
        @{ Activity = 'Exists'; Statuses = @('transport'); Expected = $null; Failure = $true; Calls = 1 },
        @{ Activity = 'Delete'; Statuses = @(202); Expected = $true; Failure = $false; Calls = 1 },
        @{ Activity = 'Delete'; Statuses = @(404); Expected = $false; Failure = $false; Calls = 1 },
        @{ Activity = 'Delete'; Statuses = @(409); Expected = $null; Failure = $true; Calls = 1 },
        @{ Activity = 'Delete'; Statuses = @('container404'); Expected = $null; Failure = $true; Calls = 1 }
    )) {
        $script:mockStatuses = $case.Statuses
        $script:mockCalls = @()
        $result = $adapter.Invoke('Test', $case.Activity, $signal, $plan, $signal)
        if ($case.Failure) {
            if (-not $result.Failure()) { throw "$($case.Activity) HTTP $($case.Statuses) should have failed." }
        }
        elseif (-not $result.Success() -or -not $result.HasResult() -or $result.GetResult() -isnot [bool] -or $result.GetResult() -ne $case.Expected) {
            throw "$($case.Activity) HTTP $($case.Statuses) returned an incorrect opSignal."
        }
        if ($script:mockCalls.Count -ne $case.Calls) { throw "$($case.Activity) used the wrong number of addresses." }
        foreach ($call in $script:mockCalls) {
            if ($call.Adapter -ne 'Condenser.Rest' -or $call.Method -ne $case.Activity.Replace('Exists', 'Head') -or -not $call.ReturnHttpStatus -or $call.Uri -notlike 'https://*.blob.core.windows.net/test/folder/blob.json') {
                throw "$($case.Activity) built an incorrect REST request."
            }
        }
    }
    $script:mockStatuses = @(200)
    $script:mockCalls = @()
    $suffixPlan = [pscustomobject]@{ Config = [pscustomobject]@{
        VirtualPath = 'folder/blob'
        PathSuffix = '.json'
    } }
    $suffixResult = $adapter.Invoke('Test', 'Exists', $signal, $suffixPlan, $signal)
    if (-not $suffixResult.Success() -or $suffixResult.GetResult() -ne $true -or $script:mockCalls[0].Uri -ne 'https://first.blob.core.windows.net/test/folder/blob.json') {
        throw 'Azure Exists did not apply Config.PathSuffix.'
    }
    $specialPlan = [pscustomobject]@{ Config = [pscustomobject]@{ VirtualPath = 'folder/blob#v1?.json' } }
    foreach ($activity in 'Exists', 'Delete') {
        $script:mockStatuses = if ($activity -eq 'Exists') { @(200) } else { @(202) }
        $script:mockCalls = @()
        $result = $adapter.Invoke('Test', $activity, $signal, $specialPlan, $signal)
        if (-not $result.Success() -or $result.GetResult() -ne $true -or $script:mockCalls[0].Uri -ne 'https://first.blob.core.windows.net/test/folder/blob%23v1%3F.json') {
            throw "Azure $activity did not encode the blob path safely."
        }
    }
}

Write-Output 'Storage Read, Exists and Delete adapter checks passed.'
