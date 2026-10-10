# Azure SQL Data Adapter Implementation Plan

## Objective

Implement a production `Data.AzureSql` adapter that follows the module, construction, invocation, configuration, and signal conventions used by `SovereignTrust.Adapters/Src/Storage/AzureStorageAccount`.

The completed route is:

```text
Plan / MemoryCondenser
  -> Data.FusionDatabase                   [Data.<Slot>]
  -> MappedDataAdapter                     [SovereignTrust.Foundation]
  -> FusionDatabase slot
  -> SovereignTrust.Adapters.Data.AzureSql [adapter implementation]
  -> JSON result in Signal
```

The adapter will execute real Azure SQL commands. The mock implementation, in-memory state, mock handlers, fixture matching, reset behavior, invocation recording, and injected failures are not part of the target design.

## 1. Use the mapped Data slot directly

Plans invoke the adapter with `Adapter: Data.FusionDatabase`, following the standard `Kind.Slot` convention. The generic mapped-adapter infrastructure resolves `Data` to `MappedDataAdapter` and `FusionDatabase` to the registered slot implementation.

The virtual path separates the implementation from the slot:

```text
SovereignTrust.Adapters.Data.AzureSql.FusionDatabase.Persistent.Full
|-------------------------------------| |------------| |--------| |--|
             adapter path                  slot         nature   access
```

- `SovereignTrust.Adapters.Data.AzureSql` identifies the adapter module and type.
- `FusionDatabase` is the mapped slot name used by plans.
- `Persistent` is the configured nature.
- `Full` is the configured access.

There is no `Condenser.Data`, `DataCondenser`, or `Config.DataAdapter` hop in this design.

Foundation remains responsible only for generic mapped-adapter routing and signal propagation. Foundation must not contain:

- Azure SQL connection or command implementation.
- `Microsoft.Data.SqlClient` dependencies.
- SQL parameter construction.
- Database-result conversion.
- Azure SQL authentication logic.
- Azure SQL input normalization.

`Data_AzureSql` is responsible for:

- Validating `Write`, `Query`, and `Delete` plans.
- Resolving exactly one of `Content` or `ContentPath` for Write.
- Normalizing JSON, PowerShell objects, and CSV input for stored-procedure ingestion.
- Preserving `Int32`, `Int64`, `Decimal`, `Guid`, `DateTime`, `byte[]`, nulls, dictionaries, and arrays in SQL parameters.
- Preserving empty and one-element top-level arrays in document mode.
- Leave the original plan and input unchanged on success and failure.

The adapter should treat the incoming plan as immutable and prepare local command values rather than rewriting or cloning the plan. If the provisional `DataCondenser` was introduced solely for AzureSql, remove its registration, helpers, and dedicated tests after confirming that no independent consumer uses it.

Before removing those helpers and tests, record their reusable normalization contracts and test cases in a migration checklist in this plan. Preserve the input/output examples and assertions needed for AzureSql-owned coverage; do not preserve obsolete condenser routing or plan-cloning behavior.

The Write normalization contract carries forward these input conventions:

- Resolve `Config.ContentPath` against `ItemSignal` using `Resolve-PathFromDictionary`, for example `@.Payload`. It is a signal/dictionary path, not a filesystem path. Propagate resolution failures through a failed signal.
- Determine whether `Content` or `ContentPath` is supplied by member presence; reject both or neither, then validate the selected value.
- Support `InputFormat` values `Object`, `Json`, and `Csv`, defaulting to `Object` when omitted.
- Support `PayloadMode` values `Records` and `Document`, defaulting to `Records` when omitted. Reject unsupported values; CSV supports only `Records`.
- Retain CSV `Delimiter` support with a comma default and exactly one character when specified.
- Retain the existing optional `ColumnSchema` contract for Records, including its dictionary and Name/Type descriptor forms and supported conversions. Apply conversions to newly prepared payload rows without mutating caller values. Document and test the supported types and invalid-conversion failures.

## 2. Refactor AzureSql into a production adapter

### Prompt B migration checklist (captured before provisional cleanup)

Source contracts: `SovereignTrust.Foundation/Src/PowerShell/Utilities/Adapters/Condenser/Data/Test-DataCondenserPlan.ps1`, `Resolve-DataCondenserPayload.ps1`, and `SovereignTrust.Foundation/Tests/DataCondenser.Tests.ps1`. These files were provisional AzureSql-only code. Reimplement the following in AzureSql-owned normalization and tests; do not restore `Condenser.Data`, `Config.DataAdapter`, cloned plans, or pre-normalized `Config.Content` mutation.

- [ ] Accept exactly one **member** of `Config.Content` and `Config.ContentPath`; both or neither fail, even when a member has a null value. Reject empty `ContentPath`. Resolve a path such as `@.Payload` against `ItemSignal` with `Resolve-PathFromDictionary -Dictionary $ItemSignal -Path $contentPath`. Merge resolution failures into the operation signal and fail when no result is returned. Treat the path as a signal/dictionary path.
- [ ] Require `Plan.Config`; Write requires nonblank `Procedure`; Query and Delete require nonblank `CommandText`. Reject unsupported activities. These validations belong to `Data_AzureSql` and must not require `Config.DataAdapter`.
- [ ] `InputFormat` accepts `Object`, `Json`, `Csv`, default `Object`. `Object` uses the selected content directly. `Json` parses string content with `ConvertFrom-Json -Depth 100` and uses nonstring content directly; malformed JSON fails. `Csv` requires text, parses with `ConvertFrom-Csv`, and supports only `PayloadMode=Records`.
- [ ] `PayloadMode` accepts `Records` and `Document`, default `Records`; reject other values. Records reject null payload, require each row to be a dictionary or `PSCustomObject`, and serialize a top-level JSON array, including zero or one record. Document serializes the selected value as one JSON document and must preserve nested objects and empty or one-element top-level arrays.
- [ ] CSV `Delimiter` defaults to comma and, when supplied, must contain exactly one character. Preserve quoted fields, empty values, and embedded newlines. For example `Id,Name` plus `2,"Gallery\r\nArchive"` yields one row with `Id="2"` before schema conversion and `Name="Gallery\r\nArchive"`. A semicolon delimiter should parse `Id;Name` when configured.
- [ ] Optional Records `ColumnSchema` accepts a dictionary such as `@{ Id = 'int' }` or descriptors such as `@(@{ Name = 'Id'; Type = 'int' })`. Apply matching column conversions to fresh output rows, leaving caller rows untouched; retain unlisted columns and null values. Supported aliases: `string/nvarchar/varchar/text` to string; `int/int32` to Int32; `long/int64/bigint` to Int64; `decimal/numeric` to Decimal; `double/float` to Double; `bool/boolean/bit` to Boolean; `date/datetime/datetime2/datetimeoffset` to DateTimeOffset. Parse numeric and date values with invariant culture. Unknown types, invalid values, and nonobject Records entries fail.
- [ ] Preserve these test fixtures/assertions from `DataCondenser.Tests.ps1`: Object Records `@([pscustomobject]@{Id='1';Name='Museum'})` with `ColumnSchema=@{Id='int'}` yields `[{'Id':1,'Name':'Museum'}]`, with converted `Id` numeric; CSV with a quoted embedded newline preserves that newline and converts `Id` to 2; `ItemSignal` result `{Payload:{Metadata:{Name:'WeatherVault';Version:1}}}` with `ContentPath='@.Payload'`, Object/Document yields nested `Metadata.Name='WeatherVault'`; both Content and ContentPath fail; malformed JSON fails. Add empty and single-element Document array assertions and invalid delimiter/schema conversion assertions. Compare caller plan and input before/after both success and failure; local normalized JSON must never be written into them.
- [ ] Preserve unrelated query/delete contract assertions at the adapter boundary: parameters and `CommandTimeoutSeconds` reach execution unchanged, successful JSON result is forwarded unchanged, and downstream failure becomes a failed signal. Replace the prior condenser-routing assertion with direct `Data.FusionDatabase` mapped routing.

Keep the adapter under:

```text
SovereignTrust.Adapters/Src/Data/AzureSql/
  PowerShell/
    Data_AzureSql.ps1
    Data_AzureSql.psm1
    Data_AzureSql.psd1
    Open-AzureSqlConnection.ps1
    New-AzureSqlCommand.ps1
    Add-AzureSqlParameters.ps1
    Invoke-AzureSqlWrite.ps1
    Invoke-AzureSqlQuery.ps1
    Invoke-AzureSqlDelete.ps1
    ConvertTo-AzureSqlJsonResult.ps1
  Tests/
```

Model its lifecycle after `Storage_AzureStorageAccount`:

- Provide a `Data_AzureSql` class.
- Provide a parameterless constructor.
- Implement `Construct([object]$dictionary)` and retain the hydrated adapter jacket.
- Implement `[Signal] Invoke([string]$Slot, [string]$Activity, [Signal]$ConductionSignal, [object]$Plan, [Signal]$ItemSignal)`.
- Export `Resolve-Data_AzureSql` from the module.
- Load operation helpers from the module entry point.
- Read adapter-level configuration from the constructed jacket.
- Read operation-level configuration from `Plan.Config`.
- Return unsupported activities and all execution errors as failed signals.

Establish the injectable internal execution boundary during this structural refactor, before implementing connections and operations. Define how tests substitute connection, command, reader, and transaction interactions while exercising the adapter's real validation, conversion, and orchestration logic. Keep the boundary internal; do not expose mock handlers or a mock mode through production configuration. Later implementation steps must reuse this boundary.

The step 2 scaffold uses private `Invoke-AzureSqlExecution` inside the module as the only call from `Data_AzureSql.Invoke` into execution. It receives the constructed adapter (and thus its hydrated jacket), slot, activity, original plan/config, and both signals. It currently fails with an explicit pending-implementation error. The direct mapped-routing test substitutes this private function in module scope to verify routing and signal propagation without SQL state. When implementing steps 5–12, keep this entry point as the real validation/orchestration path and place provider creation behind an internal session factory. Tests should replace that factory with a connection double whose `Open`, `CreateCommand`, and `BeginTransaction` return command, reader, and transaction doubles; cover `ExecuteReader`/`ExecuteNonQuery`, `Read`/`NextResult`/schema/value access, `Commit`/`Rollback`, and disposal while the real adapter code runs. Do not expose the factory or doubles in adapter configuration. The current routing substitute is transitional and does not count as SQL operation coverage.

Remove all mock-only members and behavior:

- `Mode = Mock` requirements.
- `Data` and `SeedData` state.
- Procedure and command handlers.
- Reset support.
- Invocation recording.
- Injected failures.
- Mock configuration fixtures and mock-specific tests.

## 3. Package Microsoft.Data.SqlClient

Use `Microsoft.Data.SqlClient` rather than `System.Data.SqlClient`.

Add a pinned and repeatable dependency restore/package step that includes the provider and its runtime dependencies in the adapter module artifact. Runtime module import must not download packages.

The dependency work must:

- Pin the selected package version.
- Restore dependencies during build or packaging.
- Copy the appropriate managed and native runtime assets into the adapter artifact.
- Load the packaged provider before loading the adapter class.
- Fail module import with a clear message if required assemblies are unavailable.
- Work in a fresh PowerShell 7 process on the deployment target.

Update `Data_AzureSql.psd1` with an accurate description, explicit exports, PowerShell compatibility, and dependency metadata appropriate to the final package layout.

## 4. Configure the live adapter for sdadev01

Add the adapter mapping to:

```text
SDAFusion-Content/SDA/Config/SDAFusionApp.Json
Agents[Name=sdadev01].Roles.SDAWorkItems.Adapters
```

Configured adapter jacket:

```json
{
    "Name": "SDAFusionDatabase",
    "VirtualPath": "SovereignTrust.Adapters.Data.AzureSql.FusionDatabase.Persistent.Full",
    "IsMapped": true,
    "Resource": "sda-fusion",
    "Addresses": [
        "sda-dev.database.windows.net"
    ]
}
```

Configuration responsibilities for this approved passwordless mapping:

- `VirtualPath` selects the `AzureSql` adapter implementation and registers it in the `FusionDatabase` slot.
- `Resource` names the Azure SQL database (`sda-fusion`).
- `Addresses` supplies exactly one Azure SQL server (`sda-dev.database.windows.net`).
- `Plan.Config` supplies the command or procedure and its parameters.

Do not store a password, client secret, or access token in this file. The production loader still passes the jacket through hydration before construction. A protected SqlClient connection resource remains a supported alternate configuration.

## 5. Implement secure connection construction

For the configured passwordless form, use the database name in `Resource` and the single server in `Addresses` to assign typed `Microsoft.Data.SqlClient.SqlConnectionStringBuilder` properties with `Active Directory Default` authentication. Validate both values before use. For the protected connection-resource form, parse the hydrated `Resource` using the builder and ignore `Addresses` as a SQL endpoint. Never construct a connection string through textual concatenation.

The protected resource may select any explicitly supported SqlClient authentication mode. The preferred passwordless modes are:

- `Active Directory Default` for local development and general passwordless resolution.
- `Active Directory Managed Identity` for hosted execution, including an optional user-assigned identity.

Service-principal or SQL-password authentication may be supported when required, but their credentials must exist only in the protected secret value and must never be copied into plans, logs, or the application configuration.

Apply secure defaults:

```text
Encrypt=True
TrustServerCertificate=False
Application Name=SovereignTrust.Adapters.Data.AzureSql
```

Connection handling must:

- Validate the plain database plus single SQL server form or the protected connection-resource form.
- Require a SQL data source and initial catalog after building or parsing the resource.
- Enforce encryption and reject insecure certificate-trust settings unless an explicit, separately approved development override exists.
- Apply the connection timeout from the protected resource, when used, or a safe adapter default.
- Open a new connection for an invocation and dispose it deterministically.
- Avoid logging connection strings, credentials, tokens, or parameter values.
- Return authentication, firewall, DNS, timeout, and provider errors through a failed signal.

## 6. Define typed SQL parameters

Use parameter descriptors as the canonical plan representation:

```json
"Parameters": [
    {
        "Name": "@Id",
        "SqlDbType": "Int",
        "Value": 1
    },
    {
        "Name": "@Amount",
        "SqlDbType": "Decimal",
        "Precision": 18,
        "Scale": 4,
        "Value": 125.5000
    },
    {
        "Name": "@Result",
        "SqlDbType": "Int",
        "Direction": "Output"
    }
]
```

The adapter must:

- Construct `SqlParameter` objects explicitly.
- Convert null parameter values to `DBNull.Value`.
- Apply type, size, precision, scale, and direction.
- Support input, output, input/output, and return-value parameters.
- Reject unknown SQL types, invalid directions, and failed conversions.
- Keep parameter values separate from procedure names and SQL text.
- Never perform textual parameter substitution.

The existing dictionary parameter form may be retained as a compatibility format with conservative inference. Explicit descriptors take precedence and are required when size, precision, scale, direction, or an unambiguous database type matters.

Table-valued parameters are outside the initial scope because Write uses a normalized JSON payload. Unsupported structured parameters must fail explicitly.

## 7. Implement Write, Query, and Delete

### Write

- Require `Config.Procedure`.
- Use `CommandType.StoredProcedure`.
- Require locally normalized JSON text derived from exactly one of `Config.Content` or `Config.ContentPath`, following the input contract in section 1. Do not write the normalized text back into the caller's plan.
- Bind it to `Config.PayloadParameter`, defaulting to `@Payload`.
- Use `NVarChar(MAX)` for the payload parameter.
- Bind additional typed parameters.
- Execute the procedure and capture result sets, affected rows, output parameters, and the return value.

### Query

- Require `Config.CommandText`.
- Use `CommandType.Text`.
- Bind typed parameters independently from the SQL text.
- Execute a data reader.
- Traverse every result with `NextResult()`.
- Preserve empty result sets and their column metadata.

### Delete

- Require `Config.CommandText`.
- Use `CommandType.Text` and typed parameters.
- Execute with `ExecuteNonQuery()` when no result sets are expected.
- Preserve zero as `RowsAffected: 0`.
- Convert a provider result of `-1` to `RowsAffected: null`, because the affected count is unknown.

Apply `Config.CommandTimeoutSeconds` when present, otherwise use the adapter-level default. Do not automatically retry Write or Delete because their idempotency is unknown.

## 8. Enforce the JSON result boundary

Every successful operation must call `Signal.SetResult()` with valid JSON text using this common envelope:

```json
{
    "Operation": "Query",
    "RowsAffected": null,
    "OutputParameters": {},
    "ResultSets": [
        {
            "Name": "Table",
            "Columns": [
                {
                    "Name": "Id",
                    "Type": "int",
                    "Ordinal": 0,
                    "AllowDBNull": false,
                    "Precision": null,
                    "Scale": null
                }
            ],
            "Rows": []
        }
    ]
}
```

Use data-reader schema information so columns remain available when a result set contains no rows.

Conversion rules:

- Database null becomes JSON `null`.
- Binary values become base64 strings.
- GUID values become canonical strings.
- Date and time values use invariant ISO-8601 representations.
- Decimal values become invariant precision-preserving strings.
- Integers outside the JavaScript safe-integer range become strings.
- Safe integers and floating-point values remain JSON numbers.

No `SqlConnection`, `SqlCommand`, `SqlParameter`, `SqlDataReader`, `DataSet`, `DataTable`, or `DataRow` may escape through a result, output parameter, or signal jacket.

## 9. Make mutations transactional

Default Write and Delete operations to an explicit database transaction:

1. Open the connection.
2. Begin a transaction.
3. Create and execute the command.
4. Materialize all result sets and output parameters.
5. Serialize the complete JSON envelope.
6. Commit only after serialization succeeds.
7. Roll back when execution, conversion, or serialization fails.

Allow a narrowly documented configuration override only when a stored procedure cannot participate in an adapter-managed transaction. Query operations do not require an explicit transaction by default.

## 10. Update plans and examples

Write plans route directly through the mapped data slot:

```json
{
    "Name": "IngestRecords",
    "Adapter": "Data.FusionDatabase",
    "Activity": "Write",
    "Key": "IngestResult",
    "Config": {
        "InputFormat": "Object",
        "PayloadMode": "Records",
        "Content": [
            {
                "Id": 1,
                "Name": "Museum"
            }
        ],
        "Procedure": "example.usp_IngestRecords",
        "PayloadParameter": "@Payload",
        "Parameters": []
    }
}
```

`example.usp_IngestRecords` is illustrative. Replace its schema and procedure name with a reviewed procedure in the target database before using the plan. Query and Delete plans use `Config.CommandText`, typed `Config.Parameters`, and an optional `Config.CommandTimeoutSeconds`.

The active, parseable JSON-record, CSV-record, nested-document, Query, Delete, and result-envelope examples are in `Src/Data/AzureSql/README.md`. They show the direct `Data.FusionDatabase` route and mark schema names as placeholders. The same README documents dependency packaging, protected-resource authentication, and the narrowly supported Write `TransactionMode=None` override.

Examples must contain no operational credentials and must clearly distinguish placeholders from usable environment configuration.

## 11. Test the production adapter

### Unit and contract tests

Test without requiring an Azure connection where possible:

- AzureSql input normalization, immutable-plan behavior, and preservation of parameter value types.
- Connection-builder validation and secure defaults.
- Typed parameter construction and conversion.
- Null, decimal, binary, date, GUID, and output parameters.
- Command type and timeout selection.
- Empty and multiple result-set conversion.
- JSON envelope consistency.
- Resource disposal.
- Transaction commit and rollback control flow.
- Failed signals for invalid configuration and provider exceptions.

Use an injectable internal execution boundary for unit tests. Do not ship an in-memory SQL implementation as production adapter behavior.

### Clean-session module loading tests

Use two separate fresh PowerShell 7 processes:

1. An explicit-import smoke test imports Foundation and the packaged AzureSql module and verifies provider loading, factory resolution, and construction.
2. A production lazy-resolution test imports Foundation and required bootstrap dependencies only, with AzureSql initially unloaded. Load configuration and register jackets through the production loader, then invoke `Data.FusionDatabase` and verify that production resolution loads `Data_AzureSql.psd1`, calls `Resolve-Data_AzureSql`, and calls `Construct()` with the hydrated jacket. Do not pre-import AzureSql, dot-source its class, pre-call its factory, or manually register its implementation. Use the internal execution boundary for offline SQL execution checks without bypassing production module resolution.

Passing the explicit-import test does not establish that lazy resolution works.

### Live Azure SQL integration tests

Run gated tests against a dedicated integration database and schema:

1. Start a fresh PowerShell 7 process and import Foundation and required bootstrap dependencies only. Confirm AzureSql is initially unloaded; do not manually import or register its implementation.
2. Load the real `SDAFusionApp.Json` configuration.
3. Select agent `sdadev01` and role `SDAWorkItems`.
4. Register the adapter jackets through the production loader.
5. On the first mapped invocation, confirm production lazy resolution loads `Data_AzureSql.psd1`, calls `Resolve-Data_AzureSql`, and calls `Construct()` with the hydrated jacket.
6. Route through `Data.FusionDatabase -> MappedDataAdapter -> FusionDatabase -> Data_AzureSql`.
7. Write JSON records.
8. Write CSV records, including quoted values, empty values, and embedded newlines.
9. Ingest a nested JSON document.
10. Query multiple rows, no rows, and multiple result sets.
11. Delete selected records and verify the affected count.
12. Query the remaining records.
13. Exercise a failing command and verify rollback.
14. Confirm every successful result is valid JSON text and no database object escapes.

The live suite requires:

- The Azure SQL server endpoint.
- The database name.
- Network and firewall access from the test host.
- An authenticated identity.
- A contained database user with least-privilege permissions.
- Dedicated test tables and stored procedures that can be safely reset.

For the approved `sda-fusion` target, the fixture schema is `test_sda_azure_sql_it_adapter`. The live suite must still use a contained database identity limited to that fixture; the provisioning identity's DDL rights do not satisfy the live-suite prerequisite.

## Recommended implementation order

1. Remove the `Condenser.Data` route and any provisional DataCondenser implementation created solely for AzureSql.
2. Remove mock-only AzureSql behavior and tests.
3. Define AzureSql-owned write normalization and immutable-plan behavior.
4. Define and pin the `Microsoft.Data.SqlClient` dependency package layout.
5. Refactor the AzureSql module, class, manifest, factory, and operation helper structure.
6. Implement secure connection construction and authentication modes.
7. Implement typed SQL parameter construction.
8. Implement Write with stored-procedure JSON ingestion.
9. Implement Query with empty and multiple result-set support.
10. Implement Delete with accurate affected-row semantics.
11. Harden JSON conversion for metadata, nulls, dates, binary values, and precision-sensitive numbers.
12. Add transactions, deterministic disposal, sanitized errors, and rollback behavior.
13. Validate the `sdadev01` / `SDAWorkItems` `FusionDatabase` mapping and hydrated `Resource` contract.
14. Update plans, examples, and adapter documentation to use `Data.FusionDatabase`.
15. Run unit, direct mapped-routing, clean-session, and gated live Azure SQL integration tests.
16. Run the existing Foundation mapped-adapter and plan-execution regression suites.

## Completion criteria

The implementation is complete when:

- The production environment resolves `SovereignTrust.Adapters.Data.AzureSql` from the `FusionDatabase` virtual path without manual module import or registration.
- `Data.FusionDatabase` can execute real Write, Query, and Delete operations through the mapped data route.
- SQL text and parameter values remain separate.
- Writes use stored procedures with normalized JSON payloads.
- Query results preserve empty and multiple result sets with metadata.
- Deletes distinguish zero affected rows from an unknown count.
- All successful results are valid JSON text.
- No provider or database objects escape the adapter boundary.
- Failed mutating operations roll back.
- Secrets and access tokens are neither committed nor logged.
- The original caller plan and input remain unchanged.
- Focused integration and existing regression tests pass.


## Prompt addendum

Run these prompts in order. Step numbers refer to **Recommended implementation order**, not the numbered design sections above. Each prompt builds on the completed work from the preceding prompts. The plan's design requirements and completion criteria remain authoritative.

Use each Review Prompt after its corresponding Perform Prompt. Reviews inspect the actual implementation and validation evidence without changing implementation files. Assess the completed stage and regressions it introduces; distinguish defects from work explicitly assigned to later prompts. Report findings by severity with file/line references, concrete impact, and recommended corrections, followed by checks run, checks not run, and whether the stage is ready for the next prompt. If no defects are found, state that explicitly and identify any remaining validation limits.

Apply these rules to every review below:

- Identify the changes attributable to the implementation being reviewed. Distinguish introduced defects from pre-existing issues and unrelated workspace edits; do not treat unrelated edits as implementation regressions.
- Reuse credible validation evidence that applies to the current code, packaged artifact, and relevant environment. Rerun checks when evidence is missing, relevant changes invalidate it, or a specific concern requires verification. Instructions below to run checks follow this rule; avoid repeating overlapping suites or rebuilding an unchanged, already-validated artifact without a reason. Identify reused evidence and its scope.
- Report concrete defects and material coverage gaps against the plan and the current stage. Do not introduce new requirements, demand a separate test for every checklist item, or require a particular mocking architecture. Accept internal designs that exercise the required real behavior and provide adequate evidence.
- Keep unavailable validation separate from confirmed defects. Explain whether each gap blocks the next stage or can remain tracked for a later stage. Missing live prerequisites do not imply an implementation defect, but required live validation must still be verified before declaring overall completion.

### Prompt A (Steps 1-2)

Perform Prompt:

```text
Read SovereignTrust.Adapters/docs/AzureSql-Data-Adapter-Implementation-Plan.md and the applicable repository guidance. Implement steps 1-2 of Recommended implementation order.

Inspect the existing AzureSql implementation, Foundation mapped-adapter infrastructure, and consumers of any provisional DataCondenser. Establish Data.FusionDatabase -> MappedDataAdapter -> FusionDatabase -> Data_AzureSql as the intended route. Remove the Condenser.Data route, registration, helpers, and dedicated tests only where they were introduced solely for AzureSql and have no independent consumers. Preserve generic mapped-adapter routing and signal propagation in Foundation. If independent consumers exist, preserve their functionality and document the remaining dependency.

Before deleting normalization helpers or dedicated tests, add a migration checklist to this plan for Prompt B. Capture ContentPath resolution against ItemSignal, accepted InputFormat/PayloadMode values and defaults, Delimiter and ColumnSchema behavior, and reusable input/output examples and test assertions. Include source paths and enough detail to implement the replacement after the original files are removed. Preserve reusable normalization test cases in that checklist or adapter test fixtures, without retaining obsolete condenser routing or plan-cloning behavior. This preservation is part of cleanup, not implementation of step 3.

Remove AzureSql mock-only production behavior, including Mode=Mock requirements, Data/SeedData state, handlers, reset support, invocation recording, and injected failures. Remove obsolete mock configuration fixtures and mock-specific tests. Retain useful contract coverage and test doubles that support a future internal execution boundary without shipping an in-memory SQL implementation.

Search for remaining references to removed symbols and run the relevant available routing and module checks. Report changed files, validation results, and any transitional gaps that later prompts must complete. Do not implement subsequent steps in this prompt.
```

Review Prompt:

```text
Read SovereignTrust.Adapters/docs/AzureSql-Data-Adapter-Implementation-Plan.md, including Perform Prompt A and the review instructions, and applicable repository guidance. Review the implementation of steps 1-2 without modifying implementation files. Inspect the actual diff and affected callers, not just the implementation summary.

Verify that removing Condenser.Data and provisional DataCondenser code was supported by a consumer search, that independent consumers remain functional, and that Foundation retains generic mapped routing and signal propagation. Check for dangling registrations, imports, exports, helper references, and test dependencies. Distinguish historical references and this plan from executable dependencies.

Verify that the migration checklist preserves the removed normalization contracts, source references, input/output examples, and reusable assertions needed by Prompt B. It must cover ItemSignal-relative ContentPath, input defaults, Delimiter, ColumnSchema, and immutable inputs without carrying forward plan cloning or obsolete routing requirements.

Check that AzureSql mock-only production state, handlers, reset/recording/failure injection behavior, fixtures, and dedicated tests were removed, while useful contract coverage and legitimate test doubles were preserved. Run relevant available routing and module checks. Do not flag unimplemented production SQL operations assigned to later prompts as step 1-2 defects; identify any transitional limitations explicitly.

Report evidence-backed findings by severity with file/line references, impact, and recommended corrections; list validation results and limitations and give a readiness verdict for Prompt B.
```

### Prompt B (Step 3)

Perform Prompt:

```text
Read SovereignTrust.Adapters/docs/AzureSql-Data-Adapter-Implementation-Plan.md and the applicable repository guidance. Build on steps 1-2 and implement step 3 of Recommended implementation order.

Define and implement AzureSql-owned Write input validation and normalization using section 1 and the migration checklist preserved by Prompt A. Resolve exactly one of Config.Content or Config.ContentPath, checking member presence rather than truthiness and rejecting both or neither. Resolve ContentPath against ItemSignal using Resolve-PathFromDictionary, for example @.Payload; it is not a filesystem path. Propagate missing-path and resolution failures through a failed signal.

Support InputFormat Object, Json, and Csv with Object as the omitted-value default; support PayloadMode Records and Document with Records as the omitted-value default. Reject unsupported values and reject CSV with Document mode. Retain the existing single-character Delimiter option with comma as its default, and the optional ColumnSchema contract for Records, including dictionary and Name/Type descriptor forms and existing supported conversions. Apply schema conversions to local payload rows only. Document these contracts and port the preserved normalization cases into adapter-owned tests. Preserve empty and one-element top-level arrays in document mode and handle quoted CSV fields, empty values, and embedded newlines.

Treat the caller's plan and input as immutable on success and failure. Prepare normalized JSON and other command values locally; do not rewrite or clone the plan. In particular, normalization of the Write payload must not serialize or coerce unrelated typed SQL parameter values. Preserve Int32, Int64, Decimal, Guid, DateTime, byte[], nulls, dictionaries, and arrays in the caller's parameter input. Keep all AzureSql-specific validation and normalization out of Foundation.

Add and run focused tests for supported inputs and defaults, signal-relative ContentPath resolution and failures, invalid or ambiguous content sources, Delimiter and ColumnSchema behavior, document array cardinality, parameter type preservation, and unchanged caller data after both success and failure. Report the implemented contract and validation results.
```

Review Prompt:

```text
Read SovereignTrust.Adapters/docs/AzureSql-Data-Adapter-Implementation-Plan.md, including Perform Prompt B, Prompt A's migration checklist, and the review instructions, and applicable repository guidance. Review step 3 without modifying implementation files. Trace real normalization code and its tests.

Verify exactly-one Content/ContentPath validation uses member presence and resolves ContentPath against ItemSignal through Resolve-PathFromDictionary. Check successful nested resolution, missing paths, failed resolution signals, both/neither sources, and false-like or empty values so they are validated rather than mistaken for missing members.

Check Object/Json/Csv formats, Object and Records defaults, Records/Document modes, rejection of invalid values and CSV Document mode, single-character Delimiter support, and both ColumnSchema forms with supported conversions and failure paths. Verify quoted CSV fields, empty fields, embedded newlines, nested documents, and empty/one-element document arrays against actual serialized JSON. Check that PowerShell pipeline enumeration does not silently change array cardinality.

Verify normalization prepares local values without rewriting or cloning the plan or mutating nested input. Check runtime parameter types and values before and after both success and failure; JSON equality alone cannot establish Int32/Int64/Decimal/Guid/DateTime/byte[] type preservation. Confirm AzureSql-specific normalization remains outside Foundation and preserved test cases have adapter-owned coverage.

Run focused normalization tests. Report findings by severity with file/line references, impact, and recommended corrections, then validation results, limitations, and readiness for Prompt C. Do not require connection or operation behavior assigned to later prompts.
```

### Prompt C (Steps 4-5)

Perform Prompt:

```text
Prompt C (Steps 4-5)
Read SovereignTrust.Adapters/docs/AzureSql-Data-Adapter-Implementation-Plan.md and the applicable repository guidance. Build on steps 1-3 and implement steps 4-5 of Recommended implementation order.

Inspect Storage/AzureStorageAccount and the existing build/deployment conventions. Select and pin a compatible Microsoft.Data.SqlClient version and implement a repeatable build or packaging restore that includes its required managed and native runtime dependencies in the AzureSql module artifact. Document the supported deployment target and package layout. Runtime module import must never download dependencies. Load the packaged provider before the adapter class and fail import clearly when required assemblies are missing.

Refactor the AzureSql module, class, manifest, factory, and operation helper structure to match the plan and the AzureStorageAccount lifecycle. Provide Data_AzureSql, its parameterless constructor, Construct([object]$dictionary) retaining the hydrated jacket, and exported Resolve-Data_AzureSql. Implement the exact invocation signature: [Signal] Invoke([string]$Slot, [string]$Activity, [Signal]$ConductionSignal, [object]$Plan, [Signal]$ItemSignal). Load helpers from the module entry point. Keep adapter configuration in the jacket and operation configuration in Plan.Config. Wire the normalization from step 3 into the adapter structure and return unsupported activities and execution errors as failed signals. Update manifest metadata, explicit exports, and PowerShell compatibility to match the packaged artifact.

Establish and document the injectable internal execution boundary now, so Prompts D-F can reuse it. Define how tests substitute connection, command, reader, and transaction interactions while running real adapter validation, conversion, and orchestration. Add a focused test demonstrating that the boundary is replaceable internally. Keep production execution directed at SqlClient and do not introduce public mock handlers, a mock configuration mode, or an in-memory SQL implementation. Concrete connection and operation behavior remains assigned to the subsequent prompts.

Validate dependency packaging, provider loading, construction, factory resolution, and module import in a fresh PowerShell 7 process. Check the missing-dependency failure path. Report package/version choices, commands run, and any deployment-target validation still outstanding.
```

Review Prompt:

```text
Read SovereignTrust.Adapters/docs/AzureSql-Data-Adapter-Implementation-Plan.md, including Perform Prompt C and the review instructions, and applicable repository guidance. Review steps 4-5 without modifying implementation files. Compare the actual module structure and lifecycle with the referenced AzureStorageAccount conventions and the plan's exact Invoke signature.

Inspect the pinned Microsoft.Data.SqlClient dependency definition, restore/package commands, selected deployment target, and generated artifact. Verify required managed and native dependencies are packaged, provider loading precedes class loading, imports do not download packages, and import success does not depend on a developer's already-loaded assemblies or machine-specific paths. Validate manifest compatibility, exports, and dependency metadata against the artifact. Test missing dependencies using an isolated artifact copy rather than damaging the working package.

Verify the parameterless constructor, Construct retaining the hydrated jacket, Resolve-Data_AzureSql export, five-argument Signal-returning Invoke, helper loading, configuration boundaries, normalization wiring, and failed-signal behavior. Check that the internal injectable boundary supports testing the required connection/command/reader/transaction interactions while retaining real adapter logic and does not expose production mock configuration or handlers. Accept any internal design that meets this contract; do not require a separate abstraction or mock for each provider object.

Inspect packaging, fresh PowerShell 7 explicit-import smoke-test, and focused lifecycle/boundary evidence for the current artifact. Rebuild or rerun only where the shared review rules require it and tooling is available. Distinguish explicit import from production lazy-resolution validation assigned to Prompt H. Report findings by severity with file/line references, impact, and corrections, validation commands/results, reused evidence, deployment-target limitations, and readiness for Prompt D.
```

### Prompt D (Steps 6-7)

Perform Prompt:

```text
Prompt D (Steps 6-7)
Read SovereignTrust.Adapters/docs/AzureSql-Data-Adapter-Implementation-Plan.md and the applicable repository guidance. Build on steps 1-5 and implement steps 6-7 of Recommended implementation order.

Implement secure connection construction using Microsoft.Data.SqlClient.SqlConnectionStringBuilder. Accept the configured database Resource plus one Azure SQL server Addresses value with Active Directory Default, or a protected connection-string Resource with an explicitly supported authentication mode. Require data source and initial catalog. Apply encryption, certificate validation, application name, and connection timeout requirements. Keep connection strings, credentials, access tokens, and parameter values out of logs and errors.

Implement explicit SqlParameter construction from canonical descriptors, including SqlDbType, Size, Precision, Scale, Direction, DBNull.Value, output/input-output parameters, and return values. Reject invalid types, directions, conversions, and unsupported structured parameters. If dictionary compatibility is retained, use conservative inference and document its limitations. Keep parameter values separate from SQL text and procedure names.

Add and run focused tests for connection validation and defaults, supported authentication configuration, typed value preservation and conversion, parameter metadata, nulls, output directions, and rejection paths. Use an internal injectable boundary where needed without requiring a live Azure connection. Report results and the supported configuration contract.
```

Review Prompt:

```text
Read SovereignTrust.Adapters/docs/AzureSql-Data-Adapter-Implementation-Plan.md, including Perform Prompt D and the review instructions, and applicable repository guidance. Review steps 6-7 without modifying implementation files. Inspect real connection and parameter helpers and run their focused tests through the internal execution boundary.

Verify construction of both the direct passwordless database/server jacket and protected connection-resource form with Microsoft.Data.SqlClient.SqlConnectionStringBuilder. Check encryption, certificate validation, application name, timeout, invalid values, and supported Default and Managed Identity modes. Inspect failure paths for accidental disclosure using synthetic secret values.

Inspect actual SqlParameter objects produced by tests. Verify names, explicit types, size, precision, scale, DBNull, input/output/input-output/return directions, conversion failures, and rejection of unsupported structured parameters. If dictionary compatibility exists, check conservative inference and descriptor precedence. Confirm parameter values remain separate from command text and procedure names and caller values remain unchanged.

Check that tests exercise actual builder and parameter code rather than mocking away the behavior being asserted. Distinguish offline authentication configuration checks from a successful live authentication claim. Report findings by severity with file/line references, impact, and corrections, validation results and gaps, and readiness for Prompt E.
```

### Prompt E (Steps 8-10)

Perform Prompt:

```text
Prompt E
Read SovereignTrust.Adapters/docs/AzureSql-Data-Adapter-Implementation-Plan.md and the applicable repository guidance. Build on steps 1-7 and implement steps 8-10 of Recommended implementation order.

Implement Write, Query, and Delete using the packaged provider, secure connection helper, typed parameters, and local normalized command values. Write must require Config.Procedure, use StoredProcedure, bind normalized JSON as NVarChar(MAX) to Config.PayloadParameter or @Payload, and capture result sets, affected rows, output parameters, and the return value. Do not modify the original Config.Content to satisfy the normalized JSON requirement.

Query must require Config.CommandText, use Text, execute a data reader, traverse every result with NextResult(), and preserve empty result sets with their column metadata. Delete must require Config.CommandText, use Text and typed parameters, and use ExecuteNonQuery when no result sets are expected. Preserve zero affected rows and represent a provider count of -1 as null. Apply operation-level command timeouts with the adapter default as fallback. Do not automatically retry Write or Delete.

Route successful results through the common JSON envelope and Signal.SetResult(), and return failures through failed signals. Capture output values after reader completion as required by SqlClient. Establish deterministic disposal for all resources introduced here; the next prompt must complete conversion hardening and transaction guarantees before live mutation tests.

Add and run focused operation tests through the internal execution boundary for command selection, payload binding, timeout selection, multiple/empty results, output values, and affected-row semantics. Report results and remaining work assigned to steps 11-12.
```

Review Prompt:

```text
Review Prompt E
Read SovereignTrust.Adapters/docs/AzureSql-Data-Adapter-Implementation-Plan.md, including Perform Prompt E and the review instructions, and applicable repository guidance. Review steps 8-10 without modifying implementation files. Trace each operation from Invoke through command construction, execution, result materialization, and returned Signal.

For Write, verify required Procedure, StoredProcedure command type, locally normalized JSON, the configured/default payload parameter, NVarChar(MAX), additional typed parameters, and capture of results, affected rows, output parameters, and return value. Ensure the original plan is unchanged. For Query, verify required CommandText, Text type, independent parameter binding, traversal of all results, and schema retention for empty result sets. For Delete, verify ExecuteNonQuery where no results are expected, zero retained as zero, and -1 represented as null.

Check operation timeout override and adapter fallback, absence of automatic mutation retries, failed signals for invalid configuration and provider failures, and valid common-envelope JSON supplied to Signal.SetResult. Verify readers complete and close before output parameters are captured, and resources introduced here are disposed on success and failure. Check that the injectable boundary leaves command selection and operation orchestration under test.

Run focused operation tests without live mutation tests. Treat final precision conversion and transaction hardening as Prompt F work, while identifying any defects in the current operation contracts. Report findings by severity with file/line references, impact, and corrections, test results and limitations, and readiness for Prompt F.
```

### Prompt F (Steps 11-12)

Perform Prompt:

```text
Prompt F (Steps 11-12)
Read SovereignTrust.Adapters/docs/AzureSql-Data-Adapter-Implementation-Plan.md and the applicable repository guidance. Build on steps 1-10 and implement steps 11-12 of Recommended implementation order.

Complete and harden the shared JSON result converter. Preserve schema metadata even for empty result sets. Apply the plan's conversion rules for database nulls, binary/base64 values, canonical GUIDs, invariant ISO-8601 dates and times, precision-preserving decimal strings, and integers outside the JavaScript safe range. Keep safe integers and floating-point values as JSON numbers. Apply conversion consistently to rows and output parameters, including return values. Ensure no provider or database object escapes through results or signal jackets.

Make Write and Delete transactional by default: open a connection, begin a transaction, execute, fully materialize results and output parameters, serialize the complete envelope, and commit only after serialization succeeds. Roll back on execution, conversion, or serialization failure. Handle commit, rollback, and cleanup failures without masking the primary failure or exposing secrets. Keep Query without an explicit transaction by default. Implement and narrowly document any required stored-procedure transaction opt-out under the plan's constraints.

Complete deterministic disposal and sanitized failed-signal handling across all paths. Test metadata and precision boundaries, conversion and serialization failures, commit ordering, rollback, disposal, sanitized errors, and caller-plan immutability. Run the focused adapter suite and report results.
```

Review Prompt:

```text
Review  Prompt F (Steps 11-12)
Read SovereignTrust.Adapters/docs/AzureSql-Data-Adapter-Implementation-Plan.md, including Perform Prompt F and the review instructions, and applicable repository guidance. Review steps 11-12 without modifying implementation files. Inspect the real converter, transaction orchestration, error handling, and disposal paths.

Verify the common JSON envelope, complete schema for empty and multiple result sets, database nulls, base64 binary, canonical GUIDs, invariant dates/times, precision-preserving decimal strings, and string conversion outside both positive and negative JavaScript safe-integer boundaries. Check safe integers and floating-point values remain numbers, including under a non-default culture. Apply the same review to output parameters and return values. Inspect nested results and signal jackets for escaping provider/database objects.

Trace Write and Delete through connection open, transaction begin, command enlistment, execution, reader completion, output capture, full serialization, and commit. Verify commit follows successful serialization and that execution, conversion, and serialization failures trigger rollback. Inspect commit/rollback/cleanup failure handling for masked primary errors, misleading success, resource leaks, and secret disclosure. Verify Query's default transaction behavior and the documented scope of any stored-procedure opt-out.

Inspect focused-test and offline adapter-suite evidence, reusing applicable results under the shared review rules. If additional validation is needed, run the relevant offline checks without repeating focused tests already covered by the suite; do not trigger live integration tests in this review. Confirm failure tests inject faults at the actual boundaries and observe transaction ordering and disposal, rather than merely asserting mocked success. Check immutable caller data on failure and ensure logs and signal errors do not expose synthetic credentials or parameter values. Report findings by severity with file/line references, impact, and corrections, validation evidence and gaps, and readiness for ```

### Prompt G (Steps 13-14)

Perform Prompt:

```text
 Prompt G (Steps 13-14)
Read SovereignTrust.Adapters/docs/AzureSql-Data-Adapter-Implementation-Plan.md and the applicable guidance in each affected repository. Build on steps 1-12 and implement steps 13-14 of Recommended implementation order.

Inspect SDAFusion-Content/SDA/Config/SDAFusionApp.Json and add or correct the sdadev01 / SDAWorkItems adapter mapping without duplicating an existing jacket or disturbing unrelated configuration. Use the approved SDAFusionDatabase jacket, SovereignTrust.Adapters.Data.AzureSql.FusionDatabase.Persistent.Full virtual path, IsMapped=true, Resource=sda-fusion, and Addresses=[sda-dev.database.windows.net].

Validate the production loader's mapping and hydration contract: the implementation resolves into FusionDatabase, Construct receives the hydrated jacket, and the connection builder uses its database Resource and SQL server Addresses. Exercise hydration through the appropriate test boundary and reserve live validation for the gated suite.

Update affected plans, examples, and adapter documentation to use Data.FusionDatabase directly. Include JSON records, CSV records, nested documents, typed Query/Delete parameters, timeouts, the result envelope, dependency packaging, authentication configuration, and any supported transaction override. Clearly mark placeholders and include no operational credentials. Remove stale AzureSql mock and Condenser.Data instructions while preserving any independent consumers identified earlier.

Validate configuration parsing, mapping uniqueness, example consistency, and focused loader/routing contracts. Report changed files and validation results.
```

Review Prompt:

```text
Review  Prompt G (Steps 13-14)
Read SovereignTrust.Adapters/docs/AzureSql-Data-Adapter-Implementation-Plan.md, including Perform Prompt G and the review instructions, and applicable guidance in affected repositories. Review steps 13-14 without modifying implementation files. Inspect configuration, loader contracts, examples, documentation, and their diffs together.

Verify the sdadev01 / SDAWorkItems mapping exists exactly once with the approved SDAFusionDatabase name, exact SovereignTrust.Adapters.Data.AzureSql.FusionDatabase.Persistent.Full virtual path, IsMapped=true, Resource=sda-fusion, and Addresses=[sda-dev.database.windows.net]. Confirm this implementation introduced no unrelated changes to agents, roles, or jackets; distinguish pre-existing and unrelated workspace edits. Trace registration into FusionDatabase and hydration into Construct; ensure SQL connection construction uses the hydrated database and server values. Use synthetic values for offline hydration checks and do not retrieve or print operational secrets.

Validate example syntax and consistency with the implemented contract for direct Data.FusionDatabase routing, JSON/CSV/document input, typed parameters, timeouts, results, authentication, packaging, and any transaction override. Check placeholders are unmistakable, secrets are absent, and stale mock/Condenser.Data/Config.DataAdapter instructions have been removed from active AzureSql examples and documentation. Preserve legitimate independent consumers and distinguish historical material from active instructions.

Run configuration parsing, mapping uniqueness, example validation, and focused loader/routing tests. Do not equate offline hydration tests with live Key Vault or database verification. Report findings by severity with file/line references, impact, and corrections, checks and limitations, and readiness for Prompt H.
```

### Prompt H (Steps 15-16)

Perform Prompt:

```text
Prompt H (Steps 15-16)
Read SovereignTrust.Adapters/docs/AzureSql-Data-Adapter-Implementation-Plan.md and the applicable repository guidance. Build on steps 1-14 and implement steps 15-16 of Recommended implementation order.

Complete and run the production adapter unit and contract suites and direct mapped-routing tests. Verify normalization, immutable inputs, typed parameters, result envelopes, transactions, disposal, and sanitized failed signals against the plan.

Run two distinct fresh PowerShell 7 process checks. First, explicitly import Foundation and the packaged AzureSql module to smoke-test provider loading, factory resolution, and construction. Second, start another process with Foundation and required bootstrap dependencies only and verify AzureSql is initially unloaded. Load configuration and register jackets through the production loader, then invoke Data.FusionDatabase and verify production lazy resolution loads Data_AzureSql.psd1, calls Resolve-Data_AzureSql, and calls Construct with the hydrated jacket. Do not pre-import AzureSql, dot-source its class, pre-call its factory, or manually register its implementation in this second test. For offline execution, use the internal execution boundary without bypassing module resolution. Verify the complete Data.FusionDatabase -> MappedDataAdapter -> FusionDatabase -> Data_AzureSql route. Report explicit-import and lazy-resolution results separately.

Implement or complete the gated live Azure SQL integration suite using the real SDAFusionApp.Json configuration, sdadev01, SDAWorkItems, and the production jacket loader. Run it when a dedicated integration database/schema, network access, authenticated least-privilege identity, and safely resettable fixtures are available. Cover every live scenario in the plan: JSON and CSV ingestion, nested documents, multiple/empty result sets, Delete counts, remaining records, rollback, and JSON-only result boundaries. Restrict fixture creation, mutations, and cleanup to the dedicated integration resources. Never print the hydrated connection resource or other secrets. If prerequisites are absent, report the suite as not run and list the missing prerequisites; do not claim live verification passed.

Start the live suite in its own fresh process with AzureSql initially unloaded and use the same production lazy-resolution path as the second process check. Execute real SqlClient operations in the live suite without substituting the internal execution boundary.

Run the existing Foundation mapped-adapter and plan-execution regression suites. Fix implementation-related failures and rerun affected checks. Review every completion criterion and report test commands, pass/fail/skip results, unresolved blockers, and any criteria still unverified. Do not declare the implementation complete while required validation remains outstanding.
```

Review Prompt:

```text
Review Prompt H (Steps 15-16)
Read SovereignTrust.Adapters/docs/AzureSql-Data-Adapter-Implementation-Plan.md, including Perform Prompt H, all completion criteria, and the review instructions, and applicable repository guidance. Review steps 15-16 and overall completion without modifying implementation files. Inspect actual test code, implementation paths, commands, and results; do not accept the implementation summary alone as evidence.

Verify unit and contract coverage exercises real normalization, immutable inputs, typed parameters, command selection, JSON conversion, transaction orchestration, disposal, and failed signals. Check direct mapped routing and existing Foundation mapped-adapter/plan-execution regressions. Confirm skips, unavailable dependencies, and unrelated pre-existing failures are reported accurately, not counted as passes.

Verify explicit-import and production lazy-resolution checks run in separate fresh PowerShell 7 processes. The lazy test must begin with AzureSql unloaded, use the production jacket loader and Data.FusionDatabase route, and observe module resolution, factory invocation, and Construct with the hydrated jacket without preloading or manual implementation registration. Confirm the packaged artifact, rather than accidental developer-machine dependencies, is tested.

Inspect the gated live suite for real configuration, sdadev01 / SDAWorkItems selection, genuine SqlClient execution, its own fresh lazy-loading process, and dedicated integration resources. Verify all planned live cases, including CSV edge cases, nested documents, empty/multiple results, affected counts, remaining records, rollback, and JSON-only boundaries. Ensure fixtures and cleanup cannot target unrelated data and logs contain no secrets. Run live tests only with the plan's prerequisites available; otherwise report them as not run. Reuse valid existing live evidence for unchanged code when available and identify its scope.

Run or verify the required focused and regression checks. Report findings by severity with file/line references, impact, and recommended corrections. Provide a concise completion-criteria checklist linking each criterion to code/test evidence and marking it verified, failed, or unverified. Include commands, pass/fail/skip results, residual risks, and an overall completion verdict. Do not declare completion while required validation remains unverified.
```
