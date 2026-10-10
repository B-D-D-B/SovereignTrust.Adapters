$ErrorActionPreference = 'Stop'
$moduleSource = Join-Path $PSScriptRoot '../PowerShell'
$smoke = Join-Path $PSScriptRoot 'Smoke-AzureSqlImport.ps1'
$manifest = Join-Path $moduleSource 'Data_AzureSql.psd1'
if (-not (Test-Path (Join-Path $moduleSource 'dependencies/inventory.json'))) {
    throw 'Run Package-AzureSql.ps1 before the package smoke test.'
}
$env:PSModulePath = "$(Join-Path $PSScriptRoot '../../../../../SignalGraph/Src/PowerShell');$env:PSModulePath"
& pwsh -NoProfile -File $smoke -Manifest $manifest
if ($LASTEXITCODE -ne 0) { throw 'Fresh AzureSql import smoke test failed.' }

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ("AzureSqlMissing_" + [guid]::NewGuid().ToString('N'))
$resolvedTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
$resolvedTestRoot = [IO.Path]::GetFullPath($testRoot)
if (-not $resolvedTestRoot.StartsWith($resolvedTemp + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Isolated artifact path is outside the temporary directory.'
}
try {
    New-Item -ItemType Directory -Path $testRoot | Out-Null
    Copy-Item -Path (Join-Path $moduleSource '*') -Destination $testRoot -Recurse -Force
    Remove-Item -LiteralPath (Join-Path $testRoot 'dependencies/Azure.Core.dll') -Force
    & pwsh -NoProfile -File $smoke -Manifest (Join-Path $testRoot 'Data_AzureSql.psd1') -MissingDependency Azure.Core.dll
    if ($LASTEXITCODE -ne 0) { throw 'Missing managed-dependency smoke test failed.' }
    Copy-Item -LiteralPath (Join-Path $moduleSource 'dependencies/Azure.Core.dll') -Destination (Join-Path $testRoot 'dependencies/Azure.Core.dll')
    Remove-Item -LiteralPath (Join-Path $testRoot 'dependencies/Microsoft.Data.SqlClient.SNI.dll') -Force
    & pwsh -NoProfile -File $smoke -Manifest (Join-Path $testRoot 'Data_AzureSql.psd1') -MissingDependency Microsoft.Data.SqlClient.SNI.dll
    if ($LASTEXITCODE -ne 0) { throw 'Missing native-dependency smoke test failed.' }
}
finally {
    if (Test-Path $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}
