$root = "$PSScriptRoot"
if ($root -ne (Get-Location).Path) {
    Set-Location $root
}

New-ModuleManifest -Path ./SovereignTrust.Adapters.Storage.LocalFileSystem.psd1 `
  -RootModule 'SovereignTrust.Adapters.Storage.LocalFileSystem.psm1' `
  -ModuleVersion '1.0.0' `
  -Author 'Silicon Dream Artists' `
  -CompanyName 'Silicon Dream Artists' `
  -Copyright '(c) Silicon Dream Artists. Current copyright holder: BDDB LLC.' `
  -Description 'Native PowerShell implementation for the core components for SovereignTrust.' `
  -Tags "'SovereignTrust.Core' 'SovereignTrust' 'Public' 'Core'" `
  -LicenseUri 'https://opensource.org/licenses/MIT' `
  -ProjectUri 'https://github.com/B-D-D-B/SovereignTrust.Adapters' `
  -CompatiblePSEditions 'Core' `
  -PowerShellVersion '5.1'

  Invoke-SurfaceFunctionExports -OutputFile 'SovereignTrust.Adapters.Storage.LocalFileSystem.psm1' -Root $PSScriptRoot
  Invoke-SurfaceClassLoads -OutputFile 'SovereignTrust.Adapters.Storage.LocalFileSystem.psm1' -Root $PSScriptRoot
  

  