# Data.AzureSql

The intended plan route is `Data.FusionDatabase -> MappedDataAdapter -> FusionDatabase -> Data_AzureSql`. The configured virtual path is `SovereignTrust.Adapters.Data.AzureSql.FusionDatabase.Persistent.Full`.

## Application mapping and plan examples

`SDAFusion-Content/SDA/Config/SDAFusionApp.Json` registers one `SDAFusionDatabase` jacket under `Agents[Name=sdadev01].Roles.SDAWorkItems.Adapters`. Its `IsMapped=true` virtual path registers the `FusionDatabase` slot. The production loader hydrates the jacket before calling `Data_AzureSql.Construct`. The current passwordless jacket uses `Resource=sda-fusion` as the database and `Addresses=[sda-dev.database.windows.net]` as the SQL server. Plans call `Data.FusionDatabase` directly. These examples are templates: `example.*` procedure/table names, IDs, and document fields are **placeholders** to replace with reviewed schema names and application values. They contain no operational credentials.

JSON records supplied as text (the adapter also accepts an already structured object with `InputFormat: "Object"`):

```json
{
  "Adapter": "Data.FusionDatabase", "Activity": "Write",
  "Config": {
    "Procedure": "example.usp_IngestRecords", "PayloadParameter": "@Payload",
    "InputFormat": "Json", "PayloadMode": "Records",
    "Content": "[{\"Id\":1,\"Name\":\"Example\"}]",
    "ColumnSchema": { "Id": "int" }, "CommandTimeoutSeconds": 45,
    "Parameters": []
  }
}
```

CSV records use `PayloadMode: "Records"`; a one-character `Delimiter` may be supplied. Quoted fields and embedded newlines are supported.

```json
{
  "Adapter": "Data.FusionDatabase", "Activity": "Write",
  "Config": {
    "Procedure": "example.usp_IngestRecords",
    "InputFormat": "Csv", "PayloadMode": "Records",
    "Content": "Id,Name\n2,\"Example, Gallery\"",
    "ColumnSchema": { "Id": "int" }, "CommandTimeoutSeconds": 45
  }
}
```

Nested document input uses `Document` mode. The example passes a structured object. To use an `ItemSignal` payload instead, replace `Content` with `"ContentPath": "@.Payload"`; that is a signal path, not a file path. Supply exactly one of `Content` or `ContentPath`.

```json
{
  "Adapter": "Data.FusionDatabase", "Activity": "Write",
  "Config": {
    "Procedure": "example.usp_IngestDocument",
    "InputFormat": "Object", "PayloadMode": "Document",
    "Content": { "Metadata": { "Name": "Example", "Version": 1 },
      "Items": [{ "Id": 1 }] },
    "CommandTimeoutSeconds": 60
  }
}
```

Query and Delete use separate typed parameters; the adapter never substitutes values into SQL text. Specify `Size`, `Precision`, `Scale`, and `Direction` when needed. `CommandTimeoutSeconds` overrides the jacket default of 30 seconds.

```json
{
  "Adapter": "Data.FusionDatabase", "Activity": "Query",
  "Config": {
    "CommandText": "SELECT Id, Name FROM example.Records WHERE Id = @Id",
    "Parameters": [{ "Name": "@Id", "SqlDbType": "Int", "Value": 1 }],
    "CommandTimeoutSeconds": 15
  }
}
```

```json
{
  "Adapter": "Data.FusionDatabase", "Activity": "Delete",
  "Config": {
    "CommandText": "DELETE FROM example.Records WHERE Id = @Id",
    "Parameters": [{ "Name": "@Id", "SqlDbType": "Int", "Value": 1 }],
    "CommandTimeoutSeconds": 15
  }
}
```

Successful calls return JSON text through `Signal.SetResult()`. This envelope illustrates an empty Query result; `Columns` remains populated when the reader reports schema:

```json
{
  "Operation": "Query", "RowsAffected": null, "OutputParameters": {},
  "ResultSets": [{
    "Name": "Table",
    "Columns": [{ "Name": "Id", "SourceName": "Id", "Type": "int", "Ordinal": 0,
      "AllowDBNull": false, "Precision": null, "Scale": null }],
    "Rows": []
  }]
}
```

Write and Delete use adapter-managed transactions by default. Only a reviewed Write stored procedure that cannot participate in one may set `"TransactionMode": "None"` in `Config`; it then owns its atomicity and failure recovery. Query and Delete do not accept that override.

The provisional in-memory implementation and `Condenser.Data` route have been removed. The adapter retains its constructed jacket. Secure connection construction, typed SQL parameter creation, and Write, Query, and Delete command execution are implemented.

## Gated live integration suite

Run `pwsh -NoProfile -File Src/Data/AzureSql/Tests/Launch-AzureSqlLiveIntegration.ps1` from the adapter repository root. The launcher temporarily exposes the sibling SignalGraph checkout as a module, starts `Run-AzureSqlLiveIntegration.ps1` in a fresh `pwsh -NoProfile` child, restores `PSModulePath`, and propagates the child's exit code. The child selects `sdadev01` / `SDAWorkItems` from the real `SDAFusionApp.Json`, bootstraps ModuleRoots and Secrets, registers the SQL jacket lazily through Fab, and invokes `Data.FusionDatabase` with the genuine SqlClient session factory. A missing prerequisite returns exit code 77 and prints `SKIP` without reading a protected resource.

First set `SDA_AZURESQL_LIVE_SERVER` and `SDA_AZURESQL_LIVE_DATABASE` to the **approved** integration target. Run `pwsh -NoProfile -File Src/Data/AzureSql/Tests/Launch-AzureSqlLiveIntegration.ps1 -TargetProbe` before setting live readiness flags. This read-only probe resolves the real jacket through production hydration and lazy loading, authenticates with SqlClient, and verifies both connection-builder target fields and `DB_NAME()`. Those environment variables only validate the target; they never redirect it.

The dedicated `test_sda_azure_sql_it_adapter` objects are defined in `Tests/Provision-AzureSqlLiveFixture.template.sql`. The one-time `pwsh -NoProfile -File Src/Data/AzureSql/Tests/Provision-AzureSqlLiveFixture.ps1` provisioning command checks the exact configured target and creates only that schema, table, index, and procedure in one SQL transaction. Run it with a provisioning identity, never with the restricted live-suite identity. On 2026-09-24 the objects were created in `sda-fusion`; rerunning the provisioner intentionally fails if the schema already exists.

Before any live mutation, the fixture guard must compare the current ingestion procedure to the reviewed template, including its two fixture-only `INSERT` targets and `@RunId` use. The preferred path is object-scoped `VIEW DEFINITION` on `[test_sda_azure_sql_it_adapter].[usp_IngestAzureSqlAdapterFixture]` for the restricted test identity. If that grant is unavailable, a provisioning owner with definition access can run `Provision-AzureSqlLiveFixture.ps1 -CaptureEvidence -EvidencePath <new-json-path> -ReviewedBy <owner-name>`; this read-only mode compares the current definition, then records its hash, SQL login, object ID, and object dates. Set `SDA_AZURESQL_LIVE_FIXTURE_EVIDENCE` to that JSON path for the probe and suite. Evidence for a different object or missing evidence causes exit 77 before mutation. Object dates alone are never proof of review.

Set `SDA_AZURESQL_LIVE_SCHEMA=test_sda_azure_sql_it_adapter`, then run `pwsh -NoProfile -File Src/Data/AzureSql/Tests/Launch-AzureSqlLiveIntegration.ps1 -FixtureProbe`. This read-only preflight checks the fixture definition or applicable owner evidence, shape, triggers, and visible permissions without readiness flags or mutation. Enable mutation only after the database/schema is approved for isolated integration use and the test identity's grants are reviewed. The current direct passwordless jacket does not use Key Vault; a protected-resource deployment additionally requires Key Vault access. Set `SDA_AZURESQL_LIVE_READY=1`, `SDA_AZURESQL_LIVE_DEDICATED=1`, `SDA_AZURESQL_LIVE_NETWORK_READY=1`, `SDA_AZURESQL_LIVE_IDENTITY_READY=1`, and `SDA_AZURESQL_LIVE_FIXTURES_READY=1` only after those checks. The identity needs SELECT and DELETE on the fixture table, EXECUTE on the ingestion procedure, and no DDL or unrelated table write rights. The suite never creates or drops SQL objects.

Provision only these fixture objects in that schema before enabling the gate:

- `AzureSqlAdapterFixture` table with `RunId uniqueidentifier NOT NULL`, `Id int NULL`, `Name nvarchar(max) NULL`, `Kind nvarchar(16) NOT NULL`, and `Document nvarchar(max) NULL`.
- `usp_IngestAzureSqlAdapterFixture` stored procedure taking `@Payload nvarchar(max)`, `@RunId uniqueidentifier`, and `@Kind nvarchar(16)`. For `Records`, it inserts each `OPENJSON(@Payload)` row with `Id` and `Name`, retaining empty strings and embedded newlines. For `Document`, it inserts one row with `Kind='Document'` and the unmodified JSON document in `Document`.

`Tests/Provision-AzureSqlLiveFixture.template.sql` is a guarded, unexecuted provisioning-owner template for a new dedicated schema. Existing objects require inspection and reuse rather than replacement. The test identity must not run the provisioning script.

The provisioning owner must inspect the procedure body and related triggers before enabling the fixture flag. The suite checks column and parameter types, procedure definition visibility, the use of `OPENJSON` and `@RunId`, dependencies, absence of table triggers, effective fixture grants, broad database roles, and visible unrelated table write grants. These machine checks do not replace the owner's review, including objects hidden by catalog permissions. The ingestion procedure must retain the supplied `RunId`; the live row assertions verify this behavior.

The suite uses a new GUID `RunId` for every run and limits reads, deletes, rollback checks, and cleanup to that value. It prints only that non-secret ID, a hash of the packaged `PowerShell/` artifact, and a recovery-record path. The record under the host's temporary `SovereignTrust.AzureSql.LiveRuns` folder retains stage, failure class, cleanup outcome, artifact/config hashes, and runtime version. After scoped cleanup, the suite queries the row count and reports success only when it is zero. A scenario failure remains the primary failure if cleanup also fails. After interruption, use the recorded ID in a parameterized `SELECT COUNT(*) FROM [dedicated-schema].[AzureSqlAdapterFixture] WHERE RunId=@RunId`; inspect the result before any ID-scoped recovery delete. There is no broad fixture reset. Exit 77 means not run, another nonzero exit means failed, and exit 0 after cleanup verification is live evidence.

For the Prompt G offline configuration, hydration handoff, mapped routing, and connection/parameter checks, run `pwsh -NoProfile -File Src/Data/AzureSql/Tests/Run-PromptGChecks.ps1` from the repository root. The runner packages pinned dependencies if needed, gives the sibling SignalGraph checkout a temporary module-discovery path, and runs each check in its own PowerShell process. The hydration test substitutes a synthetic value at Foundation's deferred hydration boundary; it does not contact Key Vault or SQL. Prompt H separately tests production lazy module loading and the gated live database path.

## SqlClient package and deployment

`Packaging/SqlClientRuntime.csproj` pins `Microsoft.Data.SqlClient` **6.1.7**. `Packaging/packages.lock.json` locks all transitive packages for `net8.0/win-x64`. This uses the 6.1 LTS line, which includes the Azure Identity dependencies needed for the planned Active Directory authentication modes. The declared module artifact target is **Windows x64, PowerShell 7.4 or later on .NET 8 or later**. The user-designated deployment host was validated with the packaged artifact on PowerShell **7.6.6** and .NET 10.0.12 through separate fresh-process explicit-import and production lazy-resolution checks. PowerShell 7.4 compatibility remains unverified.

From the repository root, run `pwsh -NoProfile -File Src/Data/AzureSql/Package-AzureSql.ps1`. The script restores in locked mode with the repository NuGet source configuration, publishes a framework-dependent win-x64 .NET 8 host, and copies its complete publish output into `Src/Data/AzureSql/PowerShell/dependencies/`. NuGet access is needed at package time when the locked packages are not cached. Copy the **whole** `PowerShell/` directory as the module artifact, including the manifest, scripts, `dependencies/inventory.json`, all managed DLLs, native `Microsoft.Data.SqlClient.SNI.dll` and `msalruntime.dll`, satellite folders, and the publish `.deps.json` and runtime config. Do not select individual DLLs from the publish output. The .NET runtime and PowerShell are supplied by the target host.

`Data_AzureSql.psm1` checks the package inventory and platform, registers a resolver for packaged managed assemblies, and loads SqlClient before the class definition. Module import never invokes NuGet or downloads dependencies. Missing package files fail import with a named-file error. The package directory is generated and ignored by Git; deploy it as part of the built module artifact. To verify packaging and isolated failure behavior, run `pwsh -NoProfile -File Src/Data/AzureSql/Tests/Test-AzureSqlPackage.ps1` after packaging.

## Internal execution boundary

`Data_AzureSql.Invoke` performs activity and `Plan.Config` validation and Write normalization, then calls the private `Invoke-AzureSqlExecution` orchestrator. That function creates one session via private `New-AzureSqlSession`, dispatches to `Invoke-AzureSqlWrite`, `Invoke-AzureSqlQuery`, or `Invoke-AzureSqlDelete`, and disposes the session in `finally`. The production factory parses the hydrated jacket `Resource` with `SqlConnectionStringBuilder`, opens a new `SqlConnection`, and disposes it on open failure. Each operation disposes its command. Reader operations traverse and dispose the reader before reading output parameters.

Tests replace `New-AzureSqlSession` **inside module scope** with a connection double. The connection double provides `CreateCommand` and `Dispose`; its command double provides a parameter collection, `ExecuteReader`, `ExecuteNonQuery`, and `Dispose`; reader doubles provide `Read`, `NextResult`, schema/column/value access, and `Dispose`. `Data_AzureSql.ExecutionBoundary.Tests.ps1` exercises the real Write, Query, and Delete helpers through this factory. No factory or double is exported or accepted through adapter configuration.

## Write input contract

`Plan.Config` requires a nonblank `Procedure` and exactly one **present member** of `Content` or `ContentPath`. Null `Content` still counts as present, so pairing it with `ContentPath` is ambiguous. `ContentPath` is a nonblank path resolved against `ItemSignal` with `Resolve-PathFromDictionary`, such as `@.Payload`; it does not refer to a file. Missing paths and resolver failures produce a failed signal.

`InputFormat` defaults to `Object` and accepts `Object`, `Json`, or `Csv`. Object uses the selected value directly. Json parses string content as JSON and accepts already structured values. Csv requires text and uses `ConvertFrom-Csv`, retaining quoted fields, empty fields, and embedded newlines. `Delimiter` defaults to comma and, if specified, must be a single character.

`PayloadMode` defaults to `Records` and accepts `Records` or `Document`. Records requires an array or one row of dictionary or `PSCustomObject` values and always produces a top-level JSON array, including for zero or one row. Null and scalar records fail. Document serializes the selected value as one JSON document, including empty and one-element top-level arrays. CSV supports Records only.

Records may specify `ColumnSchema` as a dictionary (`@{ Id = 'int' }`) or Name/Type descriptors (`@(@{ Name = 'Id'; Type = 'int' })`). Matching columns are converted on fresh payload rows; unlisted columns and null values are retained. Supported names are `string/nvarchar/varchar/text` (string), `int/int32` (Int32), `long/int64/bigint` (Int64), `decimal/numeric` (Decimal), `double/float` (Double), `bool/boolean/bit` (Boolean, including `0` and `1`), and `date/datetime/datetime2/datetimeoffset` (DateTimeOffset). Numeric and date parsing uses invariant culture. Unsupported types and failed conversions produce a failed signal.

Normalization keeps JSON and format information local to the invocation. It neither rewrites nor clones the caller plan, and it does not serialize or coerce unrelated `Config.Parameters` values. Write binds this local JSON as `NVarChar(MAX)` to `Config.PayloadParameter` or `@Payload`.

## Operation execution

Write calls `Config.Procedure` as a stored procedure. Query and Delete use `Config.CommandText` as text with separate typed parameters. Reader operations preserve each result set, including empty sets and schema metadata, and capture output and return-value parameters after closing the reader. Delete uses `ExecuteNonQuery` unless `Config.ExpectResultSets` is true. Provider affected count `-1` is serialized as JSON null; zero remains zero. `Config.CommandTimeoutSeconds` overrides the jacket-level value, with a 30-second default. Values must be integral seconds from 1 through 86400. Write and Delete are each executed once, without automatic retry.

Reader results assign one JSON key to each column by ordinal, even when SQL returns duplicate or unnamed columns. `Columns[].SourceName` contains the exact provider name; `Columns[].Name` and row keys contain the assigned JSON name. The first nonblank occurrence keeps its source name. Matching is case insensitive, while the original case is retained: `Id`, `Id` becomes `Id`, `Id_2`; `Id`, `id` becomes `Id`, `id_2`. Blank or whitespace-only names use `Column` plus the one-based ordinal, such as `Column1`. Generated names append `_2`, `_3`, and so on until unique. All nonblank source names are reserved before assignment, so `Id`, `Id`, `Id_2` becomes `Id`, `Id_3`, `Id_2`, and an unnamed first column followed by source `Column1` becomes `Column1_2`, `Column1`. The mapping is computed separately for each result set and is the same whether or not it contains rows. Ordinal, type, nullability, precision, and scale metadata remain with each column.

Write and Delete open one connection and enlist their command in an explicit transaction by default. The adapter closes readers, captures output and return parameters, serializes and validates the complete JSON envelope, and only then commits. Execution, conversion, serialization, and precommit cleanup failures attempt rollback. A failed commit has an uncertain outcome; its failed signal says so, even if rollback also fails. A cleanup failure after a successful commit produces a failed signal that explicitly says the operation committed. Provider exception details and parameter values are never copied into those signals. Query opens a connection without an explicit transaction.

Only a Write stored procedure that cannot participate in an adapter-managed transaction may set `Config.TransactionMode` to `None`. This is an explicit opt-out of rollback guarantees; the procedure owns its own atomicity and failure recovery. Omit the property for the transactional default. `None` is rejected for Delete and any `TransactionMode` setting is rejected for Query. Use this exception only for a procedure whose transaction behavior has been reviewed; it does not change retries or parameter handling.

The shared result converter retains column metadata for empty result sets and converts row values, output parameters, and return values to JSON-safe types. Nulls remain null, bytes become base64, GUIDs use lowercase canonical form, dates and times use invariant ISO-8601, decimals preserve their SQL or .NET precision and scale as strings, and integers beyond the JavaScript safe range become strings. Safe integers and floating-point values remain JSON numbers. Unsupported provider objects fail conversion before commit.

Decimal/numeric reader columns use SqlClient's `GetSqlDecimal`; decimal-valued `sql_variant` cells use `GetSqlValue`. Decimal output and input/output parameters use `SqlParameter.get_SqlValue()`, which retains SQL precision up to 38 digits. Method calls propagate retrieval errors into the rollback path; a failed getter is never treated as SQL null. Ordinary return codes and other output types use `get_Value()`. The offline decimal regression uses the pinned provider's output buffer to cover values that overflow CLR `Decimal`; it is provider-behavior evidence, not a live database test. Arbitrary-precision decimal **inputs** remain outside the current parameter contract.

The exported converter's DataTable and DataRow compatibility paths include column name, source name, inferred type, DataColumn ordinal and nullability, with null precision and scale when unavailable. Plain-object collections retain their inferred types and deterministic ordinals, with null for unavailable nullability, precision, and scale. An empty collection without a table or schema has no recoverable columns.

## Connection resource contract

The current jacket has a plain database name in `Resource` and one Azure SQL hostname in `Addresses`. The adapter builds an encrypted `Active Directory Default` connection without a password. A protected connection-string `Resource` remains supported as an alternate mode; it must specify `Server`/`Data Source`, `Database`/`Initial Catalog`, and either `Authentication=Active Directory Default` or `Authentication=Active Directory Managed Identity`. Managed Identity may include `User ID=<user-assigned identity client ID>`. In this alternate mode, `Addresses` is not used as the SQL endpoint. SQL password, service principal, integrated security, and connection strings without an explicit supported authentication mode are not supported in this phase.

The adapter rejects `Encrypt=False`/`Optional`, `Trust Server Certificate=True`, passwords, and connection timeouts outside 1–300 seconds. It enforces encryption and certificate validation, sets `Application Name=SovereignTrust.Adapters.Data.AzureSql`, disables persisted security information, and uses the resource's `Connect Timeout` or SqlClient's 15-second default. There is no insecure development override. Connection and provider failures enter a failed signal with a generic message so secret values do not appear in logs or errors.

## Parameter contract

`Plan.Config.Parameters` canonically contains descriptors with `Name` (an `@`-prefixed identifier), `SqlDbType`, optional `Size`, `Precision`, `Scale`, `Direction`, and `Value`. `Direction` defaults to `Input`; supported directions are `Input`, `Output`, `InputOutput`, and `ReturnValue`. Input and input/output require a present `Value`; explicit null becomes `DBNull.Value`. Character and binary output parameters require `Size`. `Size=-1` is limited to `NVarChar`, `VarChar`, and `VarBinary`. `Structured`, `Udt`, and `Variant` types are unsupported. Binary descriptors accept a `byte[]` or base64 text; other supported types use invariant scalar conversions. Conversion failures reject the descriptor without publishing the value.

A dictionary such as `@{ '@Id' = 1 }` remains as a compatibility input. It infers types only from supported nonnull .NET scalar values (string, Boolean, byte, Int16/32/64, Decimal, Single/Double, Guid, DateTime/DateTimeOffset, TimeSpan, and byte array). Nulls, objects, arrays other than `byte[]`, output directions, and explicit database metadata require descriptors. Inferred string size and decimal precision/scale are left to SqlClient, so use descriptors when those details matter. The helper creates `SqlParameter` objects and adds them to a command; it never interpolates values into command text or procedure names.
