using System.Text.Json;
using System.Diagnostics;

if (args.Contains("--help"))
{
    Console.WriteLine("-a, --ask-for-approval --ignore-user-config --ignore-rules --strict-config --json --ephemeral --sandbox --color --skip-git-repo-check --cd --output-last-message --model --config --output-schema --image");
    return;
}
if (args.Contains("--version")) { Console.WriteLine("codex-cli 0.160.0 fixture"); return; }
if (args.Length >= 2 && args[0] == "--child-sleep") {
    File.WriteAllText(args[1], Environment.ProcessId.ToString());
    Thread.Sleep(30000);
    return;
}
var modelIndex = Array.IndexOf(args, "--model");
var model = modelIndex >= 0 ? args[modelIndex + 1] : "fixture";
if (model == "fixture-output-first") {
    Console.Out.WriteLine(JsonSerializer.Serialize(new { type = "progress", padding = new string('o', 16384) })); Console.Out.Flush();
    Console.Error.Write(new string('e', 16384)); Console.Error.Flush();
}
if (model == "fixture-never-read") { Thread.Sleep(30000); return; }
if (model == "fixture-descendant") {
    var cdIndex = Array.IndexOf(args, "--cd");
    var marker = Path.Combine(args[cdIndex + 1], "descendant.pid");
    Process.Start(new ProcessStartInfo(Environment.ProcessPath!, $"--child-sleep \"{marker}\"") { UseShellExecute = false });
    Thread.Sleep(30000);
    return;
}
if (model == "fixture-stdout-flood") { Console.Out.Write(new string('x', 100000)); Console.Out.Flush(); Thread.Sleep(30000); return; }
if (model == "fixture-stderr-flood") { Console.Error.Write(new string('x', 100000)); Console.Error.Flush(); Thread.Sleep(30000); return; }
var prompt = Console.In.ReadToEnd();
var finalIndex = Array.IndexOf(args, "--output-last-message");
if (finalIndex < 0) return;
var final = args[finalIndex + 1];
var workingIndex = Array.IndexOf(args, "--cd");
File.AppendAllText(Path.Combine(args[workingIndex + 1], "fixture-invocations.log"), Path.GetDirectoryName(final) + Environment.NewLine);
var mode = prompt.StartsWith("[fixture:") ? prompt.Split(']')[0][9..] : "normal";
if (mode == "flood") { Console.Write(new string('x', 100000)); return; }
if (mode == "timeout") { Thread.Sleep(30000); return; }
if (mode == "fail") { Console.WriteLine("{\"type\":\"turn.failed\"}"); return; }
if (mode == "exit-fail") {
    Console.WriteLine("{\"type\":\"thread.started\"}");
    Console.Error.WriteLine("fixture child failure detail");
    Environment.ExitCode = 23;
    return;
}
if (mode == "malformed") { Console.WriteLine("not json"); return; }
if (mode == "no-final") { Console.WriteLine("{\"type\":\"turn.completed\"}"); return; }
if (mode == "zero-final") { File.WriteAllBytes(final, Array.Empty<byte>()); Console.WriteLine("{\"type\":\"turn.completed\"}"); return; }
if (mode == "oversize-final") { File.WriteAllText(final, new string('z', 300)); Console.WriteLine("{\"type\":\"turn.completed\"}"); return; }
if (mode == "malformed-schema-final") { File.WriteAllText(final, "not-json"); Console.WriteLine("{\"type\":\"turn.completed\"}"); return; }
if (mode == "blank-final") { File.WriteAllText(final, "   "); Console.WriteLine("{\"type\":\"turn.completed\"}"); return; }
var answer = mode == "schema-invalid" ? "{\"answer\":3}" : mode == "schema-valid" || prompt.Contains("artifact prompt") ? "{\"answer\":\"ok\"}" : prompt;
File.WriteAllText(final, answer);
Console.WriteLine("{\"type\":\"thread.started\"}");
Console.WriteLine("{\"type\":\"fixture.unknown\"}");
Console.WriteLine("{\"type\":\"turn.completed\"}");
Console.Error.WriteLine("fixture progress");
