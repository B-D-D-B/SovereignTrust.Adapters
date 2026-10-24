function Get-ADXAdminField {
    param([object]$Value, [string]$Name)
    $field = $null
    if ($Value -is [System.Collections.IDictionary]) { $field = $Value[$Name] }
    elseif ($null -ne $Value) { $field = $Value.PSObject.Properties[$Name].Value }
    if ($field -is [array]) { return ,$field }
    return $field
}

function Test-ADXAdminOverride {
    param([object]$Config)
    foreach ($name in @('Uri', 'Url', 'RequestUri', 'Address', 'Addresses', 'Host', 'Bearer', 'BearerToken', 'AccessToken', 'Token', 'Authorization', 'Database', 'Db', 'Method', 'HttpMethod', 'ExpectedClusterUri', 'ExpectedDatabase')) {
        if ($Config -is [System.Collections.IDictionary]) {
            if ($Config.Contains($name)) { return $true }
        }
        elseif ($null -ne $Config.PSObject.Properties[$name]) { return $true }
    }
    return $false
}

function Resolve-ADXAdminInput {
    param([object]$Adapter, [object]$Plan)
    $config = Get-ADXAdminField $Plan 'Config'
    if ($null -eq $config -or $config -is [string] -or (Test-ADXAdminOverride $config)) { throw 'InvalidConfig' }
    $command = Get-ADXAdminField $config 'CommandText'
    if ($command -isnot [string] -or [string]::IsNullOrWhiteSpace($command) -or -not $command.TrimStart().StartsWith('.')) { throw 'InvalidCommand' }
    $jacket = $Adapter.Signal.GetJacket()
    if ($null -eq $jacket -or -not $jacket.HasResult()) { throw 'InvalidTarget' }
    $target = $jacket.GetResult()
    $addresses = Get-ADXAdminField $target 'Addresses'
    if ($addresses -isnot [array] -or $addresses.Count -ne 1 -or $addresses[0] -isnot [string]) { throw 'InvalidTarget' }
    $address = $addresses[0]
    $uri = $null
    if (-not [Uri]::TryCreate($address, [UriKind]::Absolute, [ref]$uri) -or
        $uri.Scheme -ne 'https' -or $uri.Port -ne 443 -or
        $uri.UserInfo -or $uri.AbsolutePath -ne '/' -or $uri.Query -or $uri.Fragment -or
        $uri.Host -notmatch '^[a-z0-9][a-z0-9-]*\.[a-z0-9-]+\.kusto\.windows\.net$' -or
        $uri.Host.StartsWith('ingest-')) { throw 'InvalidTarget' }
    $database = Get-ADXAdminField $target 'Resource'
    if ($database -isnot [string] -or [string]::IsNullOrWhiteSpace($database) -or $database -ne $database.Trim()) { throw 'InvalidTarget' }
    return [pscustomobject]@{ Uri = $uri.GetLeftPart([UriPartial]::Authority) + '/v1/rest/mgmt'; Database = $database; Command = $command }
}

function Get-ADXAdminToken {
    param([object]$Plan)
    $tokenSignal = Resolve-BearerToken -Plan $Plan -Address 'https://api.kusto.windows.net' | Select-Object -Last 1
    if ($null -eq $tokenSignal -or -not $tokenSignal.Success() -or -not $tokenSignal.HasResult()) { throw 'TokenUnavailable' }
    $token = $tokenSignal.GetResult()
    if ($token -isnot [string] -or [string]::IsNullOrWhiteSpace($token)) { throw 'TokenUnavailable' }
    return $token
}

function New-ADXAdminRequest {
    param([string]$Uri, [string]$Database, [string]$Command, [string]$Token, [string]$RequestId)
    $request = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Post, $Uri)
    $body = @{ db = $Database; csl = $Command } | ConvertTo-Json -Compress -Depth 5
    $request.Content = [System.Net.Http.StringContent]::new($body, [Text.Encoding]::UTF8, 'application/json')
    $request.Headers.Accept.ParseAdd('application/json')
    $request.Headers.Authorization = [System.Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $Token)
    $request.Headers.Add('x-ms-client-request-id', $RequestId)
    return $request
}

function Send-ADXAdminHttp {
    param([string]$Uri, [string]$Database, [string]$Command, [string]$Token, [string]$RequestId)
    $handler = [System.Net.Http.HttpClientHandler]::new()
    $handler.AllowAutoRedirect = $false
    $client = [System.Net.Http.HttpClient]::new($handler)
    $client.Timeout = [TimeSpan]::FromSeconds(30)
    $request = $null
    $response = $null
    try {
        $request = New-ADXAdminRequest -Uri $Uri -Database $Database -Command $Command -Token $Token -RequestId $RequestId
        $response = $client.SendAsync($request).GetAwaiter().GetResult()
        $content = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        return [pscustomobject]@{ StatusCode = [int]$response.StatusCode; Content = $content }
    }
    finally {
        if ($null -ne $response) { $response.Dispose() }
        if ($null -ne $request) { $request.Dispose() }
        $client.Dispose()
        $handler.Dispose()
    }
}

function Test-ADXAdminErrorMember {
    param([object]$Value)
    if ($Value -isnot [System.Collections.IDictionary]) { return $false }
    foreach ($key in $Value.Keys) {
        if ([string]$key -match '^(?i:@?error|errors|partialerrors|oneapierrors|exceptions)$' -and $null -ne $Value[$key]) { return $true }
    }
    return $false
}

function ConvertFrom-ADXAdminResponse {
    param([string]$Content)
    if ([string]::IsNullOrWhiteSpace($Content) -or $Content.Length -gt 2097152) { throw 'MalformedResponse' }
    try { $parsed = ConvertFrom-Json -InputObject $Content -AsHashtable -Depth 100 -ErrorAction Stop }
    catch { throw 'MalformedResponse' }
    if ($parsed -isnot [System.Collections.IDictionary] -or (Test-ADXAdminErrorMember $parsed)) { throw 'MalformedResponse' }
    $tables = $parsed['Tables']
    if ($tables -isnot [array]) { throw 'MalformedResponse' }
    foreach ($table in $tables) {
        if (Test-ADXAdminErrorMember $table) { throw 'PartialFailure' }
        if ($table -isnot [System.Collections.IDictionary] -or $table['TableName'] -isnot [string] -or
            [string]::IsNullOrWhiteSpace($table['TableName']) -or $table['Columns'] -isnot [array] -or $table['Rows'] -isnot [array]) { throw 'MalformedResponse' }
        $columns = $table['Columns']
        foreach ($column in $columns) {
            if ($column -isnot [System.Collections.IDictionary] -or $column['ColumnName'] -isnot [string] -or
                [string]::IsNullOrWhiteSpace($column['ColumnName']) -or $column['DataType'] -isnot [string] -or
                [string]::IsNullOrWhiteSpace($column['DataType'])) { throw 'MalformedResponse' }
        }
        $severityIndex = -1
        if ($table['TableName'] -eq 'QueryStatus') {
            for ($i = 0; $i -lt $columns.Count; $i++) { if ($columns[$i]['ColumnName'] -eq 'Severity') { $severityIndex = $i; break } }
            if ($severityIndex -lt 0) { throw 'MalformedResponse' }
        }
        foreach ($row in $table['Rows']) {
            if ($row -isnot [array] -or $row.Count -ne $columns.Count) { throw 'MalformedResponse' }
            if ($severityIndex -ge 0) {
                $severity = 0
                if (-not [int]::TryParse([string]$row[$severityIndex], [ref]$severity)) { throw 'MalformedResponse' }
                if ($severity -le 2) { throw 'PartialFailure' }
            }
        }
    }
    return @{ Operation = 'Admin'; Tables = $tables } | ConvertTo-Json -Compress -Depth 100
}

function Invoke-AzureDataExplorerAdmin {
    param([object]$Adapter, [object]$Plan)
    $signal = [Signal]::Start('Data_AzureDataExplorer.Admin') | Select-Object -Last 1
    try { $inputData = Resolve-ADXAdminInput -Adapter $Adapter -Plan $Plan }
    catch { return $signal.LogCritical("ADX Admin $($_.Exception.Message).") }
    $requestId = 'ADXAdmin;' + [guid]::NewGuid().ToString('N')
    try { $token = Get-ADXAdminToken -Plan $Plan }
    catch { return $signal.LogCritical("ADX Admin TokenUnavailable; correlation $requestId.") }
    try { $response = Send-ADXAdminHttp -Uri $inputData.Uri -Database $inputData.Database -Command $inputData.Command -Token $token -RequestId $requestId }
    catch { return $signal.LogCritical("ADX Admin OutcomeUnknown; correlation $requestId.") }
    if ($response.StatusCode -lt 200 -or $response.StatusCode -ge 300) {
        $content = $response.Content | ConvertFrom-Json 
        return $signal.LogCritical("ADX Admin HttpFailure; correlation $requestId. (Message: $($content.error.message), Code: $($content.error.code), ActivityId: $($content.error.activityId) , StatusCode: $($response.StatusCode))")
    }
    try { $json = ConvertFrom-ADXAdminResponse -Content $response.Content }
    catch { return $signal.LogCritical("ADX Admin ResponseFailure; correlation $requestId.") }
    $signal.SetResult($json)
    return $signal
}
