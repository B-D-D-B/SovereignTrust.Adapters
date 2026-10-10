[CmdletBinding()]
param([switch]$TargetProbe, [switch]$FixtureProbe)

$ErrorActionPreference = 'Stop'
if ($TargetProbe -and $FixtureProbe) { throw 'Choose one read-only probe mode.' }
$signalGraphSource = (Resolve-Path (Join-Path $PSScriptRoot '../../../../../SignalGraph/Src/PowerShell')).ProviderPath
$liveSuite = (Resolve-Path (Join-Path $PSScriptRoot 'Run-AzureSqlLiveIntegration.ps1')).ProviderPath
$previousModulePath = $env:PSModulePath
$bootstrapRoot = Join-Path ([IO.Path]::GetTempPath()) ('AzureSqlLive_' + [guid]::NewGuid().ToString('N'))
$moduleLink = Join-Path $bootstrapRoot 'SignalGraph'
$exitCode = 1

try {
    New-Item -ItemType Directory -Path $bootstrapRoot | Out-Null
    New-Item -ItemType Junction -Path $moduleLink -Target $signalGraphSource | Out-Null
    $env:PSModulePath = $bootstrapRoot + [IO.Path]::PathSeparator + $previousModulePath
    if ($TargetProbe) { & pwsh -NoProfile -File $liveSuite -TargetProbe }
    elseif ($FixtureProbe) { & pwsh -NoProfile -File $liveSuite -FixtureProbe }
    else { & pwsh -NoProfile -File $liveSuite }
    $exitCode = $LASTEXITCODE
}
finally {
    $env:PSModulePath = $previousModulePath
    $resolvedTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
    $resolvedRoot = [IO.Path]::GetFullPath($bootstrapRoot)
    if (-not $resolvedRoot.StartsWith($resolvedTemp + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Temporary module bootstrap path was outside the temporary directory.'
    }
    if (Test-Path -LiteralPath $moduleLink) { Remove-Item -LiteralPath $moduleLink }
    if (Test-Path -LiteralPath $bootstrapRoot) { Remove-Item -LiteralPath $bootstrapRoot }
}
exit $exitCode
