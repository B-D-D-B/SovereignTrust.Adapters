# Prompt H remediation evidence

## 2026-09-25 deployment-host validation and completion

The user identified the current Windows x64 host as the intended deployment host and **PowerShell 7.6.6** as the preferred deployment version. This host reports PowerShell 7.6.6 and .NET 10.0.12. The current 64-file `PowerShell/` artifact hashes to `394116E47D6596A5763F94F0FDE39FCA6F39BF2753D20F7997EB4512ECE3C502`, matching the read-only fixture probe and prior successful live-operation run; `SDAFusionApp.Json` hashes to `5AB94F24231BF6299EB258580FFFDA6DA8B4C6568842BC76754B04FB39569589`.

With a temporary SignalGraph module junction on `PSModulePath`, the following checks ran in **two distinct fresh `pwsh -NoProfile` child processes** on this deployment host, then the junction and temporary environment change were removed:

| Deployment-host command from adapter repository root | Exit | Observed result |
|---|---:|---|
| `pwsh -NoProfile -File Src/Data/AzureSql/Tests/Smoke-AzureSqlImport.ps1 -Manifest Src/Data/AzureSql/PowerShell/Data_AzureSql.psd1` | 0 | Foundation and packaged AzureSql imported; SqlClient 6.1.7 loaded from the artifact; native SNI, connection builder, `Resolve-Data_AzureSql`, and `Construct` passed. |
| `pwsh -NoProfile -File Src/Data/AzureSql/Tests/Smoke-AzureSqlLazyResolution.ps1` | 0 | AzureSql began unloaded; the production jacket loader registered the selected `sdadev01` / `SDAWorkItems` jacket; first `Data.FusionDatabase` mapped invocation loaded the packaged manifest, called `Resolve-Data_AzureSql`, and constructed the adapter with the hydrated jacket. The offline execution boundary substituted SQL execution only after module resolution. |

The focused guard test, seven adapter suites, five Foundation mapped-adapter/plan-execution regressions, isolated package checks, direct mapped routing, prior full live-operation run with `VerifiedEmpty` cleanup, and the new `DirectDefinition` fixture probe all have applicable passing evidence for this source, artifact, configuration, and PowerShell 7.6.6 deployment host. Every listed plan completion criterion is **verified for the chosen deployment target**. The earlier deployment-unverified statements below are historical and superseded by this section. PowerShell 7.4 remains an **unverified advertised compatibility minimum**; it is not the selected deployment version and no 7.4 result is claimed.

## 2026-09-25 direct fixture verification and current verdict

From the adapter repository root, with `SDA_AZURESQL_LIVE_SERVER=sda-dev.database.windows.net`, `SDA_AZURESQL_LIVE_DATABASE=sda-fusion`, and `SDA_AZURESQL_LIVE_SCHEMA=test_sda_azure_sql_it_adapter` scoped to the launching shell, `pwsh -NoProfile -File Src/Data/AzureSql/Tests/Launch-AzureSqlLiveIntegration.ps1 -FixtureProbe` exited **0**. The launcher started its fresh PowerShell child with AzureSql initially unloaded. The read-only run ID was `afd453a3-666b-4772-8a0f-8dfbc69a7ac7`; its recovery record ended `Stage=complete`, `Result=Passed`, `Cleanup=NotNeeded`. No SQL mutation or fixture provisioning was performed in this run.

The probe reported five matching columns, three matching procedure parameters, **zero triggers**, `definition_visible=True`, fixture SELECT/DELETE/EXECUTE rights, no fixture ALTER right, no `db_owner`, `db_datawriter`, or `db_ddladmin` membership, and zero other visible writable tables. `AzureSqlFixtureGuard.ps1` compared the actual object-scoped procedure definition to the reviewed template and reported **`Verified:DirectDefinition`**, reviewed definition SHA-256 `28575327480A8C5AABC07AF62C78E3FDAE67DA71745B47A8AA566D64A7ECABD3`. The reviewed definition contains exactly two writes, both `INSERT INTO [test_sda_azure_sql_it_adapter].[AzureSqlAdapterFixture]`, and both preserve the supplied `@RunId`; it contains no additional mutating statement. This closes the P2 fixture-verification finding for the probed object and identity. The earlier exit 77 and open-finding statement below remain historical results, superseded by this direct verification.

The probe recovery record reports packaged artifact SHA-256 `394116E47D6596A5763F94F0FDE39FCA6F39BF2753D20F7997EB4512ECE3C502`, configuration SHA-256 `5AB94F24231BF6299EB258580FFFDA6DA8B4C6568842BC76754B04FB39569589`, and PowerShell 7.6.6. These match the prior successful live-operation record, run ID `bec8b154-38e2-4e81-b326-3e5b7416d49a`, whose `Result=Passed` and `Cleanup=VerifiedEmpty` were confirmed again from its recovery record. The current configuration file hash also matches. No adapter, package, reviewed fixture template, or guard changes preceded this probe; the prior offline adapter and Foundation regression, package and separate fresh-process loading, focused guard, and live-operation evidence remain applicable within their recorded local host/runtime scopes. No mutation rerun was warranted.

The module manifest and README specify a **Windows x64 PowerShell 7.4+ / .NET 8+ compatibility target**, but the examined adapter plan, package, SDAFusion configuration, and local launch scripts do not identify the intended deployment host or its installed PowerShell version. Local PowerShell 7.6.6 checks do not establish deployment validation or the advertised 7.4 minimum. Packaged import and production lazy resolution on the deployment host remain **unverified**; overall completion is pending that evidence.

## 2026-09-24 current fixture-review remediation

The prior fixture preflight used keywords and `create_date = modify_date` to infer that the procedure was reviewed. That inference was insufficient. The current `AzureSqlFixtureGuard.ps1` extracts the exact reviewed procedure from `Provision-AzureSqlLiveFixture.template.sql`, checks that its two `INSERT` targets are only `[test_sda_azure_sql_it_adapter].[AzureSqlAdapterFixture]` and that both branches preserve `@RunId`, and compares the current database definition to those bytes after line-ending normalization. The reviewed procedure SHA-256 is `28575327480A8C5AABC07AF62C78E3FDAE67DA71745B47A8AA566D64A7ECABD3`. If the definition is hidden, owner evidence must match the configured server/database/schema, current object ID and creation/modification metadata, and reviewed definition SHA-256. The `-CaptureEvidence` mode of `Provision-AzureSqlLiveFixture.ps1` can produce this record read-only under the provisioning owner's identity after it compares the actual definition. Without such evidence the preflight exits 77 before mutation. Object timestamps serve only to bind owner evidence to the current object; equality of timestamps is not treated as review proof. Column, parameter, trigger, and effective-permission checks remain.

| Affected check | Result |
|---|---|
| `pwsh -NoProfile -File Src/Data/AzureSql/Tests/Test-AzureSqlFixtureGuard.ps1` | Exit 0: shared real preflight accepts reviewed definition, rejects an additional unrelated-table `INSERT` in the live definition or reviewed template, stops with no definition/evidence, accepts matching synthetic owner evidence, and rejects evidence for another object. |
| `pwsh -NoProfile -File Src/Data/AzureSql/Tests/Launch-AzureSqlLiveIntegration.ps1 -FixtureProbe` with approved server/database/schema | Initial attempt exited 1 at target-validation due transient connection failure; Azure CLI session and TCP 1433 remained available. Final attempt exited **77** with five columns, three parameters, zero triggers, required fixture grants, no broad roles or other visible write rights, and `definition_visible=False`; no owner evidence was supplied. Run ID `f96df173-0367-4fd3-9ace-861df5c00597`, cleanup `NotNeeded`. No mutation occurred. |

The current procedure definition has **not** been obtained through object-scoped metadata access or a provisioning-owner attestation tied to the current object. Its write targets and lack of unrelated side effects therefore remain unverified for the current database object, and the P2 fixture-review finding remains open. The prior successful live run `bec8b154-38e2-4e81-b326-3e5b7416d49a` remains applicable to unchanged adapter execution behavior and its verified RunId cleanup, but it does not satisfy the corrected fixture guard. Production adapter and package files are unchanged; prior offline suites, fresh-process loading checks, package test, and live-operation results are reused within those scopes. Deployment host/runtime remains unverified pending an identified target.

## 2026-09-24 update: direct passwordless production jacket

The current `sdadev01` / `SDAWorkItems` jacket has `Resource=sda-fusion` and one `Addresses` entry, `sda-dev.database.windows.net`. This uncommitted Content configuration edit was supplied by the user; the other Content working-tree edits are unrelated. Adapter HEAD is `9f1ecd4`, Foundation HEAD is `4d8428d`, and Content HEAD is `88e2ac8`. The adapter working tree now changes connection construction, the matching tests, live harness assertion, README, and implementation plan. The earlier snapshot below describes a previous repository state and is not evidence for these changed files.

The current adapter accepts this direct form with `Active Directory Default`, encryption, and certificate validation. It also retains the protected connection-resource form. The production loader still hydrates the selected jacket before `Construct`. Current `Open-AzureSqlConnection.ps1` SHA-256 is `8F0C526A6A41809081966667EE43D8739017AD142A8893EC7999D2D2B15E62AF`; the package manifest and dependency inventory SHA-256 values remain `47910DB4D496FA744300D68BF65E1249F9EB02BFE44F3A28D2AB0B7BFEF63C13` and `73CBA6A288C3A2BC8B456CE620D6F3F65602218DF9A4877F51B4118E3F29A2B4`. Current config SHA-256 is `5AB94F24231BF6299EB258580FFFDA6DA8B4C6568842BC76754B04FB39569589`. The read-only probe recorded package artifact identity `65CB52E1D3B927490DFEBCA2EEC5BF0CEB9E50575E8D950E95088390ADFF6BD8`. These hashes identify the present files or probe artifact; they do not retroactively prove earlier run inputs.

| Check | Result |
|---|---|
| `pwsh -NoProfile -File Src/Data/AzureSql/Tests/Run-PromptHChecks.ps1` | Exit 0 on PowerShell 7.6.6 / win-x64: seven adapter suites, distinct explicit-import and production lazy-resolution fresh processes, and five Foundation regressions passed. Gated live suite exited 77. |
| Focused `Data_AzureSql.LoaderHydration.Tests.ps1` and `Smoke-AzureSqlLazyResolution.ps1` in fresh processes with temporary SignalGraph bootstrap | Exit 0 after adding a synthetic hydration marker; `Construct` received the hydrated jacket and the mapped route succeeded. |
| `Launch-AzureSqlLiveIntegration.ps1 -TargetProbe` with the named server/database | Exit 1 at `target-validation` after production lazy registration. The recovery record is `aadf8dc0-8d2c-4037-b900-87cc73d126cd.json`, run ID `aadf8dc0-8d2c-4037-b900-87cc73d126cd`, cleanup `NotNeeded`. The sanitized failure does not identify whether SQL authentication, database permission, target availability, or adapter execution caused the failure. No mutation occurred. |
| `az account show --output none`; SQL-audience token request with output suppressed; TCP port 1433 probe | Azure CLI session and SQL token acquisition available; TCP 1433 reachable. This does not establish SQL database authorization or successful SqlClient login. |
| `Launch-AzureSqlLiveIntegration.ps1` with named server/database and no readiness flags | Exit 77: no dedicated-resource approval, least-privilege identity proof, fixture/schema readiness, or live opt-in. No mutation occurred. |

The initial target failures exposed an implementation defect in `Import-AzureSqlProvider.ps1`: its PowerShell assembly-resolution callback was invoked by SqlClient on a thread without a PowerShell runspace. The callback is now compiled .NET code. After that fix, `Run-PromptHChecks.ps1` again exited 0 for all seven adapter suites, the two distinct fresh-process checks, and five Foundation regressions. A fresh `Test-AzureSqlPackage.ps1` run also passed normal provider/native loading and isolated missing managed/native dependency checks. The changed packaged artifact identity is `394116E47D6596A5763F94F0FDE39FCA6F39BF2753D20F7997EB4512ECE3C502` (the earlier identity above applies only to the pre-fix artifact).

The subsequent `Launch-AzureSqlLiveIntegration.ps1 -TargetProbe` exited 0 in its fresh process: production hydration and lazy resolution loaded the package, real SqlClient executed `SELECT DB_NAME()`, and the database and builder server/catalog matched `sda-fusion` and `sda-dev.database.windows.net`. It reported `VISIBLE_DEDICATED_SCHEMAS=` with no schema matching `sda_azure_sql_it_*` visible to this identity. Run ID `68800bd5-bcb4-45ce-852a-fb63b787cb4a`, recovery record `68800bd5-bcb4-45ce-852a-fb63b787cb4a.json`, cleanup `NotNeeded`. The probe was read-only. The earlier failure is resolved for this artifact and environment.

Database identity and authenticated read-only route are now verified. Dedicated fixture definition/permissions, isolation approval, all live mutation scenarios, and post-cleanup emptiness remain **unverified**. No fixture DDL or DML was run. PowerShell 7.4 and the intended deployment host remain unverified. Overall completion is blocked. Before live mutation, confirm an isolated `sda_azure_sql_it_*` schema, reviewed procedure/table/triggers, and an identity restricted to those objects. Do not set readiness flags based only on the supplied server and database names.

A final read-only target probe (run ID `38cc1d55-807b-4412-897f-1d4d7297587b`) also passed the production SQL route and reported no visible matching schema. `IS_ROLEMEMBER` returned `1` for each of `db_owner`, `db_datawriter`, and `db_ddladmin` for the current identity. This identity fails the live suite's least-privilege prerequisite. The suite must use a different identity whose effective rights are limited to the approved fixture. No mutation was attempted.

## 2026-09-24 update: approved test-prefixed fixture

The user approved fixture writes in `sda-fusion` on condition that the schema begin with `test`. The dedicated name is `test_sda_azure_sql_it_adapter`. The SQL template and live harness gate now use that prefix. A read-only target probe (run ID `72852e54-3829-4c27-b8c3-ef405de7432f`) found no visible matching schema before provisioning.

`pwsh -NoProfile -File Src/Data/AzureSql/Tests/Provision-AzureSqlLiveFixture.ps1` exited 0. It validated the real jacket, SqlClient server/catalog, and `DB_NAME()`, then created only the named schema, `AzureSqlAdapterFixture` table, RunId index, and `usp_IngestAzureSqlAdapterFixture` procedure in one SQL transaction. The script prints no connection string or token. Provisioning used the existing DDL-capable identity; no live scenario rows were written.

The subsequent fresh-process `Launch-AzureSqlLiveIntegration.ps1 -FixtureProbe` with `SDA_AZURESQL_LIVE_SCHEMA=test_sda_azure_sql_it_adapter` exited **77**. Its read-only inspection passed fixture columns, procedure parameters and definition, no triggers, and no external procedure dependencies. The identity gate did not pass: the current identity remains a member of `db_owner`, `db_datawriter`, and `db_ddladmin`. Run ID `ce1cb6b7-017d-49b3-8d52-5337ed0f87d6`, cleanup `NotNeeded`. The complete live scenario suite and post-cleanup emptiness are still unverified. The fixture is ready for a restricted identity to be provisioned and checked; do not set `SDA_AZURESQL_LIVE_IDENTITY_READY=1` for the current identity.

## 2026-09-24 update: restricted identity and full live run

The authenticated identity changed. A fresh read-only target probe reported `db_owner=0`, `db_datawriter=0`, and `db_ddladmin=0` and saw `test_sda_azure_sql_it_adapter`. The first fixture probe failed because the restricted identity cannot SELECT from `sys.sql_expression_dependencies` (SQL error 229). The earlier privileged provisioning probe had already inspected dependencies. The per-run query no longer requires that database-wide catalog permission. The restricted identity also lacks procedure-level VIEW DEFINITION, so the probe uses the reviewed provisioning definition and checks that the procedure's `create_date` equals `modify_date`; it still checks parameters, columns, triggers, fixture rights, broad roles, and visible rights on other tables. This avoids granting extra metadata access to the live identity.

The final fresh-process `Launch-AzureSqlLiveIntegration.ps1 -FixtureProbe` exited **0** (run ID `6f2c3fa7-0c8f-419a-b326-f2c556b790a3`). It reported five expected columns, three parameters, zero triggers, an unaltered procedure, SELECT/DELETE/EXECUTE rights, no fixture ALTER right, no broad writer or DDL roles, and zero visible other writable tables.

With the readiness flags scoped to the launcher process, `pwsh -NoProfile -File Src/Data/AzureSql/Tests/Launch-AzureSqlLiveIntegration.ps1` exited **0** in a fresh child. Run ID `bec8b154-38e2-4e81-b326-3e5b7416d49a`, artifact SHA-256 `394116E47D6596A5763F94F0FDE39FCA6F39BF2753D20F7997EB4512ECE3C502`, config SHA-256 `5AB94F24231BF6299EB258580FFFDA6DA8B4C6568842BC76754B04FB39569589`, runtime PowerShell 7.6.6 / win-x64. Production lazy resolution and genuine SqlClient covered JSON and CSV ingestion, quoted newline and empty CSV fields, nested document ingestion, multiple and empty result sets, Delete counts and remaining records, failed-mutation rollback, and JSON-only result boundaries. The recovery record ended `Stage=complete`, `Result=Passed`, `Cleanup=VerifiedEmpty`; the suite's scoped post-cleanup query found zero rows for that RunId. No connection resource, token, or payload value was printed.

The production adapter and packaged dependency files did not change after the prior full offline and package checks, so those passing checks remain applicable. Only the live harness, provisioning support, and documentation changed. PowerShell 7.4 and any separate deployment host remain unverified pending identification of the intended deployment runtime; do not claim cross-runtime or deployment completion from this local run alone.

Captured 2026-09-24 on Windows x64 with PowerShell 7.6.6. This is a working-tree snapshot, not a commit or a deployment attestation. No live readiness variables were present. `az account show --output none` reported no Azure CLI login; no Key Vault resource or operational SQL secret was retrieved.

## Source and package state

Repository heads: `SovereignTrust.Adapters` `a808ffa2b38892256036e8830b9c3bac689e84d5`; `SovereignTrust.Foundation` `f55e41b1402ba14974275741fff312a8d8921c56`; `SDAFusion-Content` `d481d0e9aa605a8ad565a94a1900512c0b831a99`.

The adapter working tree contains modified production module files (`ConvertTo-AzureSqlJsonResult.ps1`, `Data_AzureSql.ps1/.psd1/.psm1`, `Invoke-Data_AzureSql.ps1`), `README.md`, two older test files, and both implementation-plan documents. Untracked adapter files are `.gitignore`, `Package-AzureSql.ps1`, `Packaging/`, the nine new operation/provider/normalization helper scripts, and the configuration, connection/parameter, execution-boundary, loader, normalization, import, routing, package, and Prompt G/H test support under `Tests/`. This remediation added `Launch-AzureSqlLiveIntegration.ps1`, extended `Run-AzureSqlLiveIntegration.ps1`, prepared `Provision-AzureSqlLiveFixture.template.sql`, and updated the README; the adapter implementation and packaged files were not changed during this remediation.

Foundation has modified `FabCondenser.ps1` and five mapped-adapter/plan-execution test scripts from the preceding Prompt H work. Content has the modified `SDA/Config/SDAFusionApp.Json` AzureSql jacket. The other modified or untracked Content files (`Artifact*.Json`, `Set.Json`, artifact activity tests, and `Working/Artifact-Sql-*`) are unrelated workspace edits and were not used as AzureSql validation evidence.

The current `PowerShell/` artifact has 64 files. Its identity is SHA-256 over sorted lines of `relative/path SHA256(file)`, joined with LF: `D6355E08110EC01D708DAD470E577CF4EFEFFE766F337EAE3C323E7E4DA72307`.

| Current file | SHA-256 |
|---|---|
| `Data_AzureSql.psd1` | `47910DB4D496FA744300D68BF65E1249F9EB02BFE44F3A28D2AB0B7BFEF63C13` |
| `Data_AzureSql.psm1` | `EF68618CAABD2DF1A39D475F780EF9C83FD7DF467CAC8BA745015A1251FBC35F` |
| `dependencies/inventory.json` | `73CBA6A288C3A2BC8B456CE620D6F3F65602218DF9A4877F51B4118E3F29A2B4` |
| `dependencies/Microsoft.Data.SqlClient.dll` | `A0CC09B728BF31B393150A02B237454665BD9FD8E99E8F2D4AE0E69BE015236F` |
| `dependencies/Microsoft.Data.SqlClient.SNI.dll` | `4B699D5208390414848B2165F8AE442504852AFD87221169233A5D7C7BDA4FF9` |
| `SDAFusionApp.Json` | `F0630BF97910FCB7B03BE4D70B63A81FD5A6DA4484A5AD1C09ECAC97F6FAB787` |

These hashes describe the current files. They do **not** prove the exact bytes used by a test run before they were captured. Session edit history shows that subsequent changes were limited to the live harness and documentation; the offline adapter and package evidence is reused on that basis. A fresh `Test-AzureSqlPackage.ps1` run on 2026-09-24 bound current package-loading behavior to this snapshot without rebuilding it.

## Commands and results

| Command from adapter repository root | Result | Scope |
|---|---|---|
| `pwsh -NoProfile -File Src/Data/AzureSql/Tests/Run-PromptHChecks.ps1` (preceding Prompt H run) | Pass for seven adapter suites, separate explicit-import and lazy-resolution processes, and five Foundation regressions; live exit 77 | Offline behavior and fresh-process routing on PowerShell 7.6.6 |
| `pwsh -NoProfile -File Src/Data/AzureSql/Tests/Test-AzureSqlPackage.ps1` with temporary SignalGraph module path (2026-09-24) | Pass: packaged provider/native load and isolated managed/native missing-file failures | Current win-x64 package on PowerShell 7.6.6 |
| `pwsh -NoProfile -File Src/Data/AzureSql/Tests/Launch-AzureSqlLiveIntegration.ps1 -TargetProbe` (2026-09-24) | Exit 77: approved server and database unknown | No protected resource accessed |
| `pwsh -NoProfile -File Src/Data/AzureSql/Tests/Launch-AzureSqlLiveIntegration.ps1 -FixtureProbe` (2026-09-24) | Exit 77: approved target and dedicated schema unknown | No protected resource accessed |
| `pwsh -NoProfile -File Src/Data/AzureSql/Tests/Launch-AzureSqlLiveIntegration.ps1` (2026-09-24) | Exit 77: live prerequisites absent | No mutation attempted |

The launcher creates a temporary SignalGraph junction, starts a fresh `pwsh -NoProfile` child, restores `PSModulePath`, and propagates 0, 77, or failure. The read-only target probe checks production hydration, lazy module resolution, SqlClient authentication, connection-string server/catalog, and `DB_NAME()` before any mutation. The fixture probe checks schema, shape, procedure definition/dependencies, triggers, and visible effective permissions without readiness flags. These probes have not run past their gates.

No dedicated fixture DDL was found in the current checked-out repositories outside the adapter's test contract and copied design snapshots. Actual database objects remain unknown. The new SQL provisioning template has not been executed; it requires a provisioning owner and an approved dedicated target.

## Completion criteria

| Plan criterion | Evidence | Status |
|---|---|---|
| Production virtual-path resolution without manual implementation import/registration | `Smoke-AzureSqlLazyResolution.ps1` and successful live run through Fab and `Data.FusionDatabase`; 2026-09-25 fresh-process check on user-designated deployment host | Verified on PowerShell 7.6.6 deployment host |
| Real Write, Query, Delete through mapped route | `Run-AzureSqlLiveIntegration.ps1` exit 0, run ID `bec8b154-38e2-4e81-b326-3e5b7416d49a` | Verified live |
| SQL text separate from typed values | `Data_AzureSql.ConnectionParameters.Tests.ps1`, execution-boundary suite | Verified offline |
| Stored-procedure Write with normalized JSON | normalization, execution-boundary, and live suites | Verified live |
| Empty/multiple result sets with metadata | adapter, execution-boundary, and live suites | Verified live |
| Delete zero versus unknown affected count | execution-boundary suite covers unknown; live suite covers zero and one | Verified offline and live within those scopes |
| Valid JSON and no provider objects at result boundary | adapter, execution-boundary, and live suites | Verified live |
| Failed mutation rollback | execution-boundary and live suites | Verified live |
| No committed/logged secrets or tokens | direct passwordless config, synthetic sanitization tests, and reviewed live output | Verified for current config and deployment-host runs |
| Caller plan and input unchanged | normalization and adapter suites | Verified offline |
| Focused integration and existing regressions pass | prior offline/Foundation/package and live-operation checks pass; corrected fixture guard tests pass; 2026-09-25 fixture probe exits 0 with `DirectDefinition` and restricted-permission checks | Verified on PowerShell 7.6.6 deployment host |

The user designated this host and PowerShell 7.6.6 for deployment validation; the separate fresh-process checks above passed here. Target, fixture, identity, live scenarios, and cleanup have applicable passing evidence on the same host and artifact. The manifest's PowerShell 7.4 compatibility minimum has not been tested and is not claimed as verified.

## Exact working-tree status at capture

The following is `git status --short` from each repository, including this untracked evidence file.

### SovereignTrust.Adapters

```text
 M Src/Data/AzureSql/PowerShell/ConvertTo-AzureSqlJsonResult.ps1
 M Src/Data/AzureSql/PowerShell/Data_AzureSql.ps1
 M Src/Data/AzureSql/PowerShell/Data_AzureSql.psd1
 M Src/Data/AzureSql/PowerShell/Data_AzureSql.psm1
 M Src/Data/AzureSql/PowerShell/Invoke-Data_AzureSql.ps1
 M Src/Data/AzureSql/README.md
 M Src/Data/AzureSql/Tests/Data_AzureSql.Routing.Tests.ps1
 M Src/Data/AzureSql/Tests/Data_AzureSql.Tests.ps1
 M docs/AzureSql-Data-Adapter-Implementation-Plan-Prompts.md
 M docs/AzureSql-Data-Adapter-Implementation-Plan.md
?? Src/Data/AzureSql/.gitignore
?? Src/Data/AzureSql/Package-AzureSql.ps1
?? Src/Data/AzureSql/Packaging/
?? Src/Data/AzureSql/PowerShell/Add-AzureSqlParameters.ps1
?? Src/Data/AzureSql/PowerShell/Import-AzureSqlProvider.ps1
?? Src/Data/AzureSql/PowerShell/Invoke-AzureSqlDelete.ps1
?? Src/Data/AzureSql/PowerShell/Invoke-AzureSqlQuery.ps1
?? Src/Data/AzureSql/PowerShell/Invoke-AzureSqlWrite.ps1
?? Src/Data/AzureSql/PowerShell/New-AzureSqlCommand.ps1
?? Src/Data/AzureSql/PowerShell/New-AzureSqlSession.ps1
?? Src/Data/AzureSql/PowerShell/Open-AzureSqlConnection.ps1
?? Src/Data/AzureSql/PowerShell/Resolve-AzureSqlWriteInput.ps1
?? Src/Data/AzureSql/Tests/Data_AzureSql.Configuration.Tests.ps1
?? Src/Data/AzureSql/Tests/Data_AzureSql.ConnectionParameters.Tests.ps1
?? Src/Data/AzureSql/Tests/Data_AzureSql.ExecutionBoundary.Tests.ps1
?? Src/Data/AzureSql/Tests/Data_AzureSql.LoaderHydration.Tests.ps1
?? Src/Data/AzureSql/Tests/Data_AzureSql.Normalization.Tests.ps1
?? Src/Data/AzureSql/Tests/Launch-AzureSqlLiveIntegration.ps1
?? Src/Data/AzureSql/Tests/Provision-AzureSqlLiveFixture.template.sql
?? Src/Data/AzureSql/Tests/PromptH-Remediation-Evidence.md
?? Src/Data/AzureSql/Tests/Run-AzureSqlLiveIntegration.ps1
?? Src/Data/AzureSql/Tests/Run-PromptGChecks.ps1
?? Src/Data/AzureSql/Tests/Run-PromptHChecks.ps1
?? Src/Data/AzureSql/Tests/Smoke-AzureSqlImport.ps1
?? Src/Data/AzureSql/Tests/Smoke-AzureSqlLazyResolution.ps1
?? Src/Data/AzureSql/Tests/SqlClientDecimalFixture.ps1
?? Src/Data/AzureSql/Tests/Test-AzureSqlPackage.ps1
```

### SovereignTrust.Foundation

```text
 M Src/PowerShell/Classes/Adapters/Condenser/FabCondenser.ps1
 M Tests/Complete-PlanPhaseTask.Tests.ps1
 M Tests/Invoke-PlanIteration.Tests.ps1
 M Tests/LazyAdapterLoading.Tests.ps1
 M Tests/PlanCondenser.InvokePhaseAsync.Tests.ps1
 M Tests/PlanCondenser.IteratePhase.Tests.ps1
```

### SDAFusion-Content

```text
 M SDA/Config/SDAFusionApp.Json
 M SDA/SDA/Artifact.Json
 M SDA/SDA/Artifact_Enrollment.Json
 M SDA/SDA/Set.Json
?? SDA/SDA/Artifact_External.Json
?? SDA/SDA/Artifact_Images.Json
?? SDA/Tests/Test-ArtifactActivityPlans.ps1
?? SDA/Tests/Test-PublishImageEligibility.ps1
?? Working/Artifact-Sql-Design/
?? Working/Artifact-Sql-Ingestion-Plan.md
```
