[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$project = Join-Path $PSScriptRoot 'Packaging/SqlClientRuntime.csproj'
$nugetConfig = Join-Path $PSScriptRoot 'Packaging/NuGet.Config'
$env:NUGET_PACKAGES = Join-Path $PSScriptRoot 'Packaging/.nuget/packages'
$env:APPDATA = Join-Path $PSScriptRoot 'Packaging/.appdata'
$module = Join-Path $PSScriptRoot 'PowerShell'
$destination = Join-Path $module 'dependencies'
$publish = Join-Path $PSScriptRoot 'Packaging/bin/Release/net8.0/win-x64/publish'

if (-not (Test-Path (Join-Path $PSScriptRoot 'Packaging/packages.lock.json'))) {
    throw 'AzureSql packages.lock.json is missing. Restore the pinned project and commit its lock file first.'
}
& dotnet restore $project --runtime win-x64 --configfile $nugetConfig --locked-mode
if ($LASTEXITCODE -ne 0) { throw 'AzureSql dependency restore failed.' }
& dotnet publish $project --configuration Release --runtime win-x64 --self-contained false --no-restore
if ($LASTEXITCODE -ne 0) { throw 'AzureSql dependency publish failed.' }

$resolvedModule = [IO.Path]::GetFullPath($module).TrimEnd('\')
$resolvedDestination = [IO.Path]::GetFullPath($destination)
if (-not $resolvedDestination.StartsWith($resolvedModule + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Refusing to replace dependencies outside the AzureSql module directory.'
}
if (Test-Path $destination) { Remove-Item -LiteralPath $destination -Recurse -Force }
New-Item -ItemType Directory -Path $destination | Out-Null
Copy-Item -Path (Join-Path $publish '*') -Destination $destination -Recurse -Force

$required = @('Microsoft.Data.SqlClient.dll', 'Microsoft.Data.SqlClient.SNI.dll', 'SqlClientRuntime.deps.json')
foreach ($name in $required) {
    if (-not (Test-Path (Join-Path $destination $name))) { throw "Published AzureSql dependency '$name' is missing." }
}
$deps = Get-Content -LiteralPath (Join-Path $destination 'SqlClientRuntime.deps.json') -Raw | ConvertFrom-Json -AsHashtable
$target = $deps.targets[$deps.runtimeTarget.name]
if (-not $target.Contains('Microsoft.Data.SqlClient/6.1.7')) { throw 'Published dependency graph does not contain the pinned SqlClient package.' }
foreach ($package in $target.Keys) {
    foreach ($assetKind in @('runtime', 'native')) {
        if (-not $target[$package].Contains($assetKind)) { continue }
        foreach ($asset in $target[$package][$assetKind].Keys) {
            $fileName = [IO.Path]::GetFileName($asset)
            if (-not (Test-Path -LiteralPath (Join-Path $destination $fileName) -PathType Leaf)) {
                throw "Published $assetKind asset is missing for ${package}: $fileName"
            }
        }
    }
}
$files = @(Get-ChildItem -LiteralPath $destination -File -Recurse | ForEach-Object {
    $_.FullName.Substring($destination.Length + 1).Replace('\', '/')
} | Sort-Object)
$inventory = [ordered]@{ Package = 'Microsoft.Data.SqlClient'; Version = '6.1.7'; TargetFramework = 'net8.0'; RuntimeIdentifier = 'win-x64'; Files = $files }
ConvertTo-Json -InputObject $inventory -Depth 5 | Set-Content -LiteralPath (Join-Path $destination 'inventory.json') -Encoding utf8
Write-Output "Packaged $($files.Count) runtime files in $destination"
