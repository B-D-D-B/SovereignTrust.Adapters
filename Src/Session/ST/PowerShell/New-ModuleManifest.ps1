$root = "$PSScriptRoot"
if ($root -ne (Get-Location).Path) {
    Set-Location $root
}

New-ModuleManifest -Path ./Session_ST.psd1 `
  -RootModule 'Session_ST.psm1' `
  -ModuleVersion '1.0.0' `
  -Author 'Silicon Dream Artists' `
  -CompanyName 'Silicon Dream Artists' `
  -Copyright '(c) Silicon Dream Artists. Current copyright holder: BDDB LLC.' `
  -Description 'Native PowerShell implementation for the Azure Key Vault Storage Adapter.' `
  -Tags "'Session_ST' 'SovereignTrust.Adapters' 'SovereignTrust' 'Adapters' 'Public' 'Azure' 'SDA' 'BDDB'" `
  -LicenseUri 'https://opensource.org/licenses/MIT' `
  -ProjectUri 'https://github.com/B-D-D-B/SovereignTrust.Adapters' `
  -CompatiblePSEditions 'Core' `
  -PowerShellVersion '5.1'

  Invoke-GenerateModuleFile -OutputFile 'Session_ST.psm1' -Root $PSScriptRoot
  

  