# Private execution orchestration. Tests replace only New-AzureSqlSession once
# operation helpers are implemented; no test hooks enter adapter configuration.
function Invoke-AzureSqlExecution {
    param(
        [object]$Adapter, [string]$Slot, [string]$Activity,
        [object]$Config, [object]$Plan, [object]$NormalizedWrite,
        [Signal]$ConductionSignal, [Signal]$ItemSignal
    )
    $transactionMode = Get-AzureSqlObjectValue $Config 'TransactionMode' 'Required'
    if ($transactionMode -notin @('Required', 'None') -or
        ($transactionMode -eq 'None' -and $Activity -notin @('Write', 'Admin')) -or
        ($Activity -eq 'Query' -and (Test-AzureSqlObjectMember $Config 'TransactionMode'))) {
        throw 'TransactionMode is invalid for this Azure SQL operation.'
    }
    if ((Test-AzureSqlObjectMember $Config 'ExpectedServer') -or
        (Test-AzureSqlObjectMember $Config 'ExpectedDatabase')) {
        throw 'Azure SQL target overrides are not supported.'
    }
    $target = New-AzureSqlConnectionBuilder -Adapter $Adapter
    $session = $null
    $transaction = $null
    $failure = $null
    $result = $null
    $committed = $false
    $commitAttempted = $false
    $rollbackConfirmed = $false
    try {
        $session = New-AzureSqlSession -Adapter $Adapter
        if ($null -eq $session) { throw 'Azure SQL session factory returned no connection.' }
        $session.Open()
        # The registered adapter target is checked on the executing session.
        if ($session.DataSource -ine $target.DataSource -or
            $session.Database -cne $target.InitialCatalog) { throw 'Azure SQL destination identity mismatch.' }
        if ($Activity -in @('Write', 'Delete', 'Admin') -and $transactionMode -eq 'Required') {
            $transaction = $session.BeginTransaction()
            if ($null -eq $transaction) { throw 'Azure SQL session returned no transaction.' }
        }
        switch ($Activity) {
            'Write' { $result = Invoke-AzureSqlWrite -Session $session -Adapter $Adapter -Config $Config -NormalizedWrite $NormalizedWrite -Transaction $transaction }
            'Query' { $result = Invoke-AzureSqlQuery -Session $session -Adapter $Adapter -Config $Config }
            'Delete' { $result = Invoke-AzureSqlDelete -Session $session -Adapter $Adapter -Config $Config -Transaction $transaction }
            'Admin' { $result = Invoke-AzureSqlAdmin -Session $session -Adapter $Adapter -Config $Config -Transaction $transaction }
            default { throw "Unsupported AzureSql activity '$Activity'." }
        }
        if ($result -isnot [string]) { throw 'Azure SQL execution must return JSON text.' }
        $parsedResult = ConvertFrom-Json -InputObject $result -Depth 100 -ErrorAction Stop
        if ($Activity -eq 'Admin' -and
            ($null -eq $parsedResult -or $parsedResult.Operation -cne 'Admin' -or
             -not (Test-AzureSqlObjectMember $parsedResult 'RowsAffected') -or
             -not (Test-AzureSqlObjectMember $parsedResult 'OutputParameters') -or
             -not (Test-AzureSqlObjectMember $parsedResult 'ResultSets') -or
             $parsedResult.ResultSets -isnot [array] -or $parsedResult.ResultSets.Count -ne 0)) {
            throw 'Azure SQL Admin returned an invalid result envelope.'
        }
        if ($null -ne $transaction) { $commitAttempted = $true; $transaction.Commit(); $committed = $true }
    }
    catch {
        $failure = $_
        if ($null -ne $transaction -and -not $committed) {
            try { $transaction.Rollback(); $rollbackConfirmed = $true } catch { <# Preserve the original failure. #> }
        }
    }
    finally {
        if ($transaction -is [System.IDisposable]) {
            try { $transaction.Dispose() } catch { if ($null -eq $failure) { $failure = $_ } }
        }
        if ($session -is [System.IDisposable]) {
            try { $session.Dispose() } catch { if ($null -eq $failure) { $failure = $_ } }
        }
    }
    if ($null -ne $failure) {
        if ($committed) { throw 'Azure SQL operation committed but cleanup failed.' }
        if ($commitAttempted) { throw 'Azure SQL transaction outcome is uncertain.' }
        if ($rollbackConfirmed) { $failure.Exception.Data["SovereignTrust.Sql.RollbackConfirmed"] = $true }
        throw $failure
    }
    return $result
}

function Invoke-Data_AzureSql {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Adapter,
        [Parameter(Mandatory)][string]$Slot,
        [Parameter(Mandatory)][string]$Activity,
        [Parameter(Mandatory)][Signal]$ConductionSignal,
        [Parameter(Mandatory)][object]$Plan,
        [Parameter(Mandatory)][Signal]$ItemSignal
    )

    $opSignal = [Signal]::Start("Data_AzureSql.Invoke:$Slot.$Activity", $ItemSignal) | Select-Object -Last 1
    try {
        if ($Activity -notin @('Write', 'Query', 'Delete', 'Admin')) {
            throw "Unsupported AzureSql activity '$Activity'."
        }
        $config = Get-AzureSqlObjectValue $Plan 'Config'
        if ($null -eq $config) { throw 'AzureSql requires Plan.Config.' }
        if ($Activity -eq 'Write') {
            if ([string]::IsNullOrWhiteSpace([string](Get-AzureSqlObjectValue $config 'Procedure'))) {
                throw 'Write requires Config.Procedure.'
            }
        }
        elseif (($Activity -eq 'Admin' -and (Get-AzureSqlObjectValue $config 'CommandText') -isnot [string]) -or
            [string]::IsNullOrWhiteSpace([string](Get-AzureSqlObjectValue $config 'CommandText'))) {
            throw "$Activity requires Config.CommandText."
        }

        $normalizedWrite = $null
        if ($Activity -eq 'Write') {
            $normalizedWrite = Resolve-AzureSqlWriteInput -Config $config -ItemSignal $ItemSignal -OperationSignal $opSignal
        }
        $result = Invoke-AzureSqlExecution -Adapter $Adapter -Slot $Slot -Activity $Activity `
            -Config $config -Plan $Plan -NormalizedWrite $normalizedWrite -ConductionSignal $ConductionSignal -ItemSignal $ItemSignal
        if ($result -is [Signal]) {
            if ($opSignal.MergeSignalAndVerifyFailure($result)) { return $opSignal }
            if (-not $result.HasResult()) { throw 'Azure SQL execution returned no result.' }
            $result = $result.GetResult()
        }
        if ($result -isnot [string]) { throw 'Azure SQL execution must return JSON text.' }
        $null = $result | ConvertFrom-Json -Depth 100
        $opSignal.SetResult($result)
    }
    catch {
        # Neither provider nor conversion exceptions are safe to publish: they
        # may include a connection resource or a parameter value.
        $message = switch ($_.Exception.Message) {
            'Azure SQL operation committed but cleanup failed.' { "AzureSql $Activity committed, but cleanup failed."; break }
            'Azure SQL transaction outcome is uncertain.' { "AzureSql $Activity transaction outcome is uncertain."; break }
            default { "AzureSql $Activity failed. Check adapter configuration and operation inputs." }
        }
        $null = $opSignal.LogCritical($message)
        if ($_.Exception.Data["SovereignTrust.Sql.RollbackConfirmed"] -eq $true -and $null -ne $normalizedWrite) {
            $digest = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($normalizedWrite.Json)))
            $opSignal.SetResult((@{ Outcome="RolledBack"; PayloadSha256=$digest; InvocationId=[guid]::NewGuid().ToString() } | ConvertTo-Json -Compress))
        }
    }
    return $opSignal
}
