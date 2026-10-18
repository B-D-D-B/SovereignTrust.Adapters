function Test-CodexCLIMember {
    param([object]$Object, [string]$Name)
    $opSignal = [Signal]::Start('Test-CodexCLIMember') | Select-Object -Last 1
    try {
        $present = $false
        if ($null -ne $Object) {
            if ($Object -is [Collections.IDictionary]) { $present = $Object.Contains($Name) }
            else { $present = $null -ne $Object.PSObject.Properties[$Name] }
        }
        $opSignal.SetResult([bool]$present) | Out-Null
    }
    catch { $null = $opSignal.LogCritical('CodexCLI member presence check failed.') }
    return $opSignal
}

function Get-CodexCLILiteralMember {
    param([object]$Object, [string]$Name)
    $opSignal = [Signal]::Start('Get-CodexCLILiteralMember') | Select-Object -Last 1
    # Enumerated schema property names and unknown keys may contain path syntax.
    try {
        if ($Object -is [Collections.IDictionary]) { $value = $Object[$Name] }
        else { $value = $Object.PSObject.Properties[$Name].Value }
        $opSignal.SetResult($value) | Out-Null
    }
    catch { $null = $opSignal.LogCritical('CodexCLI literal member lookup failed.') }
    return $opSignal
}

function Get-CodexCLISafeFailureMessage {
    param([string]$Message, [string[]]$Allowed, [string]$Fallback)
    if ($Message -cin $Allowed) { return $Message }
    return $Fallback
}

function Get-CodexCLIKeys {
    param([object]$Object)
    $opSignal = [Signal]::Start('Get-CodexCLIKeys') | Select-Object -Last 1
    try {
        $keys = @()
        if ($Object -is [Collections.IDictionary]) { $keys = @($Object.Keys) }
        elseif ($null -ne $Object) { $keys = @($Object.PSObject.Properties | Where-Object MemberType -eq NoteProperty | ForEach-Object Name) }
        $opSignal.SetResult($keys) | Out-Null
    }
    catch { $null = $opSignal.LogCritical('CodexCLI member enumeration failed.') }
    return $opSignal
}

function Get-CodexCLILimit {
    param([object]$Jacket, [string]$Name, [int]$Default, [int]$Maximum)
    $opSignal = [Signal]::Start("Get-CodexCLILimit:$Name") | Select-Object -Last 1
    try {
        $presenceSignal = Test-CodexCLIMember $Jacket $Name | Select-Object -Last 1
        if ($opSignal.MergeSignalAndVerifyFailure($presenceSignal)) { return $opSignal }
        $value = $Default
        if ($presenceSignal.GetResult()) {
            $fieldSignal = Resolve-PathFromDictionary -Dictionary $Jacket -Path $Name -SignalLevel 'Information' | Select-Object -Last 1
            if ($fieldSignal.Failure()) { throw "Invalid CodexCLI $Name." }
            $value = $null
            if ($fieldSignal.HasResult()) { $value = $fieldSignal.GetResult() }
        }
        if ($value -isnot [int] -and $value -isnot [long] -and $value -isnot [decimal]) { throw "Invalid CodexCLI $Name." }
        if ($value -lt 1 -or $value -gt $Maximum -or [decimal]$value -ne [decimal][int]$value) { throw "Invalid CodexCLI $Name." }
        $opSignal.SetResult([int]$value) | Out-Null
    }
    catch { $null = $opSignal.LogCritical("Invalid CodexCLI $Name.") }
    return $opSignal
}

function Assert-CodexCLIAbsoluteDirectory {
    param([object]$Value, [string]$Name)
    $opSignal = [Signal]::Start("Assert-CodexCLIAbsoluteDirectory:$Name") | Select-Object -Last 1
    try {
        if ($Value -isnot [string] -or -not [IO.Path]::IsPathFullyQualified($Value) -or -not [IO.Directory]::Exists($Value)) {
            throw 'Invalid directory.'
        }
        $opSignal.SetResult([IO.Path]::GetFullPath($Value)) | Out-Null
    }
    catch { $null = $opSignal.LogCritical("CodexCLI $Name must be an existing absolute directory.") }
    return $opSignal
}

function Invoke-CodexCLIHelp {
    param([string]$Executable, [string[]]$Arguments)
    $opSignal = [Signal]::Start('Invoke-CodexCLIHelp') | Select-Object -Last 1
    try {
    $start = [Diagnostics.ProcessStartInfo]::new($Executable)
    $start.UseShellExecute = $false
    $start.RedirectStandardInput = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($argument in $Arguments) { [void]$start.ArgumentList.Add($argument) }
    Initialize-CodexCLIProcessType
    $result = [CodexCLIProcessRunner]::Run($start,'',5,65536,65536).GetAwaiter().GetResult()
    if ($result.ExitCode -ne 0) { throw 'CodexCLI qualification failed.' }
    $opSignal.SetResult($result.Stdout) | Out-Null
    }
    catch { $null = $opSignal.LogCritical('CodexCLI qualification failed.') }
    return $opSignal
}

function Test-CodexCLIPluginContent {
    param([string]$Directory)
    foreach ($entry in ([IO.DirectoryInfo]::new($Directory)).EnumerateFileSystemInfos()) {
        if (($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or $entry -isnot [IO.DirectoryInfo]) { return $true }
        if (Test-CodexCLIPluginContent $entry.FullName) { return $true }
    }
    return $false
}

function Resolve-CodexCLIRuntime {
    param([object]$Jacket)
    $opSignal = [Signal]::Start('Resolve-CodexCLIRuntime') | Select-Object -Last 1
    try {
    if ($null -eq $Jacket) { throw 'CodexCLI jacket is required.' }
    $settingsSignal = Resolve-PathFromDictionary -Dictionary $Jacket -Path 'CodexCLI' -SignalLevel 'Information' | Select-Object -Last 1
    $settings = $null
    if (-not $settingsSignal.Failure() -and $settingsSignal.HasResult()) { $settings = $settingsSignal.GetResult() }
    if ($settings -isnot [Collections.IDictionary] -and $settings -isnot [pscustomobject]) { throw 'CodexCLI jacket settings are required.' }
    $environmentPresence = Test-CodexCLIMember $settings 'Environment' | Select-Object -Last 1
    if ($opSignal.MergeSignalAndVerifyFailure($environmentPresence)) { return $opSignal }
    if ($environmentPresence.GetResult()) { throw 'CodexCLI jacket environment overrides are unsupported.' }
    foreach ($legacyName in @('Model','AllowedModels')) {
        $legacyPresence = Test-CodexCLIMember $settings $legacyName | Select-Object -Last 1
        if ($opSignal.MergeSignalAndVerifyFailure($legacyPresence)) { return $opSignal }
        if ($legacyPresence.GetResult()) { throw 'CodexCLI legacy model settings are unsupported.' }
    }
    $executableSignal = Resolve-PathFromDictionary -Dictionary $settings -Path 'ExecutablePath' -SignalLevel 'Information' | Select-Object -Last 1
    $executable = $null
    if (-not $executableSignal.Failure() -and $executableSignal.HasResult()) { $executable = $executableSignal.GetResult() }
    if ($executable -isnot [string] -or -not [IO.Path]::IsPathFullyQualified($executable) -or -not [IO.File]::Exists($executable)) { throw 'CodexCLI executable path is invalid.' }
    $executable = [IO.Path]::GetFullPath($executable)
    $workspaceField = Resolve-PathFromDictionary -Dictionary $settings -Path 'Workspace' -SignalLevel 'Information' | Select-Object -Last 1
    $workspaceValue = $null
    if (-not $workspaceField.Failure() -and $workspaceField.HasResult()) { $workspaceValue = $workspaceField.GetResult() }
    $workspaceSignal = Assert-CodexCLIAbsoluteDirectory $workspaceValue 'Workspace' | Select-Object -Last 1
    if ($opSignal.MergeSignalAndVerifyFailure($workspaceSignal)) { return $opSignal }
    $workspace = $workspaceSignal.GetResult()
    $cursor = [IO.DirectoryInfo]::new($workspace)
    while ($null -ne $cursor) {
        foreach ($relative in @('AGENTS.md', '.codex/config.toml', '.codex/hooks.json')) {
            if ([IO.File]::Exists((Join-Path $cursor.FullName $relative))) { throw 'CodexCLI workspace contains disallowed instructions or configuration.' }
        }
        $cursor = $cursor.Parent
    }
    $modeSignal = Resolve-PathFromDictionary -Dictionary $settings -Path 'AuthenticationMode' -SignalLevel 'Information' | Select-Object -Last 1
    $mode = $null
    if (-not $modeSignal.Failure() -and $modeSignal.HasResult()) { $mode = $modeSignal.GetResult() }
    if ($mode -cnotin @('Saved', 'ApiKey')) { throw 'CodexCLI AuthenticationMode must be Saved or ApiKey.' }
    $codexHome = $null
    $apiKey = $null
    $allowSavedHomeExtensions = $false
    $extensionPresence = Test-CodexCLIMember $settings 'AllowSavedHomeExtensions' | Select-Object -Last 1
    if ($opSignal.MergeSignalAndVerifyFailure($extensionPresence)) { return $opSignal }
    if ($extensionPresence.GetResult()) {
        $extensionSignal = Get-CodexCLILiteralMember $settings 'AllowSavedHomeExtensions' | Select-Object -Last 1
        if ($opSignal.MergeSignalAndVerifyFailure($extensionSignal)) { return $opSignal }
        if (-not $extensionSignal.HasResult() -or $extensionSignal.GetResult() -isnot [bool]) { throw 'CodexCLI AllowSavedHomeExtensions must be a Boolean.' }
        $allowSavedHomeExtensions = $extensionSignal.GetResult()
    }
    if ($mode -ceq 'Saved') {
        $homeField = Resolve-PathFromDictionary -Dictionary $settings -Path 'CodexHome' -SignalLevel 'Information' | Select-Object -Last 1
        $homeValue = $null
        if (-not $homeField.Failure() -and $homeField.HasResult()) { $homeValue = $homeField.GetResult() }
        $homeSignal = Assert-CodexCLIAbsoluteDirectory $homeValue 'CodexHome' | Select-Object -Last 1
        if ($opSignal.MergeSignalAndVerifyFailure($homeSignal)) { return $opSignal }
        $codexHome = $homeSignal.GetResult()
        $plugins = Join-Path $codexHome 'plugins'
        if (-not $allowSavedHomeExtensions -and ([IO.File]::Exists((Join-Path $codexHome 'hooks.json')) -or
            ([IO.Directory]::Exists($plugins) -and (Test-CodexCLIPluginContent $plugins)))) {
            throw 'CodexCLI saved home contains disallowed hooks or plugins.'
        }
    }
    else {
        $apiKeySignal = Resolve-PathFromDictionary -Dictionary $settings -Path 'ApiKey' -SignalLevel 'Information' | Select-Object -Last 1
        $apiKey = $null
        if (-not $apiKeySignal.Failure() -and $apiKeySignal.HasResult()) { $apiKey = $apiKeySignal.GetResult() }
        if ($apiKey -isnot [string] -or [string]::IsNullOrWhiteSpace($apiKey)) { throw 'CodexCLI API key is unavailable.' }
    }
    $defaultSignal = Resolve-PathFromDictionary -Dictionary $Jacket -Path 'DefaultModelKey' -SignalLevel 'Information' | Select-Object -Last 1
    $profilesSignal = Resolve-PathFromDictionary -Dictionary $Jacket -Path 'Profiles' -SignalLevel 'Information' | Select-Object -Last 1
    if ($defaultSignal.Failure() -or -not $defaultSignal.HasResult() -or $profilesSignal.Failure() -or -not $profilesSignal.HasResult()) { throw 'CodexCLI profiles are invalid.' }
    $defaultModelKey = $defaultSignal.GetResult()
    $profileItems = $profilesSignal.GetResult()
    if ($defaultModelKey -isnot [string] -or [string]::IsNullOrWhiteSpace($defaultModelKey) -or $profileItems -is [string] -or $profileItems -isnot [Collections.IEnumerable]) { throw 'CodexCLI profiles are invalid.' }
    $profiles = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
    foreach ($profile in $profileItems) {
        if ($profile -isnot [Collections.IDictionary] -and $profile -isnot [pscustomobject]) { throw 'CodexCLI profiles are invalid.' }
        $keySignal = Resolve-PathFromDictionary -Dictionary $profile -Path 'ModelKey' -SignalLevel 'Information' | Select-Object -Last 1
        $modelSignal = Resolve-PathFromDictionary -Dictionary $profile -Path 'Model' -SignalLevel 'Information' | Select-Object -Last 1
        $effortSignal = Resolve-PathFromDictionary -Dictionary $profile -Path 'ReasoningEffort' -SignalLevel 'Information' | Select-Object -Last 1
        if ($keySignal.Failure() -or -not $keySignal.HasResult() -or $modelSignal.Failure() -or -not $modelSignal.HasResult() -or $effortSignal.Failure() -or -not $effortSignal.HasResult()) { throw 'CodexCLI profiles are invalid.' }
        $key = $keySignal.GetResult(); $model = $modelSignal.GetResult(); $effort = $effortSignal.GetResult()
        if ($key -isnot [string] -or [string]::IsNullOrWhiteSpace($key) -or $model -isnot [string] -or [string]::IsNullOrWhiteSpace($model) -or
            $effort -isnot [string] -or $effort -cnotin @('none','minimal','low','medium','high','xhigh','max','ultra') -or $profiles.ContainsKey($key)) { throw 'CodexCLI profiles are invalid.' }
        $tokensSignal = Resolve-PathFromDictionary -Dictionary $profile -Path 'MaxInputTokens' -SignalLevel 'Information' | Select-Object -Last 1
        $maxInputTokens = $null
        if (-not $tokensSignal.Failure() -and $tokensSignal.HasResult()) {
            $maxInputTokens = $tokensSignal.GetResult()
            if ($maxInputTokens -isnot [int] -and $maxInputTokens -isnot [long]) { throw 'CodexCLI profiles are invalid.' }
            if ($maxInputTokens -le 0) { throw 'CodexCLI profiles are invalid.' }
        }
        $profiles.Add($key, [pscustomobject]@{ ModelKey=$key; Model=$model; ReasoningEffort=$effort; MaxInputTokens=$maxInputTokens })
    }
    if ($profiles.Count -eq 0 -or -not $profiles.ContainsKey($defaultModelKey)) { throw 'CodexCLI profiles are invalid.' }
    $limits = @{}
    foreach ($entry in @(
        @('TimeoutSeconds',120,600), @('MaxPromptBytes',262144,1048576), @('MaxEventBytes',1048576,4194304),
        @('MaxStderrBytes',65536,262144), @('MaxFinalBytes',1048576,4194304), @('MaxImages',4,8),
        @('MaxImageBytes',10485760,20971520), @('MaxDownloadSeconds',15,60)
    )) {
        $limitSignal = Get-CodexCLILimit $settings $entry[0] $entry[1] $entry[2] | Select-Object -Last 1
        if ($opSignal.MergeSignalAndVerifyFailure($limitSignal)) { return $opSignal }
        $limits[$entry[0]] = $limitSignal.GetResult()
    }
    $hostPresence = Test-CodexCLIMember $settings 'AllowedImageHosts' | Select-Object -Last 1
    if ($opSignal.MergeSignalAndVerifyFailure($hostPresence)) { return $opSignal }
    $allowedHosts = @()
    if ($hostPresence.GetResult()) {
        $hostsSignal = Resolve-PathFromDictionary -Dictionary $settings -Path 'AllowedImageHosts' -SignalLevel 'Information' | Select-Object -Last 1
        if (-not $hostsSignal.Failure() -and $hostsSignal.HasResult()) { $allowedHosts = $hostsSignal.GetResult() }
        else { $allowedHosts = $null }
    }
    $allowedHosts = @($allowedHosts)
    $rootPresence = Test-CodexCLIMember $settings 'AllowedLocalImageRoots' | Select-Object -Last 1
    if ($opSignal.MergeSignalAndVerifyFailure($rootPresence)) { return $opSignal }
    $allowedRoots = @()
    if ($rootPresence.GetResult()) {
        $rootsSignal = Resolve-PathFromDictionary -Dictionary $settings -Path 'AllowedLocalImageRoots' -SignalLevel 'Information' | Select-Object -Last 1
        if (-not $rootsSignal.Failure() -and $rootsSignal.HasResult()) { $allowedRoots = $rootsSignal.GetResult() }
        else { $allowedRoots = $null }
    }
    $allowedRoots = @($allowedRoots)
    foreach ($hostName in $allowedHosts) { if ($hostName -isnot [string] -or ($hostName -cne '*' -and $hostName -notmatch '^[a-zA-Z0-9.-]+$')) { throw 'CodexCLI image host allowlist is invalid.' } }
    $roots = @()
    foreach ($root in $allowedRoots) {
        if ($root -is [string] -and $root -ceq '*') { $roots += '*'; continue }
        $rootSignal = Assert-CodexCLIAbsoluteDirectory $root 'AllowedLocalImageRoots' | Select-Object -Last 1
        if ($opSignal.MergeSignalAndVerifyFailure($rootSignal)) { return $opSignal }
        $roots += $rootSignal.GetResult()
    }
    $versionSignal = Invoke-CodexCLIHelp $executable @('--version') | Select-Object -Last 1
    if ($opSignal.MergeSignalAndVerifyFailure($versionSignal)) { return $opSignal }
    $version = $versionSignal.GetResult()
    if ([string]::IsNullOrWhiteSpace($version)) { throw 'CodexCLI executable version is unavailable.' }
    $rootHelpSignal = Invoke-CodexCLIHelp $executable @('--help') | Select-Object -Last 1
    if ($opSignal.MergeSignalAndVerifyFailure($rootHelpSignal)) { return $opSignal }
    $rootHelp = $rootHelpSignal.GetResult()
    $execHelpSignal = Invoke-CodexCLIHelp $executable @('exec','--help') | Select-Object -Last 1
    if ($opSignal.MergeSignalAndVerifyFailure($execHelpSignal)) { return $opSignal }
    $execHelp = $execHelpSignal.GetResult()
    if ($rootHelp -notmatch '-a, --ask-for-approval') { throw 'CodexCLI executable lacks required options.' }
    foreach ($option in @('--ignore-user-config','--ignore-rules','--strict-config','--json','--ephemeral','--sandbox','--color','--skip-git-repo-check','--cd','--output-last-message','--model','--config','--output-schema','--image')) {
        if (-not $execHelp.Contains($option)) { throw 'CodexCLI executable lacks required options.' }
    }
    $opSignal.SetResult([pscustomobject]@{ ExecutablePath=$executable; Workspace=$workspace; AuthenticationMode=$mode; CodexHome=$codexHome; ApiKey=$apiKey; AllowSavedHomeExtensions=$allowSavedHomeExtensions;
        DefaultModelKey=$defaultModelKey; Profiles=$profiles; Limits=$limits; AllowedImageHosts=$allowedHosts; AllowedLocalImageRoots=$roots }) | Out-Null
    }
    catch {
        $safe = Get-CodexCLISafeFailureMessage $_.Exception.Message @(
            'CodexCLI jacket is required.', 'CodexCLI jacket settings are required.',
            'CodexCLI jacket environment overrides are unsupported.', 'CodexCLI executable path is invalid.',
            'CodexCLI legacy model settings are unsupported.',
            'CodexCLI workspace contains disallowed instructions or configuration.',
            'CodexCLI AuthenticationMode must be Saved or ApiKey.',
            'CodexCLI saved home contains disallowed hooks or plugins.', 'CodexCLI AllowSavedHomeExtensions must be a Boolean.', 'CodexCLI API key is unavailable.',
            'CodexCLI profiles are invalid.', 'CodexCLI image host allowlist is invalid.',
            'CodexCLI qualification failed.', 'CodexCLI executable version is unavailable.',
            'CodexCLI executable lacks required options.',
            'CodexCLI Workspace must be an existing absolute directory.',
            'CodexCLI CodexHome must be an existing absolute directory.',
            'CodexCLI AllowedLocalImageRoots must be an existing absolute directory.'
        ) 'CodexCLI runtime validation or executable qualification failed.'
        if ($_.Exception.Message -match '^Invalid CodexCLI (TimeoutSeconds|MaxPromptBytes|MaxEventBytes|MaxStderrBytes|MaxFinalBytes|MaxImages|MaxImageBytes|MaxDownloadSeconds)\.$') {
            $safe = $_.Exception.Message
        }
        $null = $opSignal.LogCritical($safe)
    }
    return $opSignal
}
