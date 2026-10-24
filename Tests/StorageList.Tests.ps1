using module ../../SovereignTrust.Foundation/Src/PowerShell/SovereignTrust.Foundation.psd1

$ErrorActionPreference = 'Stop'
function Assert([bool]$condition, [string]$message) {
    if (-not $condition) { throw $message }
}
function Assert-ListShape($signal, [int]$count) {
    Assert ($signal.Success() -and $signal.HasResult()) 'List did not return a successful result.'
    $result = $signal.GetResult()
    Assert ($result -is [pscustomobject] -and $result.Items -is [array] -and $result.Count -eq $count) 'List result shape/count is wrong.'
    $json = $result | ConvertTo-Json -Depth 10 | ConvertFrom-Json
    Assert ($json.Items -is [array] -and $json.Items.Count -eq $count) 'List JSON round-trip lost Items array.'
    foreach ($item in $result.Items) {
        Assert ($item -is [pscustomobject] -and @($item.PSObject.Properties.Name).Count -eq 4) 'List item shape is wrong.'
        foreach ($key in 'FileName', 'VirtualPath', 'DateTime', 'Size') {
            Assert ($null -ne $item.PSObject.Properties[$key]) "Missing List item property $key."
        }
        Assert ($item.FileName -is [string] -and $item.VirtualPath -is [string]) 'List path fields are not strings.'
        Assert ($null -eq $item.Size -or ($item.Size -is [long] -and $item.Size -ge 0)) 'List Size is not null or nonnegative Int64.'
        if ($null -ne $item.DateTime) {
            Assert ($item.DateTime -is [string] -and $item.DateTime.EndsWith('Z')) 'List DateTime is not a UTC string.'
            $parsed = [datetimeoffset]::MinValue
            Assert ([datetimeoffset]::TryParseExact($item.DateTime, 'o', [Globalization.CultureInfo]::InvariantCulture,
                [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$parsed)) 'List DateTime is not ISO-8601.'
        }
    }
}

Import-Module (Join-Path $PSScriptRoot '../Src/Storage/AzureStorageAccount/PowerShell/Storage_AzureStorageAccount.psd1') -Force
$azureModule = Get-Module Storage_AzureStorageAccount
& $azureModule {
    function Invoke-MappedAdapter {
        param($Adapter, $Activity, $Signal, $Plan, $ItemSignal)
        $script:calls += $Plan.Config
        $result = [Signal]::Start('ListBlobMock', $ItemSignal) | Select-Object -Last 1
        $index = $script:calls.Count - 1
        if ($script:failPage -eq $index) { $result.LogCritical('Mock page failed') | Out-Null }
        else { $result.SetResult($script:pages[$index]) }
        return $result
    }
    function Invoke-Case($config) {
        $script:calls = @()
        $signal = [Signal]::Start('AzureListFixture') | Select-Object -Last 1
        $adapter = [Storage_AzureStorageAccount]::new()
        $null = $adapter.Construct([pscustomobject]@{
            Addresses = @('https://account.blob.core.windows.net'); Resource = 'photos'
        })
        return $adapter.Invoke('Test', 'List', $signal, [pscustomobject]@{ Config = [pscustomobject]$config }, $signal)
    }
    $script:failPage = -1
    $script:pages = @(
        '<EnumerationResults><Blobs><Blob><Name>folder/a.jpg</Name><Properties><Last-Modified>Wed, 01 Jan 2025 00:00:00 GMT</Last-Modified><Content-Length>2</Content-Length></Properties></Blob><Blob><Name>folder/sub/b.jpg</Name><Properties><Last-Modified>Thu, 02 Jan 2025 00:00:00 GMT</Last-Modified><Content-Length>10</Content-Length></Properties></Blob></Blobs><NextMarker>second</NextMarker></EnumerationResults>',
        '<EnumerationResults><Blobs><Blob><Name>folder/c.png</Name><Properties><Content-Length>5</Content-Length></Properties></Blob></Blobs><NextMarker></NextMarker></EnumerationResults>'
    )
    $result = Invoke-Case @{ VirtualPath = 'folder'; Filter = '*.jpg' }
    Assert-ListShape $result 2
    Assert (($result.GetResult()).Items[0].FileName -eq 'b.jpg') 'Default FileName descending sort failed.'
    Assert ($script:calls.Count -eq 2 -and $script:calls[0].Uri -match 'prefix=folder%2F' -and
        $script:calls[1].Uri -match 'marker=second' -and $script:calls[0].Host -eq 'https://storage.azure.com/' -and
        $script:calls[0].CacheAccessToken -and $script:calls[0].Method -eq 'Get') 'Blob List request/pagination contract failed.'
    $result = Invoke-Case @{ VirtualPath = 'folder'; SortBy = 'Size'; SortDirection = 'Ascending' }
    Assert-ListShape $result 3
    Assert ((@($result.GetResult().Items.FileName) -join ',') -eq 'a.jpg,c.png,b.jpg') 'Numeric ascending Size sort failed.'
    $result = Invoke-Case @{ VirtualPath = 'folder'; SortBy = 'DateTime'; SortDirection = 'Descending' }
    Assert ((@($result.GetResult().Items.FileName) -join ',') -eq 'b.jpg,a.jpg,c.png') 'DateTime sort/null-last failed.'
    $script:pages = @('<EnumerationResults><Blobs><Blob><Name>folder/a.jpg</Name><Properties><Last-Modified>Wed, 01 Jan 2025 00:00:00 GMT</Last-Modified><Content-Length>2</Content-Length></Properties></Blob><Blob><Name>folder/A.jpg</Name><Properties><Last-Modified>Wed, 01 Jan 2025 00:00:00 GMT</Last-Modified><Content-Length>2</Content-Length></Properties></Blob><Blob><Name>folder/b.jpg</Name><Properties><Last-Modified>Wed, 01 Jan 2025 00:00:00 GMT</Last-Modified><Content-Length>2</Content-Length></Properties></Blob><Blob><Name>folder/c.jpg</Name><Properties></Properties></Blob></Blobs><NextMarker></NextMarker></EnumerationResults>')
    foreach ($key in 'Size', 'DateTime') {
        foreach ($order in 'Ascending', 'Descending') {
            $result = Invoke-Case @{ VirtualPath = 'folder'; SortBy = $key; SortDirection = $order }
            Assert-ListShape $result 4
            Assert ((@($result.GetResult().Items.FileName) -join ',') -ceq 'A.jpg,a.jpg,b.jpg,c.jpg') "Blob $key $order tie/null-last order failed."
        }
    }
    $script:pages = @([xml]$script:pages[0])
    $result = Invoke-Case @{ VirtualPath = 'folder'; Filter = 'A.jpg' }
    Assert-ListShape $result 2
    $script:pages = @('<EnumerationResults><Blobs><BlobPrefix><Name>folder/sub/</Name></BlobPrefix><BlobPrefix><Name>folder/other/</Name></BlobPrefix></Blobs><NextMarker></NextMarker></EnumerationResults>')
    $result = Invoke-Case @{ VirtualPath = 'folder'; Type = 'Directory' }
    Assert-ListShape $result 2
    Assert ($script:calls[0].Uri -match 'delimiter=%2F' -and $result.GetResult().Items[0].Size -eq $null -and
        $result.GetResult().Items[0].VirtualPath.EndsWith('/')) 'Blob immediate-directory contract failed.'
    $result = Invoke-Case @{ VirtualPath = 'folder'; Type = 'Directory'; Filter = 'sub' }
    Assert-ListShape $result 1
    Assert ($result.GetResult().Items[0].FileName -eq 'sub') 'Directory FileName filtering failed.'
    $script:pages = @('<EnumerationResults><Blobs><Blob><Name>folder-peer/x.jpg</Name><Properties><Content-Length>1</Content-Length></Properties></Blob></Blobs><NextMarker></NextMarker></EnumerationResults>')
    $result = Invoke-Case @{ VirtualPath = 'folder' }
    Assert ($result.Failure() -and -not $result.HasResult()) 'Blob peer prefix escaped the selected folder.'
    foreach ($bad in @(@{ SortBy = 'Time' }, @{ SortDirection = 'Reverse' }, @{ Type = 'Secret' })) {
        $result = Invoke-Case $bad
        Assert ($result.Failure() -and $script:calls.Count -eq 0) 'Invalid List option reached blob provider.'
    }
    $script:pages = @('<EnumerationResults><Blobs></Blobs><NextMarker></NextMarker></EnumerationResults>')
    $result = Invoke-Case @{}
    Assert-ListShape $result 0
    Assert ($script:calls[0].Uri -notmatch 'prefix=') 'Empty blob scope was not the container root.'
    $script:pages = @(
        '<EnumerationResults><Blobs></Blobs><NextMarker>second</NextMarker></EnumerationResults>',
        '<EnumerationResults><Blobs></Blobs><NextMarker>second</NextMarker></EnumerationResults>'
    )
    $result = Invoke-Case @{}
    Assert ($result.Failure() -and -not $result.HasResult()) 'Repeated blob marker exposed a partial result.'
    $script:failPage = 1
    $result = Invoke-Case @{}
    Assert ($result.Failure() -and -not $result.HasResult()) 'Failed later blob page exposed a partial result.'
    $script:failPage = -1
    foreach ($badPage in @('<not-results/>', '<EnumerationResults><Blobs>')) {
        $script:pages = @($badPage)
        $result = Invoke-Case @{}
        Assert ($result.Failure() -and -not $result.HasResult()) 'Malformed blob XML exposed a result.'
    }
}

Import-Module (Join-Path $PSScriptRoot '../Src/Storage/AzureKeyVault/PowerShell/Storage_AzureKeyVault.psd1') -Force
$vaultModule = Get-Module Storage_AzureKeyVault
& $vaultModule {
    function Invoke-MappedAdapter {
        param($Adapter, $Activity, $Signal, $Plan, $ItemSignal)
        $script:calls += $Plan.Config
        $result = [Signal]::Start('ListVaultMock', $ItemSignal) | Select-Object -Last 1
        $index = $script:calls.Count - 1
        if ($script:failPage -eq $index) { $result.LogCritical('Mock page failed') | Out-Null }
        else { $result.SetResult($script:pages[$index]) }
        return $result
    }
    function Invoke-Case($config) {
        $script:calls = @()
        $signal = [Signal]::Start('VaultListFixture') | Select-Object -Last 1
        $adapter = [Storage_AzureKeyVault]::new()
        $null = $adapter.Construct([pscustomobject]@{ Addresses = @('https://vault.vault.azure.net/') })
        return $adapter.Invoke('Test', 'List', $signal, [pscustomobject]@{ Config = [pscustomobject]$config }, $signal)
    }
    $script:failPage = -1
    $script:pages = @(
        [pscustomobject]@{ value = @(
            [pscustomobject]@{ id = 'https://vault.vault.azure.net/secrets/app-one'; attributes = [pscustomobject]@{ updated = 1735689600 } },
            [pscustomobject]@{ id = 'https://vault.vault.azure.net/secrets/other'; attributes = [pscustomobject]@{ updated = 1735776000 } }
        ); nextLink = 'https://vault.vault.azure.net/secrets?api-version=7.4&skiptoken=2' },
        [pscustomobject]@{ value = @(
            [pscustomobject]@{ id = 'https://vault.vault.azure.net/secrets/app-two'; attributes = [pscustomobject]@{ updated = 1735862400 } }
        ); nextLink = $null }
    )
    $result = Invoke-Case @{ VirtualPath = 'app'; Filter = 'app-*' }
    Assert-ListShape $result 2
    Assert ((@($result.GetResult().Items.FileName) -join ',') -eq 'app-two,app-one') 'Vault raw-prefix/default sort failed.'
    Assert ($null -eq $result.GetResult().Items[0].Size -and $script:calls.Count -eq 2 -and
        $script:calls[0].Uri -eq 'https://vault.vault.azure.net/secrets?api-version=7.4' -and
        $script:calls[1].Uri -match 'skiptoken=2' -and $script:calls[0].CacheAccessToken) 'Vault metadata/page request failed.'
    $result = Invoke-Case @{ VirtualPath = 'app'; SortBy = 'DateTime'; SortDirection = 'Ascending' }
    Assert ((@($result.GetResult().Items.FileName) -join ',') -eq 'app-one,app-two') 'Vault DateTime ascending failed.'
    $result = Invoke-Case @{ VirtualPath = 'app'; SortBy = 'Size'; SortDirection = 'Ascending' }
    Assert ((@($result.GetResult().Items.FileName) -join ',') -eq 'app-one,app-two') 'Vault null Size ordering failed.'
    $script:pages = @([pscustomobject]@{ value = @(
        [pscustomobject]@{ id = 'https://vault.vault.azure.net/secrets/app-a'; attributes = [pscustomobject]@{ updated = 1735689600 } },
        [pscustomobject]@{ id = 'https://vault.vault.azure.net/secrets/app-A'; attributes = [pscustomobject]@{ updated = 1735689600 } },
        [pscustomobject]@{ id = 'https://vault.vault.azure.net/secrets/app-z' }
    ); nextLink = $null })
    foreach ($order in 'Ascending', 'Descending') {
        $result = Invoke-Case @{ VirtualPath = 'app'; SortBy = 'DateTime'; SortDirection = $order }
        Assert-ListShape $result 3
        Assert ((@($result.GetResult().Items.FileName) -join ',') -ceq 'app-A,app-a,app-z') "Vault $order DateTime tie/null-last failed."
        Assert ($null -eq $result.GetResult().Items[2].DateTime) 'Vault missing updated metadata gained a timestamp.'
    }
    $script:pages = @(($script:pages[0] | ConvertTo-Json -Depth 10 -Compress))
    $result = Invoke-Case @{ VirtualPath = 'app'; SortBy = 'FileName'; SortDirection = 'Ascending' }
    Assert-ListShape $result 3
    $script:pages = @($script:pages[0] | ConvertFrom-Json -Depth 20)
    $result = Invoke-Case @{ Type = 'Directory' }
    Assert-ListShape $result 0
    Assert ($script:calls.Count -eq 0) 'Vault Directory issued a provider request.'
    foreach ($bad in @(@{ SortBy = 'Time' }, @{ SortDirection = 'Reverse' }, @{ Type = 'Secret' })) {
        $result = Invoke-Case $bad
        Assert ($result.Failure() -and $script:calls.Count -eq 0) 'Invalid List option reached vault provider.'
    }
    $script:pages[0].nextLink = 'https://evil.example/secrets?api-version=7.4'
    $result = Invoke-Case @{}
    Assert ($result.Failure() -and -not $result.HasResult()) 'Off-vault continuation exposed a result.'
    $script:pages[0].nextLink = 'https://vault.vault.azure.net/secrets?api-version=7.4'
    $result = Invoke-Case @{}
    Assert ($result.Failure() -and -not $result.HasResult()) 'Looping vault continuation exposed a result.'
    foreach ($badLink in @('/secrets?api-version=7.4', 'not a uri')) {
        $script:pages[0].nextLink = $badLink
        $result = Invoke-Case @{}
        Assert ($result.Failure() -and -not $result.HasResult()) 'Relative/malformed vault link exposed a result.'
    }
    $script:pages[0].nextLink = 'https://vault.vault.azure.net/secrets?api-version=7.4&skiptoken=2'
    $script:failPage = 1
    $script:pages += [pscustomobject]@{ value = @(); nextLink = $null }
    $result = Invoke-Case @{}
    Assert ($result.Failure() -and -not $result.HasResult()) 'Failed later vault page exposed a result.'
    $script:failPage = -1
    foreach ($badPage in @([pscustomobject]@{ other = @() }, '{')) {
        $script:pages = @($badPage)
        $result = Invoke-Case @{}
        Assert ($result.Failure() -and -not $result.HasResult()) 'Malformed vault page exposed a result.'
    }
    $script:pages = @([pscustomobject]@{ value = 'unchanged-read-result' })
    $script:calls = @()
    $signal = [Signal]::Start('VaultReadFixture') | Select-Object -Last 1
    $adapter = [Storage_AzureKeyVault]::new()
    $null = $adapter.Construct([pscustomobject]@{ Addresses = @('https://vault.vault.azure.net/') })
    $read = $adapter.Invoke('Test', 'Read', $signal, [pscustomobject]@{
        Config = [pscustomobject]@{ VirtualPath = 'a.b.Read.mysecret' }
    }, $signal)
    Assert ($read.Success() -and $read.GetResult() -eq 'unchanged-read-result' -and
        $script:calls.Count -eq 1 -and $script:calls[0].Uri -match '/secrets/mysecret') 'Key Vault Read routing regressed.'
}

Write-Output 'PASS: Azure Storage Account and Key Vault List mock contracts.'
