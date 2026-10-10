$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'AzureSqlFixtureGuard.ps1')

function Assert([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }

$reviewed = Get-ReviewedAzureSqlFixtureDefinition `
    -TemplatePath (Join-Path $PSScriptRoot 'Provision-AzureSqlLiveFixture.template.sql') `
    -Database 'sda-fusion' -Schema 'test_sda_azure_sql_it_adapter'
$binding = [pscustomobject]@{
    Server = 'sda-dev.database.windows.net'
    Database = 'sda-fusion'
    Schema = 'test_sda_azure_sql_it_adapter'
    ObjectId = 12345
    CreateTime = '2026-09-24T12:00:00'
    ModifyTime = '2026-09-24T12:00:00'
}
$contract = [pscustomobject]@{
    MatchingColumns = 5; MatchingParameters = 3; TriggerCount = 0
    CanSelect = 1; CanDelete = 1; CanExecute = 1; CanAlterFixture = 0
    IsDbOwner = 0; IsDbDataWriter = 0; IsDbDdlAdmin = 0; OtherWritableTables = 0
    ProcedureDefinition = $reviewed.Definition
}

$valid = Test-AzureSqlFixturePreflight -Contract $contract -Reviewed $reviewed -Binding $binding
Assert ($valid.Status -ceq 'Verified' -and $valid.Method -ceq 'DirectDefinition') 'Reviewed procedure was not accepted.'

$unrelated = $reviewed.Definition.Replace('    THROW 51005,',
    "    INSERT INTO [dbo].[Unrelated] ([RunId]) VALUES (@RunId);`n    THROW 51005,")
Assert ($unrelated -cne $reviewed.Definition) 'Unrelated INSERT fixture was not created.'
$contract.ProcedureDefinition = $unrelated
$rejected = Test-AzureSqlFixturePreflight -Contract $contract -Reviewed $reviewed -Binding $binding
Assert ($rejected.Status -ceq 'Mismatch') 'Procedure with an unrelated INSERT was accepted.'

$badTemplatePath = Join-Path ([IO.Path]::GetTempPath()) ('AzureSqlBadFixture_' + [guid]::NewGuid().ToString('N') + '.sql')
try {
    $rawTemplate = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Provision-AzureSqlLiveFixture.template.sql') -Raw
    $rawTemplate.Replace('    THROW 51005,',
        "    INSERT INTO [dbo].[Unrelated] ([RunId]) VALUES (@RunId);`n    THROW 51005,") |
        Set-Content -LiteralPath $badTemplatePath -Encoding utf8
    try {
        $null = Get-ReviewedAzureSqlFixtureDefinition -TemplatePath $badTemplatePath -Database 'sda-fusion' -Schema 'test_sda_azure_sql_it_adapter'
        throw 'Reviewed template accepted an unrelated INSERT.'
    }
    catch { if ($_.Exception.Message -eq 'Reviewed template accepted an unrelated INSERT.') { throw } }
}
finally { if (Test-Path -LiteralPath $badTemplatePath) { Remove-Item -LiteralPath $badTemplatePath } }

$contract.ProcedureDefinition = $null
$missing = Test-AzureSqlFixturePreflight -Contract $contract -Reviewed $reviewed -Binding $binding
Assert ($missing.Status -ceq 'Unverified') 'Missing definition without owner evidence was accepted.'

$evidencePath = Join-Path ([IO.Path]::GetTempPath()) ('AzureSqlFixtureEvidence_' + [guid]::NewGuid().ToString('N') + '.json')
try {
    $evidence = [ordered]@{
        Server = $binding.Server
        Database = $binding.Database
        Schema = $binding.Schema
        ObjectId = $binding.ObjectId
        CreateTime = $binding.CreateTime
        ModifyTime = $binding.ModifyTime
        DefinitionSha256 = $reviewed.Sha256
        ReviewedBy = 'synthetic-provisioning-owner'
        CapturedBy = 'synthetic-sql-identity'
        CapturedUtc = '2026-09-24T12:01:00Z'
    }
    $evidence | ConvertTo-Json | Set-Content -LiteralPath $evidencePath -Encoding utf8
    $ownerReview = Test-AzureSqlFixturePreflight -Contract $contract -Reviewed $reviewed -Binding $binding -EvidencePath $evidencePath
    Assert ($ownerReview.Status -ceq 'Verified' -and $ownerReview.Method -ceq 'OwnerEvidence') 'Applicable owner evidence was not accepted.'
    $evidence.ObjectId = 54321
    $evidence | ConvertTo-Json | Set-Content -LiteralPath $evidencePath -Encoding utf8
    $stale = Test-AzureSqlFixturePreflight -Contract $contract -Reviewed $reviewed -Binding $binding -EvidencePath $evidencePath
    Assert ($stale.Status -ceq 'Unverified') 'Evidence for a different object was accepted.'
}
finally { if (Test-Path -LiteralPath $evidencePath) { Remove-Item -LiteralPath $evidencePath } }

Write-Output 'PASS: reviewed fixture accepted; unrelated INSERT in the live definition or template rejected; missing or inapplicable owner evidence stops the guard.'
