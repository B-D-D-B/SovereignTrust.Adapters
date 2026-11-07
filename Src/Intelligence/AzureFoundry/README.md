# Intelligence.AzureFoundry

The `Intelligence_AzureFoundry` module supports `SendMessage` and `HandleMessage` with legacy `OpenAIResponses` and v2 registered Responses, OpenAI Images generation/edit, and BlackForestLabs FLUX.2 pro/flex routes. `SendMessageOriginal` is unsupported and fails before transport. Each constructed slot keeps its own route, credential, and profiles.

```json
{
  "Name": "Foundry",
  "VirtualPath": "SovereignTrust.Adapters.Intelligence.AzureFoundry.Foundry.Persistent.Run",
  "IsMapped": true,
  "ApiKind": "OpenAIResponses",
  "AuthenticationMode": "ApiKey",
  "DefaultModelKey": "Worker-Medium",
  "Profiles": [
    { "ModelKey": "Worker-Medium", "Model": "YOUR_DEPLOYMENT_NAME", "ReasoningEffort": "medium" }
  ],
  "Resource": ["[Storage.Secrets.Read.foundry-key|]"],
  "Addresses": ["https://YOUR_RESOURCE.openai.azure.com/openai/v1/responses"]
}
```

`AuthenticationMode` is `ApiKey` by default and sends `Resource` through the `api-key` header. `Entra` sends it as an Authorization bearer token. The jacket must have exactly one address and one hydrated credential. Profiles must have unique, case-sensitive keys. The `Model` value is the Foundry deployment name. The adapter validates the profile shape but the service determines whether a deployment supports the selected reasoning effort.

Profiles may include a positive integer `MaxInputTokens` for planning metadata, such as `272000`. The adapter does not send it as an API parameter or use it to truncate input; verify the value against the deployment before setting it.

`SendMessage` accepts `Config.ModelKey` and `Config.Prompt.System`, `Config.Prompt.Texts`, and `Config.Prompt.Media`. Omitting `ModelKey` uses `DefaultModelKey`; an unknown key fails before the HTTP call. The adapter sends `input`, `model`, `reasoning.effort`, and `max_output_tokens` to Responses. It extracts assistant text from `output` and returns the existing JSON `choices[0].message.content` shape for consuming plans. `Config.Model` is unsupported.

Run `pwsh -NoProfile -File Tests/FoundryProfiles.Tests.ps1` from the adapters repository root for offline contract checks. A live call additionally requires a deployed model, a hydrated credential, and an enabled Foundry slot.

For v2, a trusted jacket registers `SchemaVersion: 2`, keyed `Resource` credentials, keyed `Routes` with `ApiKind`, HTTPS `Address`, `ResourceKey` and `AuthMode`, and keyed `Profiles` with `IsDefault`, `RouteKey` and `Model`. `OpenAIImageGeneration` and `OpenAIImageEdit` use `ApiKey` in the `api-key` header; `BlackForestLabsFlux2` uses `BearerApiKey` in the bearer Authorization header. `SendMessage` with `Config.Profile: {Key}` selects an image profile. Its only other Config member is the final provider-native object `Prompt`, whose `model` must match the selected profile. Native options and references pass through; `stream:false` is accepted and other stream values fail. The adapter preflights REST-equivalent depth-100 JSON and a 1 MiB UTF-8 request limit, then forwards the parsed `Condenser.Rest` response value. This offline path makes no claim about image correctness or live REST retry, deadline or response bounds.

For v2 Responses text, `Config.ModelKey` or the registered default selects a Responses profile and keeps the normalized `choices` JSON result. The existing structured prompt and legacy `HandleMessage` behavior remain available. Run `pwsh -NoProfile -File Tests/FoundryImageSend.Tests.ps1` for the offline image dispatch checks.
