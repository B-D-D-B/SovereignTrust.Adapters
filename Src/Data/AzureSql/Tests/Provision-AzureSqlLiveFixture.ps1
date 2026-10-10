[CmdletBinding()]
param([switch]$CaptureEvidence,
      [string]$EvidencePath,
      [string]$ReviewedBy)

# One-time DDL for the user-approved test-prefixed schema. The live suite never
# creates objects and must run later with a separate restricted identity.
$ErrorActionPreference = 'Stop'
$approvedServer = 'sda-dev.database.windows.net'
$approvedDatabase = 'sda-fusion'
$approvedSchema = 'test_sda_azure_sql_it_adapter'
$moduleRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../../../../SignalGraph/Src/PowerShell')).ProviderPath
$foundationManifest = (Resolve-Path (Join-Path $PSScriptRoot '../../../../../SovereignTrust.Foundation/Src/PowerShell/SovereignTrust.Foundation.psd1')).ProviderPath
$adapterManifest = (Resolve-Path (Join-Path $PSScriptRoot '../PowerShell/Data_AzureSql.psd1')).ProviderPath
$configPath = (Resolve-Path (Join-Path $PSScriptRoot '../../../../../SDAFusion-Content/SDA/Config/SDAFusionApp.Json')).ProviderPath
$templatePath = (Resolve-Path (Join-Path $PSScriptRoot 'Provision-AzureSqlLiveFixture.template.sql')).ProviderPath
$previousModulePath = $env:PSModulePath
$bootstrapRoot = Join-Path ([IO.Path]::GetTempPath()) ('AzureSqlProvision_' + [guid]::NewGuid().ToString('N'))
$moduleLink = Join-Path $bootstrapRoot 'SignalGraph'
$connection = $null
$transaction = $null
$stage = 'bootstrap'

try {
    New-Item -ItemType Directory -Path $bootstrapRoot | Out-Null
    New-Item -ItemType Junction -Path $moduleLink -Target $moduleRoot | Out-Null
    $env:PSModulePath = $bootstrapRoot + [IO.Path]::PathSeparator + $previousModulePath
    Import-Module $foundationManifest -Force
    Import-Module $adapterManifest -Force

    $stage = 'configuration'
    $config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json -Depth 100
    $agents = @($config.Agents | Where-Object Name -eq 'sdadev01')
    if ($agents.Count -ne 1) { throw 'Approved agent selection failed.' }
    $jackets = @($agents[0].Roles.SDAWorkItems.Adapters | Where-Object Name -eq 'SDAFusionDatabase')
    if ($jackets.Count -ne 1 -or $jackets[0].Resource -cne $approvedDatabase -or
        @($jackets[0].Addresses).Count -ne 1 -or $jackets[0].Addresses[0] -cne $approvedServer) {
        throw 'Production SQL jacket differs from the approved target.'
    }
    $builder = & (Get-Module Data_AzureSql) {
        param($jacket) New-AzureSqlConnectionBuilder -Adapter ([pscustomobject]@{ Configuration = $jacket })
    } $jackets[0]
    if ($builder.DataSource -cne $approvedServer -or $builder.InitialCatalog -cne $approvedDatabase) {
        throw 'Connection builder differs from the approved target.'
    }

    $stage = 'target-validation'
    $connection = [Microsoft.Data.SqlClient.SqlConnection]::new($builder.ConnectionString)
    $connection.Open()
    $identityCommand = $connection.CreateCommand()
    try {
        $identityCommand.CommandText = 'SELECT DB_NAME()'
        if ($identityCommand.ExecuteScalar() -cne $approvedDatabase) {
            throw 'Connected database differs from the approved target.'
        }
    }
    finally { $identityCommand.Dispose() }

    if ($CaptureEvidence) {
        $stage = 'owner-evidence'
        if ([string]::IsNullOrWhiteSpace($EvidencePath) -or
            [string]::IsNullOrWhiteSpace($ReviewedBy) -or
            (Test-Path -LiteralPath $EvidencePath)) {
            throw 'Evidence capture requires a new output path and reviewer name.'
        }
        . (Join-Path $PSScriptRoot 'AzureSqlFixtureGuard.ps1')
        $reviewed = Get-ReviewedAzureSqlFixtureDefinition -TemplatePath $templatePath `
            -Database $approvedDatabase -Schema $approvedSchema
        $command = $connection.CreateCommand()
        try {
            $command.CommandText = @'
SELECT OBJECT_ID(@ProcedureName,'P') AS ObjectId,
       CONVERT(varchar(33),create_date,126) AS CreateTime,
       CONVERT(varchar(33),modify_date,126) AS ModifyTime,
       OBJECT_DEFINITION(object_id) AS ProcedureDefinition,
       ORIGINAL_LOGIN() AS CapturedBy
FROM sys.objects WHERE object_id=OBJECT_ID(@ProcedureName,'P')
'@
            $null = $command.Parameters.Add('@ProcedureName', [System.Data.SqlDbType]::NVarChar, 256)
            $command.Parameters['@ProcedureName'].Value = "${approvedSchema}.usp_IngestAzureSqlAdapterFixture"
            $reader = $command.ExecuteReader()
            try {
                if (-not $reader.Read() -or $reader.IsDBNull(3)) {
                    throw 'Current procedure definition is unavailable to the provisioning owner.'
                }
                $binding = [pscustomobject]@{
                    Server = $approvedServer; Database = $approvedDatabase; Schema = $approvedSchema
                    ObjectId = $reader.GetInt32(0)
                    CreateTime = $reader.GetString(1); ModifyTime = $reader.GetString(2)
                }
                $actualDefinition = $reader.GetString(3)
                $capturedBy = $reader.GetString(4)
            }
            finally { $reader.Dispose() }
        }
        finally { $command.Dispose() }
        $check = Test-AzureSqlFixtureDefinition -ActualDefinition $actualDefinition `
            -Reviewed $reviewed -Binding $binding
        if ($check.Status -cne 'Verified') { throw 'Current procedure differs from the reviewed fixture definition.' }
        $evidence = [ordered]@{
            Server = $binding.Server; Database = $binding.Database; Schema = $binding.Schema
            ObjectId = $binding.ObjectId; CreateTime = $binding.CreateTime
            ModifyTime = $binding.ModifyTime; DefinitionSha256 = $reviewed.Sha256
            ReviewedBy = $ReviewedBy; CapturedBy = $capturedBy
            CapturedUtc = [datetimeoffset]::UtcNow.ToString('o')
        }
        $evidence | ConvertTo-Json | Set-Content -LiteralPath $EvidencePath -Encoding utf8
        Write-Output "PASS: current fixture definition matched the reviewed template; owner evidence saved to $EvidencePath."
        return
    }

    $stage = 'template-validation'
    $template = Get-Content -LiteralPath $templatePath -Raw
    if (-not $template.Contains(':setvar ApprovedDatabase "sda-fusion"') -or
        -not $template.Contains(':setvar DedicatedSchema "test_sda_azure_sql_it_adapter"')) {
        throw 'Fixture template differs from the approved target.'
    }
    $sql = $template -replace '(?m)^:setvar [^\r\n]+\r?\n', ''
    $sql = $sql.Replace('$(ApprovedDatabase)', $approvedDatabase).Replace('$(DedicatedSchema)', $approvedSchema)
    if ($sql.Contains('$(')) { throw 'Unresolved SQL template variable.' }
    $batches = @([regex]::Split($sql, '(?m)^\s*GO\s*$') | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($batches.Count -ne 6) { throw 'Unexpected fixture template batch count.' }

    $stage = 'fixture-creation'
    $transaction = $connection.BeginTransaction()
    foreach ($batch in $batches) {
        $command = $connection.CreateCommand()
        try {
            $command.Transaction = $transaction
            $command.CommandText = $batch
            $command.CommandTimeout = 30
            $null = $command.ExecuteNonQuery()
        }
        finally { $command.Dispose() }
    }
    $transaction.Commit()
    $transaction.Dispose()
    $transaction = $null
    Write-Output "PASS: created [$approvedSchema] fixture schema, table, index, and ingestion procedure in $approvedDatabase."
}
catch {
    if ($null -ne $transaction) {
        try { $transaction.Rollback() } catch { <# Preserve the primary failure. #> }
    }
    $kind = $_.Exception.GetType().Name
    $number = if ($_.Exception -is [Microsoft.Data.SqlClient.SqlException]) { $_.Exception.Number } else { 'NA' }
    Write-Output "FAIL: fixture provisioning stage=$stage exception_type=$kind sql_number=$number; no connection details printed."
    exit 1
}
finally {
    if ($null -ne $transaction) { $transaction.Dispose() }
    if ($null -ne $connection) { $connection.Dispose() }
    $env:PSModulePath = $previousModulePath
    $resolvedTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
    $resolvedRoot = [IO.Path]::GetFullPath($bootstrapRoot)
    if (-not $resolvedRoot.StartsWith($resolvedTemp + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Temporary module bootstrap path was outside the temporary directory.'
    }
    if (Test-Path -LiteralPath $moduleLink) { Remove-Item -LiteralPath $moduleLink }
    if (Test-Path -LiteralPath $bootstrapRoot) { Remove-Item -LiteralPath $bootstrapRoot }
}
