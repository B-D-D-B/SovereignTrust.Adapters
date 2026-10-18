# Intelligence.AzureFoundry

The `Intelligence_AzureFoundry` module currently implements the `OpenAIResponses` API kind. It can be installed in multiple mapped slots; each slot has its own endpoint, credential, and model profiles. Other API kinds are rejected until their request handlers are implemented.

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
