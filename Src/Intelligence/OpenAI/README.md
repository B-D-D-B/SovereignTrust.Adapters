# Intelligence.OpenAI

`Intelligence_OpenAI` calls the native OpenAI Responses endpoint. Each mapped slot has one hydrated API key in `Resource`, one `Addresses` value (`https://api.openai.com/v1/responses`), and named model profiles. The key is sent using `Authorization: Bearer`; the `Model` is a native OpenAI model ID, not an Azure deployment name. This adapter does not use CodexCLI or Azure Foundry authentication.

```json
{
  "Name": "OpenAI",
  "VirtualPath": "SovereignTrust.Adapters.Intelligence.OpenAI.OpenAI.Persistent.Run",
  "IsMapped": true,
  "ApiKind": "OpenAIResponses",
  "DefaultModelKey": "Worker-Medium",
  "Profiles": [{ "ModelKey": "Worker-Medium", "Model": "YOUR_OPENAI_MODEL_ID", "ReasoningEffort": "medium", "MaxOutputTokens": 512 }],
  "Resource": ["[Storage.Secrets.Read.your-openai-key|]"],
  "Addresses": ["https://api.openai.com/v1/responses"]
}
```

`Config.ModelKey` selects a profile; omitted selection uses the default. `ReasoningEffort` and `MaxOutputTokens` are optional and sent only when set. Check model support for reasoning, image detail and output budget before a live call. `Config.Model` is rejected. `SendMessage` returns a JSON string containing `choices[0].message.content`; `HandleMessage` selects by `Path` and optionally runs `Format`. `SendMessageOriginal` is unsupported and fails before transport.

Use `Config.Prompt.System`, ordered `Texts` and `Media` entries. Each image entry uses `MediaType: image`, exactly one `MediaPath` or HTTPS `MediaUrl`, and optional `Detail` (`auto`, `low`, `high`). Local JPEG, PNG, WebP and static GIF files are converted to data URLs. Local files are limited to 10 MiB each, ten images per request, and 20 MiB for the serialized request. Remote image bytes are validated by the provider. `Config.Content` is accepted only when structured `Prompt` is absent. Legacy top-level media fields are rejected. The adapter sends one nonstreaming POST without retries or redirects. Failures return a failed Signal without a result and without provider body or key in diagnostics.

Run offline checks from the adapters repository root: `pwsh -NoProfile -File Tests/OpenAIResponses.Tests.ps1`. A live call requires a hydrated key, supported model and account access; offline checks do not establish live service acceptance.
