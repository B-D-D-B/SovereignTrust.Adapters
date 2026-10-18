$script:CodexCLIProcessTypeReady = $false
function Initialize-CodexCLIProcessType {
    if ($script:CodexCLIProcessTypeReady) { return }
    Add-Type -TypeDefinition @'
using System;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
public sealed class CodexCLIProcessResult { public string Stdout; public string Stderr; public int ExitCode; }
public static class CodexCLIProcessRunner {
  static async Task<string> Drain(StreamReader reader, int maxBytes, CancellationToken token) {
    var buffer = new char[4096]; var output = new StringBuilder(); int bytes = 0;
    while (true) {
      int count = await reader.ReadAsync(buffer.AsMemory(), token);
      if (count == 0) break;
      output.Append(buffer, 0, count);
      bytes += Encoding.UTF8.GetByteCount(buffer, 0, count);
      if (bytes > maxBytes) throw new InvalidOperationException("CodexCLI output limit exceeded.");
    }
    return output.ToString();
  }
  public static async Task<CodexCLIProcessResult> Run(ProcessStartInfo start, string prompt, int seconds, int maxOut, int maxErr) {
    using var process = new Process { StartInfo = start };
    using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(seconds));
    if (!process.Start()) throw new InvalidOperationException("CodexCLI process failed to start.");
    try {
      var stdout = Drain(process.StandardOutput, maxOut, deadline.Token);
      var stderr = Drain(process.StandardError, maxErr, deadline.Token);
      _ = stdout.ContinueWith(t => { if (t.IsFaulted && !process.HasExited) { try { process.Kill(true); } catch {} } });
      _ = stderr.ContinueWith(t => { if (t.IsFaulted && !process.HasExited) { try { process.Kill(true); } catch {} } });
      var write = Task.Run(async () => { await process.StandardInput.WriteAsync(prompt.AsMemory(), deadline.Token); process.StandardInput.Close(); }, deadline.Token);
      var exit = process.WaitForExitAsync(deadline.Token);
      await Task.WhenAll(stdout, stderr, write, exit).WaitAsync(deadline.Token);
      return new CodexCLIProcessResult { Stdout = stdout.Result, Stderr = stderr.Result, ExitCode = process.ExitCode };
    } catch (OperationCanceledException) { throw new TimeoutException("CodexCLI execution timed out."); }
    finally {
      if (!process.HasExited) { try { process.Kill(true); } catch {} try { await process.WaitForExitAsync(); } catch {} }
    }
  }
}
'@ -ErrorAction Stop
    $script:CodexCLIProcessTypeReady = $true
}

function Assert-CodexCLIEvents {
    param([string]$Stdout, [int]$ExitCode)
    if ($ExitCode -ne 0) { throw "CodexCLI process exited unsuccessfully (exit code $ExitCode)." }
    $completed = $false
    foreach ($line in ($Stdout -split "`r?`n")) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try { $event = ConvertFrom-Json -InputObject $line -Depth 100 -ErrorAction Stop }
        catch { throw 'CodexCLI emitted malformed JSONL.' }
        if ($null -eq $event.type -or $event.type -isnot [string]) { throw 'CodexCLI event has no type.' }
        if ($event.type -ceq 'turn.failed' -or $event.type -ceq 'error') { throw 'CodexCLI reported a terminal failure.' }
        if ($event.type -ceq 'turn.completed') { $completed = $true }
    }
    if (-not $completed) { throw 'CodexCLI turn did not complete.' }
}

function Add-CodexCLIProcessOutputToSignal {
    param([object]$Run, [Signal]$Signal, [bool]$Failed)
    foreach ($line in ($Run.Stdout -split "`r?`n")) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $type = $null
        try { $type = (ConvertFrom-Json -InputObject $line -Depth 100 -ErrorAction Stop).type }
        catch { }
        if ($type -ceq 'error' -or $type -ceq 'turn.failed') {
            $null = $Signal.LogCritical("CodexCLI stdout: $line")
        }
        else { $null = $Signal.LogInformation("CodexCLI stdout: $line") }
    }
    foreach ($line in ($Run.Stderr -split "`r?`n")) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        if ($Failed) { $null = $Signal.LogCritical("CodexCLI stderr: $line") }
        else { $null = $Signal.LogInformation("CodexCLI stderr: $line") }
    }
}

function Remove-CodexCLIInvocationDirectory {
    param([string]$Directory)
    if ($null -ne $Directory -and [IO.Directory]::Exists($Directory)) { [IO.Directory]::Delete($Directory, $true) }
}

function Invoke-CodexCLIExecution {
    param([object]$Adapter, [object]$Config)
    $opSignal = [Signal]::Start('Invoke-CodexCLIExecution') | Select-Object -Last 1
    $directory = $null
    $result = $null
    $run = $null
    $failure = $null
    $failureSignal = $null
    $failureCategory = 'CodexCLI execution failed.'
    try {
        $runtimeSignal = Resolve-CodexCLIRuntime $Adapter.Configuration | Select-Object -Last 1
        if ($runtimeSignal.Failure() -or -not $runtimeSignal.HasResult()) {
            $failureSignal = $runtimeSignal
            throw 'CodexCLI runtime validation failed.'
        }
        $runtime = $runtimeSignal.GetResult()
        $requestSignal = Resolve-CodexCLIPrompt $Config $runtime | Select-Object -Last 1
        if ($requestSignal.Failure() -or -not $requestSignal.HasResult()) {
            $failureSignal = $requestSignal
            throw 'CodexCLI prompt validation failed.'
        }
        $request = $requestSignal.GetResult()
        $directory = Join-Path ([IO.Path]::GetTempPath()) ('codexcli-' + [guid]::NewGuid().ToString('N'))
        [IO.Directory]::CreateDirectory($directory) | Out-Null
        $mediaSignal = Resolve-CodexCLIMedia $request.Media $runtime $directory | Select-Object -Last 1
        if ($mediaSignal.Failure() -or -not $mediaSignal.HasResult()) {
            $failureSignal = $mediaSignal
            throw 'CodexCLI media validation failed.'
        }
        $images = @($mediaSignal.GetResult())
        if ([string]::IsNullOrWhiteSpace($request.Text)) {
            if ($images.Count -eq 0) { throw 'CodexCLI prompt is empty.' }
            $request.Text = 'Respond to the attached image(s).'
            $schemaBytes = if ($null -eq $request.SchemaJson) { 0 } else { [Text.Encoding]::UTF8.GetByteCount($request.SchemaJson) }
            if ([Text.Encoding]::UTF8.GetByteCount($request.Text) + $schemaBytes -gt $runtime.Limits.MaxPromptBytes) { throw 'CodexCLI prompt exceeds the configured limit.' }
        }
        $start = New-CodexCLIProcess $runtime $request $images $directory
        Initialize-CodexCLIProcessType
        $run = [CodexCLIProcessRunner]::Run($start,$request.Text,$runtime.Limits.TimeoutSeconds,$runtime.Limits.MaxEventBytes,$runtime.Limits.MaxStderrBytes).GetAwaiter().GetResult()
        Assert-CodexCLIEvents $run.Stdout $run.ExitCode
        $finalFile = Join-Path $directory 'final.txt'
        if (-not [IO.File]::Exists($finalFile)) { throw 'CodexCLI final response is absent.' }
        $length = ([IO.FileInfo]::new($finalFile)).Length
        if ($length -eq 0 -or $length -gt $runtime.Limits.MaxFinalBytes) { throw 'CodexCLI final response size is invalid.' }
        $final = [IO.File]::ReadAllText($finalFile, [Text.UTF8Encoding]::new($false,$true))
        if ([string]::IsNullOrWhiteSpace($final)) { throw 'CodexCLI final response is blank.' }
        if ($null -ne $request.SchemaJson) {
            $command = Get-Command Test-Json -ErrorAction SilentlyContinue
            if ($null -eq $command) { throw 'Local schema validation is unavailable.' }
            if (-not (Test-Json -Json $final -SchemaFile (Join-Path $directory 'schema.json') -ErrorAction Stop)) { throw 'CodexCLI final response violates OutputSchema.' }
        }
        $result = ConvertTo-CodexCLIJsonResult $final
    }
    catch {
        $failure = $_
        if ($null -ne $run) {
            if ($run.ExitCode -ne 0) { $failureCategory = "CodexCLI process exited unsuccessfully (exit code $($run.ExitCode))." }
        }
        if ($null -eq $failureSignal) {
            switch -Regex ($_.Exception.Message) {
                'CodexCLI output limit exceeded\.' { $failureCategory = 'CodexCLI output limit exceeded.'; break }
                'CodexCLI reported a terminal failure\.' { $failureCategory = 'CodexCLI reported a terminal failure.'; break }
                'CodexCLI execution timed out\.' { $failureCategory = 'CodexCLI execution timed out.'; break }
            }
        }
    }
    finally {
        try { Remove-CodexCLIInvocationDirectory $directory }
        catch { if ($null -eq $failure) { $failure = $_; $failureCategory = 'CodexCLI invocation cleanup failed.' } }
    }
    if ($null -ne $run) { Add-CodexCLIProcessOutputToSignal $run $opSignal ($null -ne $failure) }
    if ($null -ne $failure) {
        if ($null -ne $failureSignal) { $opSignal.MergeSignal($failureSignal) | Out-Null }
        else { $null = $opSignal.LogCritical($failureCategory) }
        return $opSignal
    }
    $opSignal.SetResult($result) | Out-Null
    return $opSignal
}
