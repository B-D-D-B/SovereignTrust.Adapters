class Storage_LocalFileSystem {
    [object]$Jacket

    Storage_LocalFileSystem() {
        # Empty constructor for flexibility
    }

    [Signal] Construct([object]$dictionary) {
        $signal = [Signal]::Start("Construct-LocalFileSystem") | Select-Object -Last 1

        try {
            if ($null -eq $dictionary) {
                return $signal.LogCritical("Cannot construct LocalFileSystem — provided dictionary is null.")
            }

            $storageJacket = Resolve-StorageResourceRoutesJacket -Jacket $dictionary -Family LocalFileSystem | Select-Object -Last 1
            if ($storageJacket.Failure() -or -not $storageJacket.HasResult()) {
                return $signal.MergeSignal($storageJacket).LogCritical('LocalFileSystem jacket is invalid.')
            }
            $dictionary = $storageJacket.GetResult()

            $this.Jacket = $dictionary
            $signal.LogInformation("LocalFileSystem constructed successfully with provided jacket.")
        }
        catch {
            $signal.LogCritical("Error constructing LocalFileSystem: $_")
        }

        return $signal
    }

    [Signal] ReadObjectAsJson([string]$folder, [string]$fileName) {
        return Get-JsonFromFile -Folder $folder -FileName $fileName
    }

    [Signal] ReadObjectAsXml([string]$folder, [string]$fileName) {
        return Get-XmlFromFile -Folder $folder -FileName $fileName
    }

    [Signal] DeleteFile([string]$folder, [string]$fileName) {
        return Remove-FileFromFileSystem -Folder $folder -FileName $fileName
    }

    [Signal] ListDirectoryObjects([string]$folder) {
        return Get-FileListFromDirectory -Folder $folder
    }
}
