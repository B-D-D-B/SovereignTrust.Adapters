$root = "$PSScriptRoot"
if ($root -ne (Get-Location).Path) {
    Set-Location $root
}

New-ModuleManifest -Path ./Storage_AzureKeyVault.psd1 `
  -RootModule 'Storage_AzureKeyVault.psm1' `
  -ModuleVersion '1.0.0' `
  -Author 'Silicon Dream Artists' `
  -CompanyName 'Silicon Dream Artists' `
  -Copyright '(c) Silicon Dream Artists. Current copyright holder: BDDB LLC.' `
  -Description 'Native PowerShell implementation for the Azure Key Vault Storage Adapter.' `
  -Tags "'Storage_AzureKeyVault' 'SovereignTrust.Adapters' 'SovereignTrust' 'Adapters' 'Public' 'Azure' 'SDA' 'BDDB'" `
  -LicenseUri 'https://opensource.org/licenses/MIT' `
  -ProjectUri 'https://github.com/B-D-D-B/SovereignTrust.Adapters' `
  -CompatiblePSEditions 'Core' `
  -PowerShellVersion '5.1'

  Invoke-GenerateModuleFile -OutputFile 'Storage_AzureKeyVault.psm1' -Root $PSScriptRoot
  

  