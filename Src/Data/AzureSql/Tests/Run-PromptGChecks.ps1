[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$adapterRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).ProviderPath
$signalGraphSource = (Resolve-Path (Join-Path $PSScriptRoot '../../../../../SignalGraph/Src/PowerShell')).ProviderPath
$inventory = Join-Path $adapterRoot 'PowerShell/dependencies/inventory.json'

if (-not (Test-Path -LiteralPath $inventory -PathType Leaf)) {
    Write-Output 'Packaging pinned AzureSql dependencies for the focused checks.'
    & pwsh -NoProfile -File (Join-Path $adapterRoot 'Package-AzureSql.ps1')
    if ($LASTEXITCODE -ne 0) { throw 'AzureSql dependency packaging failed.' }
}

# This checkout keeps SignalGraph.psd1 at Src/PowerShell. PowerShell's named
# `using module SignalGraph` requires a parent containing a SignalGraph folder.
# A temporary junction supplies that module name without changing either repo.
$bootstrapRoot = Join-Path ([IO.Path]::GetTempPath()) ('AzureSqlPromptG_' + [guid]::NewGuid().ToString('N'))
$moduleLink = Join-Path $bootstrapRoot 'SignalGraph'
New-Item -ItemType Directory -Path $bootstrapRoot | Out-Null
try {
    New-Item -ItemType Junction -Path $moduleLink -Target $signalGraphSource | Out-Null
    $env:PSModulePath = $bootstrapRoot + [IO.Path]::PathSeparator + $env:PSModulePath
    $failed = [System.Collections.Generic.List[string]]::new()
    foreach ($name in @(
        'Data_AzureSql.Configuration.Tests.ps1',
        'Data_AzureSql.LoaderHydration.Tests.ps1',
        'Data_AzureSql.Routing.Tests.ps1',
        'Data_AzureSql.ConnectionParameters.Tests.ps1'
    )) {
        Write-Output "RUN: $name"
        & pwsh -NoProfile -File (Join-Path $PSScriptRoot $name)
        if ($LASTEXITCODE -ne 0) {
            $failed.Add($name)
            Write-Output "FAIL: $name"
        }
    }
    if ($failed.Count -gt 0) { throw "Focused checks failed: $($failed -join ', ')" }
    Write-Output 'PASS: all Prompt G focused checks.'
}
finally {
    if (Test-Path -LiteralPath $moduleLink) { Remove-Item -LiteralPath $moduleLink }
    if (Test-Path -LiteralPath $bootstrapRoot) { Remove-Item -LiteralPath $bootstrapRoot }
}
