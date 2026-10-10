$ErrorActionPreference = 'Stop'

function Assert([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

$contentRoot = Join-Path $PSScriptRoot '../../../../../SDAFusion-Content'
$configPath = Join-Path $contentRoot 'SDA/Config/SDAFusionApp.Json'
$config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json -AsHashtable -Depth 100

$agents = @($config.Agents | Where-Object Name -eq 'sdadev01')
Assert ($agents.Count -eq 1) 'Expected exactly one sdadev01 agent.'
$role = $agents[0].Roles.SDAWorkItems
Assert ($null -ne $role) 'SDAWorkItems role is missing.'
$adapters = @($role.Adapters)
$named = @($adapters | Where-Object Name -eq 'SDAFusionDatabase')
$slot = @($adapters | Where-Object VirtualPath -eq 'SovereignTrust.Adapters.Data.AzureSql.FusionDatabase.Persistent.Full')
Assert ($named.Count -eq 1 -and $slot.Count -eq 1) 'FusionDatabase mapping must occur exactly once.'
$jacket = $named[0]
Assert ($jacket.VirtualPath -ceq 'SovereignTrust.Adapters.Data.AzureSql.FusionDatabase.Persistent.Full') 'VirtualPath differs from the planned mapping.'
Assert ($jacket.IsMapped -ceq $true) 'FusionDatabase must be mapped.'
Assert ($jacket.Resource -ceq 'sda-fusion') 'Database Resource differs from the approved configuration.'
Assert ($jacket.Addresses.Count -eq 1 -and $jacket.Addresses[0] -ceq 'sda-dev.database.windows.net') 'SQL server address differs from the approved configuration.'

$readmePath = Join-Path $PSScriptRoot '../README.md'
$readme = Get-Content -LiteralPath $readmePath -Raw
$blocks = [regex]::Matches($readme, '(?ms)^```json\s*\r?\n(.*?)^```')
Assert ($blocks.Count -eq 6) 'Expected six active JSON plan/result examples.'
$examples = @($blocks | ForEach-Object { $_.Groups[1].Value | ConvertFrom-Json -AsHashtable -Depth 100 })
for ($index = 0; $index -lt 5; $index++) {
    Assert ($examples[$index].Adapter -ceq 'Data.FusionDatabase') "Example $index does not use the direct mapped route."
}
Assert ($examples[0].Config.InputFormat -ceq 'Json' -and $examples[0].Config.PayloadMode -ceq 'Records') 'JSON records example is inconsistent.'
Assert ($examples[1].Config.InputFormat -ceq 'Csv' -and $examples[1].Config.PayloadMode -ceq 'Records') 'CSV records example is inconsistent.'
Assert ($examples[2].Config.InputFormat -ceq 'Object' -and $examples[2].Config.PayloadMode -ceq 'Document' -and $examples[2].Config.Content.Metadata.Name -ceq 'Example' -and $examples[2].Config.Content.Items.Count -eq 1) 'Nested document example is inconsistent.'
Assert ($examples[3].Activity -ceq 'Query' -and $examples[4].Activity -ceq 'Delete') 'Query/Delete examples are missing.'
Assert ($examples[5].Operation -ceq 'Query' -and $examples[5].ResultSets[0].Columns.Count -eq 1) 'Result envelope example is inconsistent.'
$records = $examples[0].Config.Content | ConvertFrom-Json -AsHashtable -NoEnumerate -Depth 100
Assert ($records.Count -eq 1 -and $records[0].Id -eq 1) 'JSON record Content does not parse as a record array.'
$csv = @($examples[1].Config.Content | ConvertFrom-Csv)
Assert ($csv.Count -eq 1 -and $csv[0].Id -eq '2' -and $csv[0].Name -ceq 'Example, Gallery') 'CSV record Content does not parse as documented.'
foreach ($index in @(3, 4)) {
    $operation = $examples[$index]
    Assert ($operation.Config.Parameters.Count -eq 1 -and $operation.Config.Parameters[0].Name -ceq '@Id' -and $operation.Config.Parameters[0].SqlDbType -ceq 'Int') "Example $index is missing its typed parameter."
    Assert ($operation.Config.CommandText.Contains('@Id') -and $operation.Config.CommandTimeoutSeconds -eq 15) "Example $index has inconsistent text or timeout."
}

$planPath = Join-Path $PSScriptRoot '../../../../docs/AzureSql-Data-Adapter-Implementation-Plan.md'
$planText = Get-Content -LiteralPath $planPath -Raw
$planExample = [regex]::Match($planText, '(?ms)^## 10\. Update plans and examples\s*.*?^```json\s*\r?\n(.*?)^```')
Assert ($planExample.Success) 'Implementation plan JSON example is missing.'
$illustration = $planExample.Groups[1].Value | ConvertFrom-Json -AsHashtable -Depth 100
Assert ($illustration.Adapter -ceq 'Data.FusionDatabase' -and
    $illustration.Config.Procedure -ceq 'example.usp_IngestRecords' -and
    $illustration.Config.InputFormat -ceq 'Object') 'Implementation plan JSON example is inconsistent.'
Assert ($planText.Contains('Replace its schema and procedure name with a reviewed procedure')) 'Implementation plan does not mark its procedure as illustrative.'

Write-Output 'PASS: configuration parses, sdadev01 mapping is unique and exact, and active JSON examples parse and route directly.'
