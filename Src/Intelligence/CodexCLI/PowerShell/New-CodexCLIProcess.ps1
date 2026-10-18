function New-CodexCLIProcess {
    param([object]$Runtime, [object]$Request, [string[]]$Images, [string]$InvocationDirectory)
    $start = [Diagnostics.ProcessStartInfo]::new($Runtime.ExecutablePath)
    $start.UseShellExecute = $false
    $start.RedirectStandardInput = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.StandardInputEncoding = [Text.UTF8Encoding]::new($false)
    $start.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
    $start.StandardErrorEncoding = [Text.UTF8Encoding]::new($false)
    $start.WorkingDirectory = $Runtime.Workspace
    $start.Environment.Clear()
    foreach ($name in @('SystemRoot','WINDIR','PATH','TEMP','TMP','USERPROFILE','APPDATA','LOCALAPPDATA','PROGRAMDATA','COMSPEC','HOMEDRIVE','HOMEPATH')) {
        $value = [Environment]::GetEnvironmentVariable($name)
        if ($null -ne $value) { $start.Environment[$name] = $value }
    }
    $start.Environment['CODEX_HOME'] = if ($Runtime.AuthenticationMode -ceq 'Saved') { $Runtime.CodexHome } else { $InvocationDirectory }
    if ($Runtime.AuthenticationMode -ceq 'ApiKey') { $start.Environment['CODEX_API_KEY'] = $Runtime.ApiKey }
    foreach ($argument in @('-a','never','exec','--ignore-user-config','--ignore-rules','--strict-config','--json','--ephemeral',
        '--sandbox','read-only','--color','never','--skip-git-repo-check','--cd',$Runtime.Workspace,
        '--output-last-message',(Join-Path $InvocationDirectory 'final.txt'),'--model',$Request.Model,
        '--config',('model_reasoning_effort="' + $Request.ReasoningEffort + '"'))) {
        [void]$start.ArgumentList.Add($argument)
    }
    if ($null -ne $Request.SchemaJson) {
        $schemaFile = Join-Path $InvocationDirectory 'schema.json'
        [IO.File]::WriteAllText($schemaFile, $Request.SchemaJson, [Text.UTF8Encoding]::new($false))
        [void]$start.ArgumentList.Add('--output-schema')
        [void]$start.ArgumentList.Add($schemaFile)
    }
    foreach ($image in $Images) { [void]$start.ArgumentList.Add('--image'); [void]$start.ArgumentList.Add($image) }
    [void]$start.ArgumentList.Add('-')
    return $start
}
