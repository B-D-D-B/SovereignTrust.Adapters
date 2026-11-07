using module SignalGraph

if (-not (Get-Module -Name 'SovereignTrust.Foundation')) {
    $foundationPath = Join-Path $PSScriptRoot '../../../../../SovereignTrust.Foundation/Src/PowerShell/SovereignTrust.Foundation.psd1'
    Import-Module (Resolve-Path $foundationPath).ProviderPath -ErrorAction Stop
}
# =============================================================================
# LocalFileSystem Storage Module (Signal Compliant)
# SovereignTrust Adapters • SDA Standard Storage Adapter
# =============================================================================

# --- Internal Tools ---
function Get-VirtualFilePath {
    param (
        [Parameter(Mandatory)] [string]$Folder,
        [Parameter(Mandatory)] [string]$FileName
    )

    $folder = $Folder -replace '\\', '/'
    if (![string]::IsNullOrWhiteSpace($folder)) {
        $folder = $folder.Trim('/') + '/'
    }

    return "$folder$FileName"
}

# --- Read Operations ---
function Get-JsonFromFile {
    param (
        [Parameter(Mandatory)] [string]$Folder,
        [Parameter(Mandatory)] [string]$FileName
    )

    $path = Get-VirtualFilePath -Folder $Folder -FileName $FileName
    $signal = [Signal]::Start("Get-JsonFromFile:$path") | Select-Object -Last 1

    try {
        if (!(Test-Path -Path $path)) {
            $null = $signal.LogCritical("File not found: $path")
            return $signal
        }

        $jsonString = Get-Content -Path $path -Raw
        $parsedObject = $jsonString | ConvertFrom-Json

        $null = $signal.SetResult($parsedObject)
        $null = $signal.LogInformation("Successfully loaded JSON object from $path.")
    }
    catch {
        $null = $signal.LogCritical("Error loading JSON from $($path): $_")
    }

    return $signal
}

function Get-XmlFromFile {
    param (
        [Parameter(Mandatory)] [string]$Folder,
        [Parameter(Mandatory)] [string]$FileName
    )

    $path = Get-VirtualFilePath -Folder $Folder -FileName $FileName
    $signal = [Signal]::Start("Get-XmlFromFile:$path") | Select-Object -Last 1

    try {
        if (!(Test-Path -Path $path)) {
            $null = $signal.LogCritical("File not found: $path")
            return $signal
        }

        $xmlDocument = [xml](Get-Content -Path $path -Raw)

        $null = $signal.SetResult($xmlDocument)
        $null = $signal.LogInformation("Successfully loaded XML object from $path.")
    }
    catch {
        $null = $signal.LogCritical("Error loading XML from $($path): $_")
    }

    return $signal
}

function Remove-FileFromFileSystem {
    param (
        [Parameter(Mandatory)] [string]$Folder,
        [Parameter(Mandatory)] [string]$FileName
    )

    $path = Get-VirtualFilePath -Folder $Folder -FileName $FileName
    $signal = [Signal]::Start("Remove-FileFromFileSystem:$path") | Select-Object -Last 1

    try {
        if (Test-Path -Path $path) {
            Remove-Item -Path $path -Force
            $null = $signal.LogInformation("File deleted: $path.")
        }
        else {
            $null = $signal.LogWarning("File to delete not found: $path.")
        }
    }
    catch {
        $null = $signal.LogCritical("Error deleting file: $_")
    }

    return $signal
}

function Get-FileListFromDirectory {
    param (
        [Parameter(Mandatory)] [string]$Folder
    )

    $signal = [Signal]::Start("Get-FileListFromDirectory:$Folder") | Select-Object -Last 1

    try {
        if (!(Test-Path -Path $Folder)) {
            $null = $signal.LogCritical("Folder not found: $Folder")
            return $signal
        }

        $files = Get-ChildItem -Path $Folder | Select-Object -ExpandProperty Name
        $null = $signal.SetResult($files)
        $null = $signal.LogInformation("Listed files in folder: $Folder.")
    }
    catch {
        $null = $signal.LogCritical("Error listing directory contents: $_")
    }

    return $signal
}

############################SovereignTrust.Adapters.Storage.LocalFileSystem.psm1############
Export-ModuleMember -Function 'Get-VirtualFilePath'
Export-ModuleMember -Function 'Get-JsonFromFile'
Export-ModuleMember -Function 'Get-XmlFromFile'
Export-ModuleMember -Function 'Remove-FileFromFileSystem'
Export-ModuleMember -Function 'Get-FileListFromDirectory'

############################CLASS_LOADS############
. "$PSScriptRoot/Storage_LocalFileSystem.ps1"


