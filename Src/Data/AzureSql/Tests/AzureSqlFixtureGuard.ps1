$ErrorActionPreference = 'Stop'

function Get-ReviewedAzureSqlFixtureDefinition {
    param([Parameter(Mandatory)][string]$TemplatePath,
          [Parameter(Mandatory)][string]$Database,
          [Parameter(Mandatory)][string]$Schema)

    if ($Database -cne 'sda-fusion' -or $Schema -cne 'test_sda_azure_sql_it_adapter') {
        throw 'Fixture review target differs from the approved database or schema.'
    }
    $template = Get-Content -LiteralPath $TemplatePath -Raw
    if (-not $template.Contains(':setvar ApprovedDatabase "sda-fusion"') -or
        -not $template.Contains(':setvar DedicatedSchema "test_sda_azure_sql_it_adapter"')) {
        throw 'Fixture template target differs from the approved database or schema.'
    }
    $expanded = $template.Replace('$(ApprovedDatabase)', $Database).Replace('$(DedicatedSchema)', $Schema)
    $batches = @([regex]::Split($expanded, '(?m)^\s*GO\s*$') |
        Where-Object { $_ -match '(?m)^\s*CREATE PROCEDURE\s+' })
    if ($batches.Count -ne 1) { throw 'Fixture template must contain exactly one ingestion procedure.' }
    $definition = ($batches[0] -replace "`r`n", "`n").Trim()
    $target = "[$Schema].[AzureSqlAdapterFixture]"
    $inserts = [regex]::Matches($definition, '(?i)\bINSERT\s+INTO\s+(\[[^\]]+\]\.\[[^\]]+\])')
    if ($inserts.Count -ne 2 -or @($inserts | Where-Object { $_.Groups[1].Value -cne $target }).Count -gt 0 -or
        $definition -cnotmatch 'SELECT\s+@RunId\s*,' -or
        $definition -cnotmatch 'VALUES\s*\(\s*@RunId\s*,' -or
        $definition -match '(?i)\b(EXEC|EXECUTE|UPDATE|DELETE|MERGE|TRUNCATE|DROP|ALTER)\b') {
        throw 'Reviewed fixture procedure has an unapproved write target or RunId behavior.'
    }
    $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($definition)))
    return [pscustomobject]@{ Definition = $definition; Sha256 = $hash }
}

function Test-AzureSqlFixtureDefinition {
    param([AllowNull()][string]$ActualDefinition,
          [Parameter(Mandatory)][object]$Reviewed,
          [Parameter(Mandatory)][object]$Binding,
          [AllowNull()][string]$EvidencePath)

    if (-not [string]::IsNullOrWhiteSpace($ActualDefinition)) {
        $actual = ($ActualDefinition -replace "`r`n", "`n").Trim()
        if ($actual -cne $Reviewed.Definition) {
            return [pscustomobject]@{ Status = 'Mismatch'; Method = 'DirectDefinition' }
        }
        return [pscustomobject]@{ Status = 'Verified'; Method = 'DirectDefinition' }
    }
    if ([string]::IsNullOrWhiteSpace($EvidencePath) -or
        -not (Test-Path -LiteralPath $EvidencePath -PathType Leaf)) {
        return [pscustomobject]@{ Status = 'Unverified'; Method = 'NoOwnerEvidence' }
    }
    try { $evidence = Get-Content -LiteralPath $EvidencePath -Raw | ConvertFrom-Json -Depth 10 }
    catch { return [pscustomobject]@{ Status = 'Unverified'; Method = 'InvalidOwnerEvidence' } }
    foreach ($field in @('Server','Database','Schema','ObjectId','CreateTime','ModifyTime','DefinitionSha256','ReviewedBy','CapturedBy','CapturedUtc')) {
        if ([string]::IsNullOrWhiteSpace([string]$evidence.$field)) {
            return [pscustomobject]@{ Status = 'Unverified'; Method = 'IncompleteOwnerEvidence' }
        }
    }
    if ($evidence.Server -cne $Binding.Server -or $evidence.Database -cne $Binding.Database -or
        $evidence.Schema -cne $Binding.Schema -or [string]$evidence.ObjectId -cne [string]$Binding.ObjectId -or
        $evidence.CreateTime -cne $Binding.CreateTime -or $evidence.ModifyTime -cne $Binding.ModifyTime -or
        $evidence.DefinitionSha256 -cne $Reviewed.Sha256) {
        return [pscustomobject]@{ Status = 'Unverified'; Method = 'OwnerEvidenceDoesNotMatchCurrentObject' }
    }
    $captured = [datetimeoffset]::MinValue
    if (-not [datetimeoffset]::TryParse([string]$evidence.CapturedUtc, [ref]$captured)) {
        return [pscustomobject]@{ Status = 'Unverified'; Method = 'InvalidOwnerEvidenceTime' }
    }
    return [pscustomobject]@{ Status = 'Verified'; Method = 'OwnerEvidence' }
}

function Test-AzureSqlFixturePreflight {
    param([Parameter(Mandatory)][object]$Contract,
          [Parameter(Mandatory)][object]$Reviewed,
          [Parameter(Mandatory)][object]$Binding,
          [AllowNull()][string]$EvidencePath)

    if ($Contract.MatchingColumns -ne 5 -or $Contract.MatchingParameters -ne 3 -or
        $Contract.TriggerCount -ne 0) {
        return [pscustomobject]@{ Status = 'Rejected'; Method = 'FixtureShapeOrTriggers' }
    }
    if ($Contract.CanSelect -ne 1 -or $Contract.CanDelete -ne 1 -or $Contract.CanExecute -ne 1 -or
        $Contract.CanAlterFixture -eq 1 -or $Contract.IsDbOwner -eq 1 -or
        $Contract.IsDbDataWriter -eq 1 -or $Contract.IsDbDdlAdmin -eq 1 -or
        $Contract.OtherWritableTables -ne 0) {
        return [pscustomobject]@{ Status = 'Unverified'; Method = 'LeastPrivilegeNotReady' }
    }
    return Test-AzureSqlFixtureDefinition -ActualDefinition $Contract.ProcedureDefinition `
        -Reviewed $Reviewed -Binding $Binding -EvidencePath $EvidencePath
}
