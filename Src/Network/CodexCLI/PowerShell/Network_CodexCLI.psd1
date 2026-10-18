@{
    RootModule = 'Network_CodexCLI.psm1'
    ModuleVersion = '1.0.0'
    CompatiblePSEditions = @('Core')
    GUID = 'bc680d61-c489-468f-a4dd-e5f329fb1e71'
    Author = 'Silicon Dream Artists'
    CompanyName = 'Silicon Dream Artists'
    Copyright = '(c) Silicon Dream Artists. Current copyright holder: BDDB LLC.'
    Description = 'Mapped network adapter for noninteractive Codex CLI execution.'
    PowerShellVersion = '7.4'
    RequiredModules = @('SignalGraph')
    FunctionsToExport = @('Resolve-Network_CodexCLI')
    CmdletsToExport = @()
    VariablesToExport = @()
    AliasesToExport = @()
    PrivateData = @{ PSData = @{
        Tags = @('Network_CodexCLI', 'SovereignTrust', 'Adapters')
        LicenseUri = 'https://opensource.org/licenses/MIT'
        ProjectUri = 'https://github.com/B-D-D-B/SovereignTrust.Adapters'
    } }
}
