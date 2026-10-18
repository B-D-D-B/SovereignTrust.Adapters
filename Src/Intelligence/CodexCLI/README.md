# Intelligence.CodexCLI

This mapped intelligence adapter runs `SendMessage` plans through a separately installed Codex CLI and returns JSON text with `choices[0].message.role = "assistant"` and `choices[0].message.content` set to the final response. `HandleMessage` uses the existing SignalGraph path resolver and optional Foundation Format condenser. The module exports only `Resolve-Intelligence_CodexCLI`. Import and `Construct` do not run Codex.

## Trusted jacket

The Foundation-hydrated mapped jacket has `Name`, `VirtualPath`, `IsMapped`, root-level `DefaultModelKey` and `Profiles`, and a nested `CodexCLI` object. Each profile maps a unique `ModelKey` to a provider `Model` and `ReasoningEffort`. `CodexCLI` supplies an absolute existing `ExecutablePath`, an absolute existing dedicated `Workspace`, and `AuthenticationMode` (`Saved` or `ApiKey`). A jacket mapped to `Intelligence.AI` uses `SovereignTrust.Adapters.Intelligence.CodexCLI.AI.Persistent.Run`; a separate jacket mapped to `Intelligence.CodexCLI` uses `SovereignTrust.Adapters.Intelligence.CodexCLI.CodexCLI.Persistent.Run`. Saved mode also requires an existing absolute `CodexHome` with a previously completed CLI sign-in. ApiKey mode requires a nonblank hydrated `ApiKey`; it is supplied only to the child as `CODEX_API_KEY`. Neither mode reads auth files or changes the parent process environment. An extra nested `Environment` map is rejected.

Synthetic jacket shape (Foundation replaces the example key token before `Construct`):

```json
{
  "Name": "CodexCLIAI",
  "VirtualPath": "SovereignTrust.Adapters.Intelligence.CodexCLI.AI.Persistent.Run",
  "IsMapped": true,
  "Kind": "Network",
  "Slot": "AI",
  "DefaultModelKey": "Worker-Medium",
  "Profiles": [{ "ModelKey": "Worker-Medium", "Model": "gpt-5.6-sol", "ReasoningEffort": "medium" }],
  "CodexCLI": {
    "ExecutablePath": "C:/Tools/Codex/codex.exe",
    "Workspace": "C:/CodexCLIWorkspace",
    "AuthenticationMode": "ApiKey",
    "ApiKey": "[Storage.Secrets.Read.codex-api-key|]"
  }
}
```

Optional `CodexCLI` bounds and defaults: `TimeoutSeconds` 120 (maximum 600), `MaxPromptBytes` 262144 (maximum 1048576), `MaxEventBytes` 1048576 (maximum 4194304), `MaxStderrBytes` 65536 (maximum 262144), `MaxFinalBytes` 1048576 (maximum 4194304), `MaxImages` 4 (maximum 8), `MaxImageBytes` 10485760 (maximum 20971520), and `MaxDownloadSeconds` 15 (maximum 60). Invalid or nonpositive values fail. `AllowedImageHosts` is an exact HTTPS host allowlist and defaults to empty. `AllowedLocalImageRoots` is a list of existing absolute directories and defaults to empty. Either list may contain `"*"`: `AllowedImageHosts: ["*"]` permits any hostname, and `AllowedLocalImageRoots: ["*"]` permits local images in any directory. This bypasses only host/root matching; HTTPS, public-address, redirect, file-link, image-format, size, and timeout checks still apply.

A profile may include a positive integer `MaxInputTokens` as planning metadata. The adapter does not pass it to Codex or use it to truncate prompts.

The adapter checks CLI help for the fixed invocation options and uses `-a never exec --ignore-user-config --ignore-rules --strict-config --json --ephemeral --sandbox read-only --color never --skip-git-repo-check --cd <Workspace> --output-last-message <owned file> --model <selected model> --config model_reasoning_effort="<selected effort>" [--output-schema <owned file>] [--image <owned file> ...] -`. The prompt goes only to UTF-8 stdin. It rejects `AGENTS.md`, `.codex/config.toml`, or `.codex/hooks.json` in the workspace ancestry. By default, Saved `CodexHome` rejects `hooks.json` and plugin files or links, but permits empty `plugins` directories, including empty nested directories. The host remains responsible for the workspace contents and system or managed Codex settings. Read-only filesystem policy does not disable network or external tools. No request is resumed or retried.

Set `CodexCLI.AllowSavedHomeExtensions` to the Boolean `true` in the trusted jacket to allow an existing Saved `CodexHome` containing `hooks.json` or populated `plugins`. The default is `false`; the flag cannot be set in a plan. This option leaves the home unchanged and may let home extensions affect CLI execution.

The execution Signal records the CLI's captured JSONL stdout and stderr. JSONL `error` and `turn.failed` events are Critical; other JSONL events are Information. Stderr is Critical when execution fails and Information otherwise. A nonzero exit code is also recorded as Critical. These entries can contain prompt or response content and are available to Signal consumers. Capture remains subject to `MaxStderrBytes` and `MaxEventBytes`.

## Plan input and compatibility

`SendMessage` accepts `Config.Prompt` as a nonblank scalar, or an object with optional `System`, ordered string `Texts`, and `Media`. Nonblank `System` is labeled and joined with text items using two newlines. If `Prompt` is absent, nonblank `Config.Content` is a legacy fallback; both together fail. Blank optional fields are omitted. A valid image-only request sends `Respond to the attached image(s).` as the prompt. `Config.ModelKey` selects a configured profile; an omitted key selects `DefaultModelKey`, while an unknown key fails. `Config.Model` is unsupported. `Config.OutputSchema` supports a flat closed draft 2020-12 object schema with scalar property types, all properties listed exactly once in `required`, and no other keywords. `Config.Break` may be null or false. Other nonempty Config options, including sampling or token controls, fail.

Media entries accept exactly one `MediaPath` or `MediaUrl`, optional blank or `image` `MediaType`, and blank `Detail`. Blank path/URL placeholders are ignored. Local regular files must be inside an allowed root without path links, including junctions in ancestor directories. HTTPS URLs must match `AllowedImageHosts`; the downloader rejects credentials, redirects, proxies, nonpublic destinations, missing or mismatched MIME, oversize bodies, and unsupported signatures. One download deadline covers DNS, connection, TLS, headers, and body. PNG, JPEG, GIF, and WebP are supported. Downloads and local files are copied into a unique adapter-owned invocation directory, which is removed on success and failure. Video, audio, and image detail controls are unsupported.

The CLI receives one flattened text prompt, so a `System` section does not carry hosted chat system-role authority. Codex tools, workspace, and managed configuration can affect the answer. Provider/model output is not identical to AzureFoundry. AzureFoundry and CodexCLI resolve `Config.ModelKey` within their mapped jackets. Neither authentication nor model availability is inferred from a plan. A successful offline fixture proves process transport and consumer shape, not an authenticated model response.

## Checks

From the SovereignTrust.Adapters root, run `pwsh -NoProfile -File Src/Intelligence/CodexCLI/Tests/Run-CodexCLIChecks.ps1`. It builds a harmless .NET child fixture, checks actual OS transport and process-tree termination, bounded output and deadline behavior, JSONL/final separation, schema validation, local and HTTPS image handling, production loader/deferred hydration, both mapped routes, and named unchanged consumer steps with synthetic hydrated input. The fixture requires a local .NET SDK. Generated fixture build files are ignored.

Live checks are opt-in: set `CODEXCLI_LIVE_READY=1`, `CODEXCLI_LIVE_EXECUTABLE`, `CODEXCLI_LIVE_WORKSPACE`, `CODEXCLI_LIVE_MODEL`, and `CODEXCLI_LIVE_AUTH_MODE` (`Saved` with `CODEXCLI_LIVE_CODEX_HOME`, or `ApiKey` with `CODEXCLI_LIVE_API_KEY`), then run `pwsh -NoProfile -File Src/Intelligence/CodexCLI/Tests/Run-CodexCLILiveIntegration.ps1`. Exit 77 means prerequisites were skipped. The live script checks text and a small structured response; it makes no media claim.
