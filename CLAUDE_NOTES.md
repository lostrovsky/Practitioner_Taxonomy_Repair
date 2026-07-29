# Claude Session Notes - Practitioner Taxonomy Repair

## Project Overview

Standalone remediation tool. Re-fetches NPPES taxonomies for practitioners that were loaded before the v1.4.1 extractor fix and pushes complete-overlay amends to HRP via a dedicated call type. Out-of-band -- not part of `run_pipeline.ps1`.

## Why this exists

`Claim_Provider_Data_Extractor` v1.4.0 had a bug where a pre-rank reset wiped the NPPES `is_primary` marker before the practitioner-create-ranking CTE could use it. Practitioners loaded during the bug window have wrong primary taxonomy in HRP. v1.4.1 fixed the extractor going forward, but already-loaded practitioners stay wrong unless we amend them.

Verified test case from v1.4.1: NPI 1003008574 -- post-fix, Hospitalist (208M00000X) is correctly primary over Family Medicine (207Q00000X).

## Stack

- Java 21, Maven
- Reuses `NPPESClient` from `claim-provider-data-extractor.jar` (Maven dep, never modified)
- ust-utils-core (DBManager, ConfigLoader, LoggerFactory)
- mssql-jdbc

## Data flow

```
                          ┌──────────────────────────────────────────────────┐
                          │ NPI list (from --npi-file or auto-derived from   │
                          │ cpe_master.practitioner_taxonomy WHERE source =  │
                          │ 'NPPES')                                         │
                          └──────────────────────────┬───────────────────────┘
                                                     │
                          ┌──────────────────────────▼───────────────────────┐
                          │ PractitionerTaxonomyRepair (this jar)            │
                          │  - For each NPI: NPPESClient.lookupNpi(npi)      │
                          │  - Load ALL master taxonomies for NPI (any src)  │
                          │  - DIFF: if master codes ⊇ NPPES codes AND       │
                          │    master is_primary code == NPPES primary code  │
                          │    -> record skip (status='skipped'), no amend   │
                          │  - ELSE merge (dedup; NPPES primary wins;        │
                          │    secondary = 2nd NPPES code if any)            │
                          │  - Look up taxonomy_name in                      │
                          │    [HRDW_REPLICA].[PAYOR_DW].[PROVIDER_TAXONOMY] │
                          │    (same source pipeline's sp_resolve uses)      │
                          │  - INSERT into cpe_repair.* (own schema, own     │
                          │    run_id IDENTITY, never touches cpe_load)      │
                          └──────────────────────────┬───────────────────────┘
                                                     │ RUN_ID printed
                                                     ▼
                          ┌──────────────────────────────────────────────────┐
                          │ Orchestrator (run_repair.ps1) runs:              │
                          │ java -jar generic-hrp-ws-call.jar               │
                          │      practitioner_taxonomy_repair                │
                          │      --RUN_ID=<run_id>                           │
                          │      --env-file=<env.properties>                 │
                          └──────────────────────────┬───────────────────────┘
                                                     │
                          ┌──────────────────────────▼───────────────────────┐
                          │ Loader queries TVF:                              │
                          │   cpe_repair.fn_get_practitioner_taxonomy_       │
                          │   repair_for_run_id(@run_id)                     │
                          │ Renders taxonomy-only amend SOAP, sends to HRP   │
                          │ Post-call SQL:                                   │
                          │   cpe_repair.sp_mark_practitioner_repair_loaded  │
                          └──────────────────────────────────────────────────┘
```

## Database objects (cpe_repair schema)

| Object | Purpose |
|---|---|
| `cpe_repair.repair_run` | One row per repair invocation. `run_id` IDENTITY. Mirrors `cpe_load.load_run` shape and name; the column name matches across schemas (PK collision impossible because different schemas). |
| `cpe_repair.practitioner_repair` | One row per (run, NPI considered). `entity_id` IDENTITY -- the post-call SQL target for `status='pending'` rows the loader sends. Carries `practitioner_hcc_id` (used in SOAP) and `npi` (for ops audit). `status` is one of `pending`/`loaded`/`failed`/`skipped`; `skipped` rows are recorded for the audit trail but the TVF filters them out so the loader never picks them up. For `skipped` rows, `error_message` holds the decision reason ("master already matches NPPES..."). |
| `cpe_repair.practitioner_taxonomy` | One row per (entity, taxonomy). FK to `practitioner_repair`. Carries the NPPES-corrected `is_primary` flag. |
| `cpe_repair.fn_get_practitioner_taxonomy_repair_for_run_id(@run_id)` | TVF the loader queries. Returns one row per (practitioner, "other" taxonomy) plus scalar primary/secondary slots -- same row shape as `cpe_load.fn_get_practitioner_amends_for_run_id` so the loader's existing template engine handles it. Filters `status NOT IN ('loaded','skipped')` so resume is free and `skipped` rows are never sent to HRP. |
| `cpe_repair.sp_mark_practitioner_repair_loaded(@entity_id, @success, @error_message)` | Post-call SQL target. Mirrors `cpe_load.sp_mark_entity_loaded` shape. |

DDL lives at `sql/create_cpe_repair_objects.sql`. Idempotent (`IF NOT EXISTS` on schema and tables; `CREATE OR ALTER` on TVF and proc). Includes an embedded v1.x migration that drops the old `cpe_repair.batch` table and `fn_get_..._for_batch_id` TVF if present, so re-running the DDL on a pre-v1.5 install rebuilds under the new run_id naming.

## Layout

```
Practitioner_Taxonomy_Repair/
├── pom.xml
├── PractitionerTaxonomyRepair.properties      (DEV ONLY: local working tree skip-worktree'd with real creds;
│                                                git HEAD has placeholders; NOT shipped in zip since v1.4.0
│                                                -- install.ps1 generates it from install.config)
├── run_repair.ps1                              (orchestrator: stages via jar, captures RUN_ID, invokes loader;
│                                                mirrors pipeline's run_pipeline.ps1; ships in zip; install.ps1
│                                                copies into the repair install dir with $SQLCMD substituted)
├── CLAUDE.md, CLAUDE_NOTES.md, TODO.md, README.md
├── REGRESSION_TEST.md                          (manual smoke-test runbook --
│                                                install, skip path, stage-amend
│                                                via cpe_master inject + restore;
│                                                always LOG_ONLY=true)
├── .claude/settings.local.json
├── .gitignore
├── deploy/
│   ├── build_package.ps1                       (build machine: produces the release zip)
│   ├── install.ps1                             (pipeline-style installer; reads install.config sibling)
│   ├── install.config                          (operator-edited template; values feed env.properties +
│   │                                            PractitionerTaxonomyRepair.properties generation)
│   └── INSTALL.txt                             (manual runbook; bundled into the zip)
├── sql/
│   └── create_cpe_repair_objects.sql           (idempotent; run once per environment)
├── calls/
│   └── practitioner_taxonomy_repair/
│       ├── practitioner_taxonomy_repair.properties      (loader config: TVF query, WS endpoint, taxonomy-only template)
│       ├── practitioner_taxonomy_repair.sql.json        (post-call SQL → cpe_repair.sp_mark_practitioner_repair_loaded)
│       └── practitioner_taxonomy_repair.report.json     (CSV report column mappings)
├── src/main/java/com/ust/utils/
│   └── PractitionerTaxonomyRepair.java         (main class)
└── target/                                     (gitignored)
```

## CLI

```bash
java -jar practitioner-taxonomy-repair-1.6.5-jar-with-dependencies.jar \
    [--log-output=both|file|console] \
    [--properties-file=<path>] \
    [--npi-file=<path>] \
    [--description=<text>] \
    [--dry-run]
```

- `--npi-file=<path>`: text file, one NPI per line; lines starting with `#` are comments. If omitted, the tool runs the auto-derive query.
- **Auto-derive query** (used when `--npi-file` is not passed):
  - Default: `SELECT DISTINCT npi FROM <db.master.schema>.practitioner_taxonomy WHERE taxonomy_source = 'NPPES'`.
  - Override: set `db.npi_query` in `PractitionerTaxonomyRepair.properties` to a `SELECT` returning one column of NPIs. Used verbatim (no schema substitution). Intended for a `cpe_load.load_run` bug-window filter so the operator doesn't have to materialize the list to a file first. `--npi-file` always wins over `db.npi_query`.
  - Whichever query is used is logged on every run (first 500 chars; truncated if longer).
- `--dry-run`: do everything except the final INSERTs. Logs what would be staged. Useful before committing a large run.
- `--description`: stored on `cpe_repair.repair_run.description` for audit.

## Operator flow

```bash
# 0. Dry-run first -- this is the DEFAULT since v1.6.2; writes nothing.
.\run_repair.ps1 -NpiFile pilot.txt
   -> Diff computed, staged/skipped counts logged, no run_id, no loader call.

# 1. Stage the corrections for real (-Execute is required)
.\run_repair.ps1 -NpiFile pilot.txt -Execute
   -> Repair run 7 staged. Loader invoked with --RUN_ID=7.

# Or run jar + loader directly (the orchestrator does this for you):
java -jar practitioner-taxonomy-repair-*-jar-with-dependencies.jar
   -> RUN_ID=7
java -jar generic-hrp-ws-call.jar practitioner_taxonomy_repair --RUN_ID=7 --env-file=<dir>/env.properties

# Verify in cpe_repair
SELECT status, COUNT(*) FROM cpe_repair.practitioner_repair WHERE run_id = 7 GROUP BY status;
```

## Decision policy (per NPI, since v1.3.0)

Each NPI in the input list goes through this decision tree exactly once:

1. **Not in `cpe_master.practitioner`** -> log warning, skip (no `cpe_repair` row written; `notInMaster` counter).
2. **NPPES not found / no taxonomies / no primary marker** -> log warning, skip (no `cpe_repair` row written; `nppesNotFound` counter).
3. **Match** (master codes ⊇ NPPES codes AND master's `is_primary=1` code == NPPES's primary code) -> record `status='skipped'` row in `practitioner_repair` with a reason in `error_message`. No taxonomy rows. The loader never picks it up (TVF filter).
4. **Mismatch** -> stage an amend:
   - **Primary** = NPPES primary code
   - **Secondary** = the first non-primary code in NPPES's list (NPPES has no native secondary marker; this is our convention)
   - **Others** = remaining NPPES codes + all master codes not already covered, deduped
   - Status `pending`; the loader will send the SOAP amend.

Match check rationale:
- The whole set must be present in master (not just primary) so that if NPPES knows a code master doesn't have, we still push the new code to HRP.
- Master's primary code must equal NPPES's primary code (this is the v1.4.0-bug case the tool exists to fix).
- Master can have codes NPPES doesn't have. That's "same" for our purposes -- we have no signal NPPES wants those codes removed, and the daily pipeline will re-derive master from claims+NPPES anyway.

End-of-run summary line: `N staged for amend; M skipped as already-matching; X NPPES-not-found; Y not-in-master (total N+M+X+Y considered)`.

## Constraints (load-bearing)

- **No code modifications** to any other project. `Claim_Provider_Data_Extractor` is imported via Maven; `Generic_HRP_WS_Call` is invoked unchanged; `Claim_Provider_Data_Pipeline` is not touched at all.
- **Read-only on `cpe_master.*`** — for `practitioner_hcc_id` lookup and `claims`-source taxonomy preservation.
- **No writes to `cpe.*` or `cpe_load.*`.**
- **Own `run_id` IDENTITY sequence** in `cpe_repair.repair_run`. Does not consume `cpe_load.load_run.run_id` -- different schema, so PK collision is impossible even though the column name matches.
- **NPPES live re-fetch** is the source of truth for "what's primary." We do not preserve any historical NPPES marker in `cpe_master`.

## Verified end-to-end (2026-04-30)

Against v1.4.1 verification case NPI 1003008574 (which `cpe_master` already shows correctly post-fix):

```
java -jar practitioner-taxonomy-repair-1.0.0-jar-with-dependencies.jar --npi-file=test.txt
  -> BATCH_ID=1 (1 practitioner, 2 taxonomy rows in cpe_repair)

java -jar generic-hrp-ws-call.jar practitioner_taxonomy_repair --RUN_ID=1 --LOG_ONLY=true ...
  -> SOAP rendered correctly:
       <practitionerHccId>P10000001</practitionerHccId>
       <primarySpecialty><codeName>Hospitalist Physician</codeName></primarySpecialty>
       <specialties>
         <updateMode>REPLACE</updateMode>
         <specialty><codeName>Family Medicine Physician</codeName></specialty>
       </specialties>
  -> Post-call SQL: EXEC cpe_repair.sp_mark_practitioner_repair_loaded @entity_id=1, @success=1
```

Sanity-checked after run: `cpe_load.load_run` latest run_id unchanged; `cpe_master.practitioner_taxonomy` for 1003008574 byte-identical to before; only writes were to `cpe_repair.*`.

## Known unknowns (operator decisions)

- **`<maintenanceReasonCode>`** in the call folder template is still `PractitionerCreateReason / 1` (mirrored from existing amend template). HRP-correct amend reason for a taxonomy overlay is a long-standing TODO carried over from the Pipeline project. Adjust in `calls/practitioner_taxonomy_repair/practitioner_taxonomy_repair.properties` once those values are known.
- **`<updateMode>REPLACE</updateMode>`** in the `<specialties>` block enforces complete-overlay semantics. The existing daily-pipeline `practitioner_amends` uses `MERGE`. Verify HRP behavior matches expectations.

## Installer + Orchestrator (since v1.4.0)

Pipeline-style install mirroring `Claim_Provider_Data_Pipeline\deploy\install.ps1`.
Single source of truth for install-time configuration is `install.config`; the
operator edits that once, then `install.ps1` generates every per-component
config file from it. No CLI param explosion.

**`install.config`** (sibling of `install.ps1` in the release zip) holds:
`DB_URL`, `DB_USER`, `DB_PASSWORD`, `WS_BASE_URL`, `CONNECTOR_ADMIN_PASSWORD`,
`LOG_ONLY`, `WS_RETRY_*`, `SQLCMD_PATH`, optional `NPI_QUERY`, optional
schema overrides. Trimmed from the pipeline's install.config -- no
`EMAIL_*`/`SMTP_*`/`AUTO_RESUME_FAILED` (out of scope for a one-off
remediation tool); no `INTEGRATION_PASSWORD` (this call type uses
`connector_admin` only).

**`install.ps1`** (interactive: prompts for installation directory and DDL y/N):
1. Reads + validates `install.config` (sibling).
2. Verifies `<base>\Claim_Provider_Data_Loader\` exists (add-on, not stand-alone).
3. Prompts `y/N` if `<base>\Practitioner_Taxonomy_Repair\` already exists.
4. Creates the repair sibling folder.
5. Copies: jar (glob-discovered, version-agnostic), `install.ps1` self, `install.config` self,
   `version.txt`, `sql\create_cpe_repair_objects.sql`.
6. Copies `run_repair.ps1` with `$SQLCMD = "..."` line regex-substituted from
   `SQLCMD_PATH` (same pattern as pipeline's `run_pipeline.ps1` substitution).
7. **Generates `env.properties`** from `install.config` (DB_URL/USER/PASSWORD,
   WS_BASE_URL, CONNECTOR_ADMIN_PASSWORD, LOG_ONLY, WS_RETRY_*). This is the
   file the loader consumes via `--env-file` at run time; the call folder's
   `${...}` references resolve against it.
8. **Generates `PractitionerTaxonomyRepair.properties`** from `install.config`
   (concrete `db.url`/`db.user`/`db.password`; schema defaults or overrides;
   `db.npi_query` only if NPI_QUERY is set). This is the file the repair jar
   reads directly; no `${...}` substitution.
9. Copies the call folder to `<base>\Claim_Provider_Data_Loader\practitioner_taxonomy_repair\`,
   backing up any existing one to a timestamped `.bak.<ts>` sibling first.
10. Optional DDL apply (y/N prompt; uses sqlcmd from `SQLCMD_PATH`).

**`run_repair.ps1`** (lives in the installed repair folder; mirrors
`run_pipeline.ps1` structure):
0. **Dry-run is the default (since v1.6.2).** `[switch]$DryRun = $true`; a real
   run requires `-Execute` (or the literal `-DryRun:$false`). Passing both
   `-Execute` and `-DryRun` is a hard error rather than a silent pick. The
   guard applies to resume mode too -- `-RunId <n>` without `-Execute`
   verifies the run exists, then stops before the loader, because resume
   re-sends real SOAP amends. A `PSAvoidDefaultValueSwitchParameter`
   suppression with justification sits above the param block; the deviation
   from PowerShell convention is deliberate (safe state is the default state).
1. Concurrency lock (`repair.lock`), transcript log (`repair_<ts>.log`), prior-log
   archive-to-`logs/`. The transcript records the reconstructed invocation
   (`Invocation: .\run_repair.ps1 -NpiFile pilot.txt -Execute`) at STEP 1 and
   in the RUN SUMMARY, plus explicit `DB writes:` / `HRP calls:` lines.
   Rebuilt from `$PSBoundParameters`, never `$MyInvocation.Line` -- the latter
   returns the caller's whole command line and would leak a secret from
   something like `$env:SQLCMDPASSWORD='...'; .\run_repair.ps1`.
2. Validate prerequisites (jar via glob in script dir; loader jar at
   `..\Claim_Provider_Data_Loader\generic-hrp-ws-call.jar`; env.properties;
   call folder; sqlcmd; -NpiFile path; -RunId numeric).
3. Parse env.properties for DB_URL/USER/PASSWORD + LOG_ONLY; live DB
   connectivity check with hint-tagged failure messages (expired, login
   failed, server unreachable, db not found).
4. **STEP 2: stage** -- `java -jar <repair jar> [--npi-file=...] [--description=...] [--dry-run]`.
   Captures `RUN_ID=<n>` from stdout. Handles `--dry-run` (exits with summary,
   no loader call) and the "nothing to amend" success-no-op case (jar exits 0
   without emitting RUN_ID).
5. **STEP 3: load** -- `java -jar generic-hrp-ws-call.jar practitioner_taxonomy_repair
   --RUN_ID=<n> --env-file=...\env.properties`. Honors LOG_ONLY from
   env.properties; `-LogOnlyOverride` switch passes `--LOG_ONLY=true` for one run.
   Loader failure prints a `.\run_repair.ps1 -RunId <n>` resume hint.
6. Resume mode (`-RunId <n>`) skips Step 2 and re-invokes the loader against
   an existing run. TVF filter (`status NOT IN ('loaded','skipped')`) means
   already-completed rows complete instantly.
7. End-of-run summary lines (run_id, elapsed, log file path, per-status
   counts queried from `cpe_repair.practitioner_repair`).

**Rationale for the rewrite (v1.4.0):** the v1.1.0-v1.3.0 installer was
self-contained -- operator pre-extracted, pre-edited a properties file,
ran install.ps1 from there. That left install-location decisions to the
operator and didn't match the rest of this ecosystem. v1.4.0 mirrors the
pipeline pattern so the two tools install and run the same way.

What v1.4.0 dropped from v1.3.0:
- `-LoaderInstallPath` CLI param (the installer now derives loader path
  from the target directory it prompts for).
- Targeted-preserve logic on `PractitionerTaxonomyRepair.properties` (the
  file is now wholesale-generated from install.config every install; the
  "preserve real creds" concern is solved by NOT shipping the file in the
  zip and re-deriving it from install.config every time).
- `-WhatIf`/`-Force`/`-SkipDdl` switches (replaced by the interactive
  y/N prompts the pipeline pattern uses).

What v1.4.0 retained:
- Call folder backup-then-replace (the `<maintenanceReasonCode>` operator-edit
  case is still real and still respected -- existing call folder moved to
  `.bak.<ts>` sibling before overwrite).
- Robust self-verifying packaging in `build_package.ps1` (the v1.1.0
  Compress-Archive/Defender drop bug fix stays).

## Releases

GitHub: https://github.com/lostrovsky/Practitioner_Taxonomy_Repair/releases

| Tag | Date | Commit | Asset | Contents |
|---|---|---|---|---|
| `v1.0.0` | 2026-05-01 | `b7c60bc` | `practitioner_taxonomy_repair_v1.0.0.zip` | Initial release. Jar, DDL, call folder, `build_package.ps1` + `INSTALL.txt`. **No `install.ps1`** — install was fully manual. |
| `v1.1.0` | 2026-05-19 | `72a94c6` | `practitioner_taxonomy_repair_v1.1.0.zip` (~1.5 MB, 9 entries) | Adds `install.ps1` (properties-as-source, idempotent, upgrade-safe). Hardens `build_package.ps1` packaging (see below). Java code unchanged; jar inside the zip is still `practitioner-taxonomy-repair-1.0.0-jar-with-dependencies.jar` (pom version unchanged). |
| `v1.2.0` | 2026-05-20 | `242dec0` | `practitioner_taxonomy_repair_v1.2.0.zip` (~1.5 MB, 9 entries) | Adds **`db.npi_query`** — operator-configurable verbatim SELECT for the auto-derive path (intended for `cpe_load.load_run` bug-window scoping; `--npi-file` still wins). Bumps pom to **1.2.0** (jar inside zip is now `practitioner-taxonomy-repair-1.2.0-jar-with-dependencies.jar` — first honest artifact version). `build_package.ps1` jar path made version-agnostic (glob), so future pom bumps don't require touching the packaging script. |
| `v1.3.0` | 2026-05-21 | `8875334` | `practitioner_taxonomy_repair_v1.3.0.zip` (~1.5 MB, 9 entries, jar `1.3.0`) | **Behavior change: diff-and-skip per NPI.** Tool no longer unconditionally stages amends. Compares NPPES vs master per NPI; if `master.codes ⊇ NPPES.codes` AND `master.is_primary=1 code == NPPES.primary code`, records `status='skipped'` (with reason in `error_message`) instead of staging. Mismatch path builds merge: primary=NPPES primary; secondary = first non-primary NPPES code (tool's convention — NPPES has no native secondary); others = remaining NPPES + master-only, deduped. TVF filter widened to `status NOT IN ('loaded','skipped')`. Pom bumped to 1.3.0. The v1.4.1 verification case (NPI 1003008574) now produces a `skipped` row instead of an amend (correct under new policy). |
| `v1.4.0` | 2026-05-21 | `1cde3aa` | `practitioner_taxonomy_repair_v1.4.0.zip` (jar still `1.3.0` — Java unchanged) | **Install + orchestration redesigned to mirror the daily pipeline.** New `run_repair.ps1` orchestrator (concurrency lock, transcript log, env.properties parse, DB check, stage → capture BATCH_ID → loader; `-BatchId` resume mode). New `install.config` single-source-of-truth template; `install.ps1` rewritten pipeline-style (prompts for installation directory, creates `<base>\Practitioner_Taxonomy_Repair\` sibling, generates `env.properties` + `PractitionerTaxonomyRepair.properties` from install.config, copies call folder to loader, optional DDL apply). The v1.1.0-v1.3.0 `-LoaderInstallPath` CLI flow is gone; `PractitionerTaxonomyRepair.properties` no longer shipped (generated by installer). Pom stays 1.3.0 (no Java change). |
| `v1.5.0` | 2026-05-22 | `e908590` | `practitioner_taxonomy_repair_v1.5.0.zip` (jar `1.5.0`) | **Two corrective changes after operator feedback.** (1) **Taxonomy lookup fixed**: previously queried a fabricated `cpe_xref.taxonomy` table that doesn't exist in the daily-pipeline ecosystem; now queries `[HRDW_REPLICA].[PAYOR_DW].[PROVIDER_TAXONOMY]` (`PROVIDER_TAXONOMY_CODE` / `PROVIDER_TAXONOMY_NAME`) -- the same source the pipeline's `sp_resolve_taxonomy_names` uses. Overridable via `db.taxonomy.lookup.{table,code_column,name_column}`. `DB_XREF_SCHEMA` dropped from install.config. (2) **Vocab unified with pipeline**: `cpe_repair.batch` -> `cpe_repair.repair_run`; `batch_id` column -> `run_id` everywhere; TVF renamed to `fn_get_practitioner_taxonomy_repair_for_run_id`; Java jar stdout `BATCH_ID=<n>` -> `RUN_ID=<n>`; `run_repair.ps1 -BatchId` -> `-RunId`. DDL ships with embedded v1.x->v1.5 migration that drops the old batch table and TVF on re-apply. Pom bumped to 1.5.0. |
| `v1.6.0` | 2026-05-23 | `347180f` | `practitioner_taxonomy_repair_v1.6.0.zip` (jar `1.6.0`) | **Hardening + audit + unit tests** based on senior-dev review of v1.5.0. (1) **Fail-fast on unresolved primary**: if NPPES's primary taxonomy code doesn't resolve in PROVIDER_TAXONOMY, the practitioner is demoted to `skipped` (with reason) instead of staged -- prevents shipping a SOAP amend with no `<primarySpecialty>` tag. (2) **Dry-run does taxonomy lookup**: surfaces unresolvable codes before the real run. (3) **`sp_finalize_repair_run`** stored proc + orchestrator call after the loader exits -- aggregates practitioner_repair statuses into `repair_run.status` (`completed`/`partial`/`failed`/`pending`); previously the run-level status was always `pending`. (4) **CHECK constraints** on `practitioner_taxonomy(NOT (is_primary=1 AND is_secondary=1))` and on `repair_run.status` / `practitioner_repair.status` value sets. (5) **`taxonomy_name NOT NULL`** in practitioner_taxonomy (was nullable; fail-fast guarantees we never insert nulls now). (6) **`decide()` refactored to a pure testable static method** with 11 JUnit tests covering match / mismatch / primary-mismatch / NPPES-new-code / single-NPPES-code / master-extras / dedup / seq ordering. (7) **Drop-existing prompt** in install.ps1 + new `sql/drop_cpe_repair_objects.sql` for clean rebuilds. (8) Embedded v1.x->v1.5 migration block removed from DDL (fresh installs only; drop script handles upgrade-via-rebuild). (9) Tightened `validateQualifiedTableName` regex (`[A-Za-z0-9_ ]` inside brackets) + trust-model Javadoc. (10) Doc cleanup of remaining v1.4-era `batch` / `BATCH_ID` references. |
| `v1.6.1` | 2026-05-30 | `c8f6913` | `practitioner_taxonomy_repair_v1.6.1.zip` (jar `1.6.1`) | **Drop-script patch.** `sql/drop_cpe_repair_objects.sql` now also drops the legacy pre-v1.5 objects -- `cpe_repair.batch` (renamed to `repair_run` in v1.5) and `fn_get_practitioner_taxonomy_repair_for_batch_id` (renamed to `..._for_run_id` in v1.5) -- in FK-safe order (legacy `batch` after `practitioner_repair` so the old `batch_id` FK is gone first). Prior versions dropped only the current names, so dropping a DB last installed at v1.4.0 or earlier left those two objects orphaned and re-`create` could not transform the still-present old tables. This matters for any DB upgrading from <= v1.4.0: the `create` script's `IF OBJECT_ID(...) IS NULL` guards skip existing tables, so without a clean drop the v1.6 CHECK constraints + `taxonomy_name NOT NULL` never get applied. No Java change in behavior; pom bumped to 1.6.1 to keep the jar/zip/tag aligned. |
| `v1.6.2` | 2026-07-27 | `fab42c1` | `practitioner_taxonomy_repair_v1.6.2.zip` (jar `1.6.2`) | **Safety + auditability release for `run_repair.ps1`.** (1) **Dry-run is now the DEFAULT** -- `[switch]$DryRun = $true`. A bare `.
un_repair.ps1` stages nothing and never invokes the loader; a real run requires the new `-Execute` switch (or the literal `-DryRun:$false`). Passing both `-Execute` and `-DryRun` is a hard error rather than a silent pick. (2) **Resume mode honors the guard** -- `-RunId <n>` without `-Execute` verifies the run exists, then stops before STEP 3. Without this the new default would have been actively dangerous: the pre-existing dry-run exit lives inside the `-not $RESUME_MODE` block, so a resume would have inherited `DryRun=$true` and then fallen through to a LIVE loader call. (3) **Invocation is recorded in the transcript** -- STEP 1 and the RUN SUMMARY both print the reconstructed command line. `Start-Transcript` runs inside the script, so the operator's command line was never captured before; a finished log gave no way to tell a dry run from a real one. Rebuilt from `$PSBoundParameters`, deliberately NOT `$MyInvocation.Line` -- the latter returns the caller's entire command line and would write a secret into the transcript for `$env:SQLCMDPASSWORD='...'; .
un_repair.ps1`. (4) **Explicit `DB writes:` / `HRP calls:` lines** in the RUN SUMMARY, so the two independent flags (`-Execute` gates staging + loader; `LOG_ONLY` gates only the SOAP send) can never be confused when reading a log after the fact. Both degrade correctly when a run fails early (no `RUN_ID` -> "run ended before ..."). (5) Mode banners for all three states (dry-run / log-only / live). (6) `build_package.ps1` now stages `sql/rebuild_cpe_repair_objects.sql` (added in `ae3b5ae`) into the zip. (7) Docs updated across README / INSTALL.txt / install.ps1 hints / REGRESSION_TEST.md -- every real-run example now carries `-Execute`. No Java behavior change; pom bumped to 1.6.2 to keep jar/zip/tag aligned. |
| `v1.6.3` (SUPERSEDED -- do not use) | 2026-07-28 | `c152e4d` | `practitioner_taxonomy_repair_v1.6.3.zip` (jar `1.6.3`) | **Two symmetric safety knobs in `run_repair.ps1`, both defaulting to safe.** No Java change. (1) **`$HrpCallsLogMode` added** -- a second gate on HRP calls layered on top of `env.properties` `LOG_ONLY`, defaulting to `$true` (suppress). Live amends now require BOTH the script knob set to `$false` AND `LOG_ONLY=false`; neither file alone can put traffic on the wire. The gate is one-directional -- the script can tighten safety but can never enable HRP calls. (2) **Disagreement aborts** -- `$HrpCallsLogMode = $false` against `LOG_ONLY=true` fails during STEP 1 validation with a message naming both files, rather than silently staying safe (which reads as a broken live run) or silently going live. Fires before the jar runs, so a mismatch costs nothing. (3) **`$DryRun` reframed as the primary knob for the DB axis**, matching `$HrpCallsLogMode`: both are `[switch]`, both `$true` = safe, both meant to be edited in the `param()` block. `-Execute` and `-LogOnlyOverride` demoted to documented CLI-only aliases that can only tighten. Resolves an inconsistency from v1.6.2, where the DB axis was opted out of via a *different* parameter (`-Execute`) while the HRP axis flipped the same one. (4) **Invocation line rebuilt from EFFECTIVE values, not `$PSBoundParameters`** -- operators drive this script by editing defaults, so `$PSBoundParameters` is empty and all phases logged an identical "no parameters" line. It now reports resolved state plus a `[from command line]` / `[from script defaults]` tag, and always prints the HRP gate. (5) **`HRP decided by:`** added to the RUN SUMMARY, naming which gate made the call. (6) Docs rewritten around the two-knob phase table (README / INSTALL.txt / install.ps1 hints / REGRESSION_TEST.md); INSTALL.txt now lists the drop + rebuild SQL scripts in its layout section. Pom bumped to 1.6.3. |
| `v1.6.4` | 2026-07-28 | `f64f561` | `practitioner_taxonomy_repair_v1.6.4.zip` (jar `1.6.4`) | **Fixes a critical bug in v1.6.3 plus three others, all found by the first end-to-end local smoke test.** (1) **CRITICAL -- `$HrpCallsLogMode = $true` did not suppress HRP calls when `env.properties` said `LOG_ONLY=false`.** The loader arg was gated on `if ($LogOnlyOverride)` rather than the resolved `$LOG_ONLY`, so the script printed `LOG-ONLY MODE ACTIVE -- script tightened it` while the loader, given no flag, resolved `false` from the env file and **sent live SOAP amends**. This broke precisely the cell that made the second gate worth having. Now gated on `$LOG_ONLY`. (2) **Delivery verified from the DB, not the loader exit code.** `Generic_HRP_WS_Call` exits 0 even when every call fails -- a thrown call is logged and swallowed at its outer catch, and because the post-call SQL sits inside that same try, no error is recorded either; rows stay `pending` with NULL `error_message`. A total HRP outage therefore reported `Status: SUCCESS`. `run_repair.ps1` now re-queries `practitioner_repair` after a live run and reports `FAILED -- N row(s) undelivered` with exit 1 and a retry hint. The loader itself is untouched (this project does not modify siblings). (3) **NPI deduplication.** `readNpiFile` and the custom `db.npi_query` path both used `ArrayList`, so a repeated NPI violated `uq_repair_practitioner_run_npi` and rolled back the whole staging transaction *after* every NPPES lookup was paid for. Both now dedup via `LinkedHashSet`, preserving order and logging the count. (4) **Installer output was mangled** -- `\$DryRun` in `install.ps1` hints used a backslash, which is not a PowerShell escape, rendering `[switch]\  = \True`. Single-quoted now. (5) `DB writes:` no longer claims status updates on a resume that aborted during validation, and the success path now ends with an explicit `exit 0` instead of inheriting `$LASTEXITCODE` from the last sqlcmd (hardening -- no failure was observed from this). REGRESSION_TEST.md gains steps 5b/5c/5d covering the gate matrix, undelivered detection, and duplicate NPIs. Pom bumped to 1.6.4. |
| `v1.6.5` (Latest) | 2026-07-29 | `PENDING` | `practitioner_taxonomy_repair_v1.6.5.zip` (jar `1.6.5`) | **Removes the `-Execute` and `-LogOnlyOverride` CLI aliases.** No Java behavior change. Both were leftovers from the pre-v1.6.3 command-line workflow and had become redundant once the tool moved to edit-the-defaults: `-LogOnlyOverride` (v1.4.0) forced log-only for one run, which is exactly what `$HrpCallsLogMode = $true` already does by default, and `-Execute` (v1.6.2) existed only because `-DryRun:$false` is awkward to type. Keeping them meant two ways to express each axis -- the same inconsistency the operator flagged before v1.6.3. Removal deletes the `-Execute`/`-DryRun` contradiction check, one term from the `$LOG_ONLY` computation, and a `$LOG_ONLY_SOURCE` branch that could never fire. `run_repair.ps1` now exposes exactly one control per axis (`$DryRun`, `$HrpCallsLogMode`), and its own hint messages point at the knobs instead of the removed flags. Docs and REGRESSION_TEST.md updated (four runbook invocations lost their `-Execute`; the runbook now says to set `$DryRun = $false` in the param block). Also removed a dead `db.xref.schema` key that lingered in the local dev properties file -- the jar has not read it since v1.5.0 replaced the fabricated `cpe_xref.taxonomy` lookup. Pom bumped to 1.6.5. |

### Packaging gotcha (caught during v1.1.0 build — do not regress)

The first v1.1.0 build silently produced a broken zip **missing `install.ps1`**.
Root cause: `Compress-Archive` opens each staged file individually and races
Windows Defender's real-time scan of freshly-written `.ps1` files, throwing
`IOException` ("being used by another process") on the locked file -- but
because the error is emitted from inside the `Microsoft.PowerShell.Archive`
module, the caller's `$ErrorActionPreference='Stop'` did not promote it to
terminating, and the script printed "Package created" with the file silently
dropped.

`build_package.ps1` was hardened to:
- Use `[System.IO.Compression.ZipFile]::CreateFromDirectory` (single-shot,
  doesn't race AV the same way) with one `IOException` retry.
- Post-zip **manifest check** comparing every file under `deploy/stage/` to
  the zip's entries -- a missing file aborts the build with `Write-Error` and
  removes the bad zip.

If anyone is tempted to "simplify" back to `Compress-Archive`: don't. The
manifest check is the real safety net; the `CreateFromDirectory` swap is
just defense-in-depth against the AV race.

## State at Time of Notes

Release `v1.6.5` shipped 2026-07-29 (marked Latest). No Java behavior change. `run_repair.ps1` now exposes **exactly one control per axis**, both defaulting to safe and both set by editing the `param()` block:

```powershell
[switch]$DryRun           = $true   # $true = no DB writes
[switch]$HrpCallsLogMode  = $true   # $true = no HRP calls
```

The `-Execute` and `-LogOnlyOverride` aliases are gone. `-LogOnlyOverride` (v1.4.0) forced log-only for a single run, which `$HrpCallsLogMode = $true` now does by default -- it was pure redundancy carrying a dead branch in `$LOG_ONLY_SOURCE`. `-Execute` (v1.6.2) existed only because `-DryRun:$false` is awkward on a command line, a rationale that died when the workflow moved into the param block. Keeping either meant two ways to express one axis, which is the inconsistency that prompted the v1.6.3 redesign in the first place.

Also cleaned up a dead `db.xref.schema=cpe_xref` key that survived in the local dev properties file. The jar has not read it since v1.5.0 replaced the fabricated `cpe_xref.taxonomy` lookup with `[HRDW_REPLICA].[PAYOR_DW].[PROVIDER_TAXONOMY]`; it was never in git HEAD and the installer never generated it, but it caused real confusion when read alongside the `TAXONOMY_LOOKUP_*` overrides in install.config (which govern the *real* lookup and should be left blank).

Release `v1.6.4` shipped 2026-07-28 (marked Latest). **v1.6.3 is superseded and must not be used** -- it contained a critical bug in the very feature it added.

This release exists because the operator asked for a local end-to-end smoke test before deploying to UAT ("I don't want any surprises"). The full three-phase flow had never actually been run against a live install; only the gate logic and summary rendering had been unit-checked in isolation. The smoke test found four defects, one of them severe:

1. **`$HrpCallsLogMode = $true` did not suppress HRP calls when `env.properties` said `LOG_ONLY=false`.** The loader argument was gated on `if ($LogOnlyOverride)` instead of the resolved `$LOG_ONLY`. The script printed `LOG-ONLY MODE ACTIVE -- script tightened it` and then sent live SOAP amends. The isolated gate tests passed because they only checked the computed `$LOG_ONLY` value, never what was handed to the loader; the earlier phase test passed because it only exercised `env=true`. The lesson is narrow and worth keeping: **a safety flag must be verified at the point of effect, not at the point of decision.**
2. The loader exits 0 even when every SOAP call fails, so a total HRP outage reported `Status: SUCCESS`. Now verified from the database after a live run.
3. A duplicate NPI in an operator-maintained pilot file rolled back the entire staging transaction after all NPPES lookups had completed. Found by accident -- the first `SELECT TOP 5` used to build a pilot list returned duplicates because it was not `DISTINCT`.
4. `install.ps1` next-steps hints rendered as `[switch]\  = \True`, because backslash is not a PowerShell escape character.

**Smoke test coverage (2026-07-28, local INTEGRATION_PLUS_DB, `C:\Tools\PTR_smoke`):** install from the release zip; phase 1 dry run (5-NPI pilot, all skipped, zero DB writes confirmed by query); inject a primary mismatch on NPI 1003008574; phase 2 stage-only (RUN_ID=1, 1 pending + 4 skipped, `Total groups: 1`, SOAP rendered with Hospitalist primary / Family Medicine secondary, post-call SQL dry-run); gate mismatch abort (exit 1, lock released); all four gate combinations; phase 3 live against a dead port (`http://127.0.0.1:9`) confirming both the live attempt and the new undelivered detection; duplicate-NPI handling. `cpe_master` restored byte-identical afterward and verified, `cpe_repair` rebuilt clean, and `cpe_load.load_run` confirmed untouched.

One methodology note worth keeping: an apparent fifth defect (successful runs exiting -1) turned out to be an artifact of the test harness -- piping the child process into `Select-Object -First N` terminates the upstream pipeline, killing `powershell.exe` mid-run and leaving a truncated log plus an orphaned `repair.lock`. Re-running with full output redirected to a file showed exit 0 and no leaked lock. When smoke-testing a script that manages a lock file, never truncate its pipeline.

**UAT is still at v1.4.0** and cannot be upgraded in place -- run `sql/rebuild_cpe_repair_objects.sql` first (verified against populated pre-v1.5 schemas on 2026-07-27).

Release `v1.6.3` shipped 2026-07-28 (marked Latest) -- no Java change; `run_repair.ps1` only. The script now has **two symmetric safety knobs, both `$true` = safe**, both meant to be edited in the `param()` block rather than passed as arguments:

```powershell
[switch]$DryRun           = $true   # $true = no DB writes
[switch]$HrpCallsLogMode  = $true   # $true = no HRP calls
```

| Phase | `$DryRun` | `$HrpCallsLogMode` | `env.properties` |
|---|---|---|---|
| 1 -- dry run | `$true` | `$true` | -- |
| 2 -- stage only | `$false` | `$true` | `LOG_ONLY=true` |
| 3 -- send amends | `$false` | `$false` | `LOG_ONLY=false` |

**Live HRP calls require both the script knob and `env.properties` to agree**; a mismatch aborts during STEP 1 rather than resolving silently in either direction. The script can only ever tighten -- there is no combination in which it enables HRP calls on its own.

Origin: the operator wanted to drive the tool by editing defaults in the installed script instead of typing arguments, and wanted `env.properties` to remain the authority on HRP traffic. That surfaced two problems with v1.6.2. First, the invocation line was rebuilt from `$PSBoundParameters`, which is empty when everything comes from defaults -- so all three phases, including the live one, would have logged an identical "no parameters" line, destroying the auditability v1.6.2 had just added. It now reports effective values with a tag saying where they came from. Second, the operator noticed the axes were inconsistent: the DB axis was opted out of via a *different* parameter (`-Execute`) while the HRP axis flipped the same one. `-Execute` had been introduced purely for command-line ergonomics, a rationale that evaporated once the workflow moved into the param block; it is now a documented alias.

Note that re-running `install.ps1` replaces `run_repair.ps1` wholesale, resetting both knobs to safe. That is deliberate -- an upgrade must never inherit a half-configured live-send state -- and is called out in INSTALL.txt so operators re-apply phase settings after upgrading.

Release `v1.6.2` shipped 2026-07-27 (marked Latest) -- safety + auditability work on `run_repair.ps1`, no Java behavior change. **Dry-run is now the default**: a bare `.
un_repair.ps1` writes nothing, and every real run (including resume) needs `-Execute`. Every transcript now records the reconstructed invocation plus explicit `DB writes:` / `HRP calls:` lines.

Origin: an operator asked whether a UAT log with `LOG_ONLY=true` had written anything to the database. It had not -- but only because the run had also been given `-DryRun`, and *nothing in the log said so*. `Start-Transcript` opens inside the script, so the invocation line was never captured, and the transcript header's `Host Application` line showed a stale ISE session (`install.ps1`). The answer had to be reconstructed by reading the jar's "--dry-run set: skipping all INSERTs" message and tracing back to the only line that emits the flag. For a tool whose whole job is writing remediation rows and pushing SOAP amends, "did this write anything?" must be answerable from the log alone.

Two hazards were found while implementing it, both fixed before shipping: (a) the naive `$MyInvocation.Line` approach captures the caller's *entire* command line and would have leaked a password from `$env:SQLCMDPASSWORD='...'; .
un_repair.ps1` straight into the transcript -- reconstructing from `$PSBoundParameters` instead; (b) defaulting `-DryRun` to true would have made `-RunId <n>` resume *actively dangerous*, since the dry-run exit lives inside the `-not $RESUME_MODE` block and resume would have fallen through to a live loader call. Verified across 10 summary-rendering combinations and 7 parameter combinations.

**`sql/rebuild_cpe_repair_objects.sql` verified 2026-07-27** against the local INTEGRATION_PLUS_DB. Tested both entry states: (a) already-current v1.6 schema -> clean rebuild; (b) faithful UAT simulation -- dropped the schema, applied the real v1.4.0 DDL from `git show v1.4.0:sql/create_cpe_repair_objects.sql` (producing `batch` + `fn_..._for_batch_id`), then ran the rebuild. Repeated with the legacy tables POPULATED (1 `batch`, 2 `practitioner_repair`, 4 `practitioner_taxonomy` rows) so the FK-safe drop ordering was exercised with live foreign keys and data present. Post-state confirmed in every case: legacy objects gone, the six current objects present, 3 CHECK constraints applied, `taxonomy_name` NOT NULL (`is_nullable=0`). The script shipped in v1.6.2 had never been executed before this.

**UAT is still at v1.4.0** (pre-v1.5 schema: `cpe_repair.batch`, `fn_..._for_batch_id`). It cannot be upgraded in place -- `create_cpe_repair_objects.sql` guards every table with `IF OBJECT_ID(...) IS NULL` and silently skips the existing ones, so the v1.6 CHECK constraints and `taxonomy_name NOT NULL` never get applied. Run `sql/rebuild_cpe_repair_objects.sql` before the next UAT run.

The last UAT dry run (2026-05-22, v1.4.0, 167 NPIs from the auto-derive query) reported **13 staged for amend, 154 skipped as already-matching, 0 NPPES-not-found, 0 not-in-master** -- so the real blast radius there is 13 practitioners.

Release `v1.6.1` shipped 2026-05-30 (marked Latest) -- a one-line-fix patch on the drop script. `sql/drop_cpe_repair_objects.sql` now also removes the legacy pre-v1.5 objects (`cpe_repair.batch`, `fn_..._for_batch_id`) so a database last installed at v1.4.0 or earlier can drop + rebuild cleanly; prior versions orphaned them. Found while answering an operator question about whether a v1.4.0 production DB needs a manual drop before deploying v1.6.x (it does -- the renamed objects + the `IF OBJECT_ID IS NULL` create-guards mean an in-place `create` won't apply the v1.6 constraints). No Java change; pom bumped to 1.6.1 to keep jar/zip/tag aligned. The three TODO.md blockers are unchanged.

Release `v1.6.0` shipped 2026-05-23 -- hardening release based on the senior-dev review of v1.5.0. Fail-fast when NPPES's primary code doesn't resolve in PROVIDER_TAXONOMY (instead of silently shipping a primary-less SOAP amend); dry-run does the taxonomy lookup so config errors surface early; new `sp_finalize_repair_run` populates `repair_run.status` after the loader exits (was always `pending`); CHECK constraints on `practitioner_taxonomy(NOT (is_primary=1 AND is_secondary=1))` and both `status` columns; `taxonomy_name NOT NULL`; `decide()` extracted as a pure testable function with 11 JUnit tests; install.ps1 gains a "Drop existing cpe_repair objects first?" prompt + new `sql/drop_cpe_repair_objects.sql`; embedded v1.x->v1.5 migration block removed (fresh installs only); tightened `validateQualifiedTableName` regex; remaining v1.4-era doc references cleaned up. Pom bumped to 1.6.0. v1.0.0-v1.5.0 remain published and unchanged. The three blockers in TODO.md remain: HRP-correct `<maintenanceReasonCode>` (the agent's review noted the pipeline's `practitioner_amends` uses the same value HRP currently accepts, so this may be more symbolic than blocking), verifying `<updateMode>REPLACE</updateMode>` semantics in HRP dev, and affected-practitioner scope (de-risked since v1.3.0).

Smoke tested end-to-end against the local INTEGRATION_PLUS_DB on 2026-05-22 (re-using the [REGRESSION_TEST.md](REGRESSION_TEST.md) procedure). Tear-down → fresh install → DDL embedded migration ran cleanly ("Migrating v1.x: dropping old cpe_repair.batch / practitioner_repair / practitioner_taxonomy"; new objects created with `repair_run` / `fn_get_..._for_run_id` names). Skip-path pilot (5 NPIs, all matching): 5 skipped, RUN_ID=1 captured, loader saw `Total groups: 0`. Inject-and-restore on NPI 1003008574: primary mismatch detected (`master=207Q00000X, NPPES=208M00000X`), 1 staged, RUN_ID=2 captured, SOAP envelope rendered with `<primarySpecialty><codeName>Hospitalist</codeName></primarySpecialty>` + `<secondarySpecialty><codeName>Family Medicine</codeName></secondarySpecialty>` (note: PROVIDER_TAXONOMY uses shorter names than the cpe_xref had -- `Hospitalist` not `Hospitalist Physician` -- because that's what the daily pipeline already uses and what HRP expects). cpe_master row restored byte-identical (208M primary=1, 207Q is_secondary=1 unchanged).
