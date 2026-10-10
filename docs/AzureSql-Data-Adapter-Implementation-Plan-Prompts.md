
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

Implement secure connection construction from the hydrated adapter jacket Resource using Microsoft.Data.SqlClient.SqlConnectionStringBuilder. Require a valid supported resource, SQL data source, and initial catalog. Never use the Key Vault Addresses value as a SQL endpoint. Apply encryption, certificate validation, application name, and connection timeout requirements from the plan. Support and document the selected authentication modes, including Active Directory Default and Active Directory Managed Identity. Do not introduce an insecure development override without the separate approval required by the plan. Keep connection strings, credentials, access tokens, and parameter values out of logs and errors.

Implement explicit SqlParameter construction from canonical descriptors, including SqlDbType, Size, Precision, Scale, Direction, DBNull.Value, output/input-output parameters, and return values. Reject invalid types, directions, conversions, and unsupported structured parameters. If dictionary compatibility is retained, use conservative inference and document its limitations. Keep parameter values separate from SQL text and procedure names.

Add and run focused tests for connection validation and defaults, supported authentication configuration, typed value preservation and conversion, parameter metadata, nulls, output directions, and rejection paths. Use an internal injectable boundary where needed without requiring a live Azure connection. Report results and the supported configuration contract.
```

Review Prompt:

```text
Read SovereignTrust.Adapters/docs/AzureSql-Data-Adapter-Implementation-Plan.md, including Perform Prompt D and the review instructions, and applicable repository guidance. Review steps 6-7 without modifying implementation files. Inspect real connection and parameter helpers and run their focused tests through the internal execution boundary.

Verify connection construction uses the hydrated Resource and Microsoft.Data.SqlClient.SqlConnectionStringBuilder, requires data source and initial catalog, and never derives the SQL endpoint from Addresses. Check encryption enforcement, certificate validation, application name, connection timeout, rejection of invalid resources, and supported authentication settings, including Default and Managed Identity with optional user-assigned identity. Ensure any insecure override has the explicit approval required by the plan. Inspect failure paths for accidental disclosure using synthetic secret values; do not retrieve operational secrets for this review.

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

Inspect focused-test and offline adapter-suite evidence, reusing applicable results under the shared review rules. If additional validation is needed, run the relevant offline checks without repeating focused tests already covered by the suite; do not trigger live integration tests in this review. Confirm failure tests inject faults at the actual boundaries and observe transaction ordering and disposal, rather than merely asserting mocked success. Check immutable caller data on failure and ensure logs and signal errors do not expose synthetic credentials or parameter values. Report findings by severity with file/line references, impact, and corrections, validation evidence and gaps, and readiness for Prompt G.
```

### Prompt G (Steps 13-14)

Perform Prompt:

```text
 Prompt G (Steps 13-14)
Read SovereignTrust.Adapters/docs/AzureSql-Data-Adapter-Implementation-Plan.md and the applicable guidance in each affected repository. Build on steps 1-12 and implement steps 13-14 of Recommended implementation order.

Inspect SDAFusion-Content/SDA/Config/SDAFusionApp.Json and add or correct the sdadev01 / SDAWorkItems adapter mapping without duplicating an existing jacket or disturbing unrelated configuration. Use the plan's exact SDAFusionDatabase jacket, SovereignTrust.Adapters.Data.AzureSql.FusionDatabase.Persistent.Full virtual path, IsMapped=true, protected Resource expression, and Key Vault Addresses value.

Validate the production loader's mapping and hydration contract: the implementation resolves into FusionDatabase, Construct receives the hydrated jacket, and Resource supplies the protected SQL connection resource. Addresses remains the Key Vault address. Do not retrieve or print operational secrets merely to validate configuration structure; exercise hydration through the appropriate test boundary and reserve live validation for the gated suite.

Update affected plans, examples, and adapter documentation to use Data.FusionDatabase directly. Include JSON records, CSV records, nested documents, typed Query/Delete parameters, timeouts, the result envelope, dependency packaging, authentication configuration, and any supported transaction override. Clearly mark placeholders and include no operational credentials. Remove stale AzureSql mock and Condenser.Data instructions while preserving any independent consumers identified earlier.

Validate configuration parsing, mapping uniqueness, example consistency, and focused loader/routing contracts. Report changed files and validation results.
```

Review Prompt:

```text
Review  Prompt G (Steps 13-14)
Read SovereignTrust.Adapters/docs/AzureSql-Data-Adapter-Implementation-Plan.md, including Perform Prompt G and the review instructions, and applicable guidance in affected repositories. Review steps 13-14 without modifying implementation files. Inspect configuration, loader contracts, examples, documentation, and their diffs together.

Verify the sdadev01 / SDAWorkItems mapping exists exactly once with the plan's SDAFusionDatabase name, exact SovereignTrust.Adapters.Data.AzureSql.FusionDatabase.Persistent.Full virtual path, IsMapped=true, protected Resource expression, and Key Vault Addresses. Confirm this implementation introduced no unrelated changes to agents, roles, or jackets; distinguish pre-existing and unrelated workspace edits. Trace registration into FusionDatabase and hydration into Construct; ensure SQL connection construction consumes hydrated Resource and never uses Addresses as its SQL endpoint. Use synthetic values for offline hydration checks and do not retrieve or print operational secrets.

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
