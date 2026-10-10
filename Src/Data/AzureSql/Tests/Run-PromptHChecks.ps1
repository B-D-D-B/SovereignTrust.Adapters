[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$adapterRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).ProviderPath
$signalGraphSource = (Resolve-Path (Join-Path $PSScriptRoot '../../../../../SignalGraph/Src/PowerShell')).ProviderPath
$foundationTests = (Resolve-Path (Join-Path $PSScriptRoot '../../../../../SovereignTrust.Foundation/Tests')).ProviderPath
$manifest = (Resolve-Path (Join-Path $adapterRoot 'PowerShell/Data_AzureSql.psd1')).ProviderPath
if (-not (Test-Path -LiteralPath (Join-Path $adapterRoot 'PowerShell/dependencies/inventory.json'))) {
    & pwsh -NoProfile -File (Join-Path $adapterRoot 'Package-AzureSql.ps1')
    if ($LASTEXITCODE -ne 0) { throw 'AzureSql dependency packaging failed.' }
}

$bootstrapRoot = Join-Path ([IO.Path]::GetTempPath()) ('AzureSqlPromptH_' + [guid]::NewGuid().ToString('N'))
$moduleLink = Join-Path $bootstrapRoot 'SignalGraph'
New-Item -ItemType Directory -Path $bootstrapRoot | Out-Null
$failed = [System.Collections.Generic.List[string]]::new()
try {
    New-Item -ItemType Junction -Path $moduleLink -Target $signalGraphSource | Out-Null
    $env:PSModulePath = $bootstrapRoot + [IO.Path]::PathSeparator + $env:PSModulePath

    foreach ($name in @(
        'Data_AzureSql.Configuration.Tests.ps1',
        'Data_AzureSql.Tests.ps1',
        'Data_AzureSql.Normalization.Tests.ps1',
        'Data_AzureSql.ConnectionParameters.Tests.ps1',
        'Data_AzureSql.ExecutionBoundary.Tests.ps1',
        'Data_AzureSql.LoaderHydration.Tests.ps1',
        'Data_AzureSql.Routing.Tests.ps1'
    )) {
        Write-Output "RUN: $name"
        & pwsh -NoProfile -File (Join-Path $PSScriptRoot $name)
        if ($LASTEXITCODE -ne 0) { $failed.Add($name); Write-Output "FAIL: $name" }
    }

    Write-Output 'RUN: explicit-import fresh process'
    & pwsh -NoProfile -File (Join-Path $PSScriptRoot 'Smoke-AzureSqlImport.ps1') -Manifest $manifest
    if ($LASTEXITCODE -ne 0) { $failed.Add('explicit-import fresh process') }

    Write-Output 'RUN: production lazy-resolution fresh process'
    & pwsh -NoProfile -File (Join-Path $PSScriptRoot 'Smoke-AzureSqlLazyResolution.ps1')
    if ($LASTEXITCODE -ne 0) { $failed.Add('production lazy-resolution fresh process') }

    foreach ($name in @(
        'LazyAdapterLoading.Tests.ps1',
        'Invoke-PlanIteration.Tests.ps1',
        'PlanCondenser.IteratePhase.Tests.ps1',
        'PlanCondenser.InvokePhaseAsync.Tests.ps1',
        'Complete-PlanPhaseTask.Tests.ps1'
    )) {
        Write-Output "RUN: Foundation/$name"
        & pwsh -NoProfile -File (Join-Path $foundationTests $name)
        if ($LASTEXITCODE -ne 0) { $failed.Add("Foundation/$name"); Write-Output "FAIL: Foundation/$name" }
    }

    Write-Output 'RUN: gated live integration fresh process'
    & pwsh -NoProfile -File (Join-Path $PSScriptRoot 'Run-AzureSqlLiveIntegration.ps1')
    if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne 77) { $failed.Add('gated live integration') }

    if ($failed.Count -gt 0) { throw "Prompt H checks failed: $($failed -join ', ')" }
    Write-Output 'PASS: all available Prompt H checks passed; review the live suite SKIP/PASS line separately.'
}
finally {
    $resolvedTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
    $resolvedRoot = [IO.Path]::GetFullPath($bootstrapRoot)
    if (-not $resolvedRoot.StartsWith($resolvedTemp + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Temporary bootstrap root was outside the temporary directory.' }
    if (Test-Path -LiteralPath $moduleLink) { Remove-Item -LiteralPath $moduleLink }
    if (Test-Path -LiteralPath $bootstrapRoot) { Remove-Item -LiteralPath $bootstrapRoot }
}
