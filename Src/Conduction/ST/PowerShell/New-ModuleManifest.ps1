$root = "$PSScriptRoot"
if ($root -ne (Get-Location).Path) {
    Set-Location $root
}

New-ModuleManifest -Path ./Conduction_ST.psd1 `
  -RootModule 'Conduction_ST.psm1' `
  -ModuleVersion '1.0.0' `
  -Author 'Silicon Dream Artists' `
  -CompanyName 'Silicon Dream Artists' `
  -Copyright '(c) Silicon Dream Artists. Current copyright holder: BDDB LLC.' `
  -Description 'Native PowerShell implementation for the Azure Key Vault Storage Adapter.' `
  -Tags "'Conduction_ST' 'SovereignTrust.Adapters' 'SovereignTrust' 'Adapters' 'Public' 'Azure' 'SDA' 'BDDB'" `
  -LicenseUri 'https://opensource.org/licenses/MIT' `
  -ProjectUri 'https://github.com/B-D-D-B/SovereignTrust.Adapters' `
  -CompatiblePSEditions 'Core' `
  -PowerShellVersion '5.1'

  Invoke-GenerateModuleFile -OutputFile 'Conduction_ST.psm1' -Root $PSScriptRoot
  

  