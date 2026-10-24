function Resolve-ADXDataInput {
    param([object]$Adapter, [object]$Plan, [string]$Activity)
    $config = Get-ADXAdminField $Plan 'Config'
    if ($null -eq $config -or $config -is [string] -or (Test-ADXAdminOverride $config)) { throw 'InvalidConfig' }
    $command = Get-ADXAdminField $config 'CommandText'
    if ($command -isnot [string] -or [string]::IsNullOrWhiteSpace($command) -or $command.Length -gt 16384) { throw 'InvalidCommand' }
    $command = $command.Trim()
    $table = '[A-Za-z_][A-Za-z0-9_]*'
    switch ($Activity) {
        'Query' {
            if ($command.StartsWith('.') -or $command -match ';' -or $command -match '(?m)^\s*\.') { throw 'InvalidCommand' }
        }
        'Write' {
            if ($command -cnotmatch ('^\.ingest inline into table ' + $table + ' <\|\r?\n[^\r\n;]+$')) { throw 'InvalidCommand' }
        }
        'Delete' {
            if ($command -cnotmatch ('^\.delete table (' + $table + ') records <\| \1 \| where [A-Za-z_][A-Za-z0-9_]* == "[^"\r\n;]+"$')) { throw 'InvalidCommand' }
        }
        default { throw 'InvalidActivity' }
    }
    # Reuse the accepted target and override validation without changing Admin's contract.
    $targetInput = Resolve-ADXAdminInput -Adapter $Adapter -Plan @{ Config = @{ CommandText = '.show tables' } }
    $uri = $targetInput.Uri
    if ($Activity -eq 'Query') { $uri = $uri.Replace('/v1/rest/mgmt', '/v1/rest/query') }
    return [pscustomobject]@{ Uri = $uri; Database = $targetInput.Database; Command = $command }
}

function ConvertFrom-ADXDataResponse {
    param([string]$Content, [string]$Activity)
    $validated = ConvertFrom-ADXAdminResponse -Content $Content | ConvertFrom-Json -AsHashtable -Depth 100
    if ($Activity -ne 'Query') {
        return @{ Operation = $Activity; Tables = $validated.Tables } | ConvertTo-Json -Compress -Depth 100
    }
    $resultSets = @()
    foreach ($table in $validated.Tables) {
        if ($table.TableName -eq 'QueryStatus') { continue }
        $rows = @()
        foreach ($values in $table.Rows) {
            $row = [ordered]@{}
            for ($i = 0; $i -lt $table.Columns.Count; $i++) {
                $name = $table.Columns[$i].ColumnName
                if ($row.Contains($name)) { throw 'MalformedResponse' }
                $row[$name] = $values[$i]
            }
            $rows += $row
        }
        $resultSets += @{ Rows = @($rows) }
    }
    return @{ Operation = 'Query'; ResultSets = @($resultSets) } | ConvertTo-Json -Compress -Depth 100
}

function Invoke-AzureDataExplorerData {
    param([object]$Adapter, [object]$Plan, [string]$Activity)
    $signal = [Signal]::Start("Data_AzureDataExplorer.$Activity") | Select-Object -Last 1
    try { $inputData = Resolve-ADXDataInput -Adapter $Adapter -Plan $Plan -Activity $Activity }
    catch { return $signal.LogCritical("ADX $Activity InvalidInput.") }
    $requestId = "ADX$Activity;" + [guid]::NewGuid().ToString('N')
    try { $token = Get-ADXAdminToken -Plan $Plan }
    catch { return $signal.LogCritical("ADX $Activity TokenUnavailable; correlation $requestId.") }
    try { $response = Send-ADXAdminHttp -Uri $inputData.Uri -Database $inputData.Database -Command $inputData.Command -Token $token -RequestId $requestId }
    catch { return $signal.LogCritical("ADX $Activity OutcomeUnknown; correlation $requestId.") }
    if ($response.StatusCode -lt 200 -or $response.StatusCode -ge 300) {
        return $signal.LogCritical("ADX $Activity HttpFailure; correlation $requestId.")
    }
    try { $json = ConvertFrom-ADXDataResponse -Content $response.Content -Activity $Activity }
    catch { return $signal.LogCritical("ADX $Activity ResponseFailure; correlation $requestId.") }
    $signal.SetResult($json)
    return $signal
}
