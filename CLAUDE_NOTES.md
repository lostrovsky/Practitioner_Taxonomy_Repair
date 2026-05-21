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
                          │  - Look up taxonomy_name in cpe_xref.taxonomy    │
                          │  - INSERT into cpe_repair.* (own schema, own     │
                          │    batch_id sequence, never touches cpe_load)    │
                          └──────────────────────────┬───────────────────────┘
                                                     │ batch_id printed
                                                     ▼
                          ┌──────────────────────────────────────────────────┐
                          │ Operator runs:                                   │
                          │ java -jar generic-hrp-ws-call.jar               │
                          │      practitioner_taxonomy_repair                │
                          │      --RUN_ID=<batch_id>                         │
                          │      --env-file=<env.properties>                 │
                          └──────────────────────────┬───────────────────────┘
                                                     │
                          ┌──────────────────────────▼───────────────────────┐
                          │ Loader queries TVF:                              │
                          │   cpe_repair.fn_get_practitioner_taxonomy_       │
                          │   repair_for_batch_id(@batch_id)                 │
                          │ Renders taxonomy-only amend SOAP, sends to HRP   │
                          │ Post-call SQL:                                   │
                          │   cpe_repair.sp_mark_practitioner_repair_loaded  │
                          └──────────────────────────────────────────────────┘
```

## Database objects (cpe_repair schema)

| Object | Purpose |
|---|---|
| `cpe_repair.batch` | One row per repair invocation. `batch_id` IDENTITY. |
| `cpe_repair.practitioner_repair` | One row per (batch, NPI considered). `entity_id` IDENTITY -- the post-call SQL target for `status='pending'` rows the loader sends. Carries `practitioner_hcc_id` (used in SOAP) and `npi` (for ops audit). `status` is one of `pending`/`loaded`/`failed`/`skipped`; `skipped` rows are recorded for the audit trail but the TVF filters them out so the loader never picks them up. For `skipped` rows, `error_message` holds the decision reason ("master already matches NPPES..."). |
| `cpe_repair.practitioner_taxonomy` | One row per (entity, taxonomy). FK to `practitioner_repair`. Carries the NPPES-corrected `is_primary` flag. |
| `cpe_repair.fn_get_practitioner_taxonomy_repair_for_batch_id(@batch_id)` | TVF the loader queries. Returns one row per (practitioner, "other" taxonomy) plus scalar primary/secondary slots -- same row shape as `cpe_load.fn_get_practitioner_amends_for_run_id` so the loader's existing template engine handles it. Filters `status NOT IN ('loaded','skipped')` so resume is free and `skipped` rows are never sent to HRP. |
| `cpe_repair.sp_mark_practitioner_repair_loaded(@entity_id, @success, @error_message)` | Post-call SQL target. Mirrors `cpe_load.sp_mark_entity_loaded` shape. |

DDL lives at `sql/create_cpe_repair_objects.sql`. Idempotent (`IF NOT EXISTS` on schema and tables; `CREATE OR ALTER` on TVF and proc).

## Layout

```
Practitioner_Taxonomy_Repair/
├── pom.xml
├── PractitionerTaxonomyRepair.properties      (DEV ONLY: local working tree skip-worktree'd with real creds;
│                                                git HEAD has placeholders; NOT shipped in zip since v1.4.0
│                                                -- install.ps1 generates it from install.config)
├── run_repair.ps1                              (orchestrator: stages via jar, captures BATCH_ID, invokes loader;
│                                                mirrors pipeline's run_pipeline.ps1; ships in zip; install.ps1
│                                                copies into the repair install dir with $SQLCMD substituted)
├── CLAUDE.md, CLAUDE_NOTES.md, TODO.md, README.md
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
java -jar practitioner-taxonomy-repair-1.3.0-jar-with-dependencies.jar \
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
- `--dry-run`: do everything except the final INSERTs. Logs what would be staged. Useful before committing a large batch.
- `--description`: stored on `cpe_repair.batch.description` for audit.

## Operator flow

```bash
# 1. Stage the corrections
java -jar practitioner-taxonomy-repair-1.3.0-jar-with-dependencies.jar
   -> Repair batch 7 staged. Run the loader with --RUN_ID=7
   -> BATCH_ID=7

# 2. Push amends (LOG_ONLY=true to verify SOAP first)
java -jar generic-hrp-ws-call.jar practitioner_taxonomy_repair \
     --RUN_ID=7 --LOG_ONLY=true \
     --env-file=<install>/Claim_Provider_Data_Pipeline/env.properties

# 3. Once verified, push for real
java -jar generic-hrp-ws-call.jar practitioner_taxonomy_repair \
     --RUN_ID=7 \
     --env-file=<install>/Claim_Provider_Data_Pipeline/env.properties

# 4. Verify in cpe_repair
SELECT status, COUNT(*) FROM cpe_repair.practitioner_repair WHERE batch_id = 7 GROUP BY status;
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
- **Own batch_id sequence** in `cpe_repair.batch`. Does not consume `cpe_load.load_run.run_id`.
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
1. Concurrency lock (`repair.lock`), transcript log (`repair_<ts>.log`), prior-log
   archive-to-`logs/`.
2. Validate prerequisites (jar via glob in script dir; loader jar at
   `..\Claim_Provider_Data_Loader\generic-hrp-ws-call.jar`; env.properties;
   call folder; sqlcmd; -NpiFile path; -BatchId numeric).
3. Parse env.properties for DB_URL/USER/PASSWORD + LOG_ONLY; live DB
   connectivity check with hint-tagged failure messages (expired, login
   failed, server unreachable, db not found).
4. **STEP 2: stage** -- `java -jar <repair jar> [--npi-file=...] [--description=...] [--dry-run]`.
   Captures `BATCH_ID=<n>` from stdout. Handles `--dry-run` (exits with summary,
   no loader call) and the "nothing to amend" success-no-op case (jar exits 0
   without emitting BATCH_ID).
5. **STEP 3: load** -- `java -jar generic-hrp-ws-call.jar practitioner_taxonomy_repair
   --RUN_ID=<batch> --env-file=...\env.properties`. Honors LOG_ONLY from
   env.properties; `-LogOnlyOverride` switch passes `--LOG_ONLY=true` for one run.
   Loader failure prints a `.\run_repair.ps1 -BatchId <n>` resume hint.
6. Resume mode (`-BatchId <n>`) skips Step 2 and re-invokes the loader against
   an existing batch. TVF filter (`status NOT IN ('loaded','skipped')`) means
   already-completed rows complete instantly.
7. End-of-run summary lines (batch_id, elapsed, log file path, per-status
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
| `v1.4.0` (Latest) | 2026-05-21 | TBD | `practitioner_taxonomy_repair_v1.4.0.zip` (jar still `1.3.0` — Java unchanged) | **Install + orchestration redesigned to mirror the daily pipeline.** New `run_repair.ps1` orchestrator (concurrency lock, transcript log, env.properties parse, DB check, stage → capture BATCH_ID → loader; `-BatchId` resume mode). New `install.config` single-source-of-truth template; `install.ps1` rewritten pipeline-style (prompts for installation directory, creates `<base>\Practitioner_Taxonomy_Repair\` sibling, generates `env.properties` + `PractitionerTaxonomyRepair.properties` from install.config, copies call folder to loader, optional DDL apply). The v1.1.0-v1.3.0 `-LoaderInstallPath` CLI flow is gone; `PractitionerTaxonomyRepair.properties` no longer shipped (generated by installer). Pom stays 1.3.0 (no Java change). |

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

Release `v1.4.0` shipped 2026-05-21 (marked Latest) -- install + orchestration redesigned to mirror the daily pipeline pattern. Pipeline-style `install.config` + interactive `install.ps1` create a `Practitioner_Taxonomy_Repair\` sibling folder next to the existing extractor/loader, with its own `env.properties` and a `run_repair.ps1` orchestrator (same shape as `run_pipeline.ps1`) that handles both the stage step and the loader call. Pom stays 1.3.0 -- no Java change; the diff-and-skip behavior shipped in v1.3.0 is unchanged. v1.0.0-v1.3.0 remain published and unchanged. DDL applied to dev DB only. **Not yet smoke-tested with a real install.** Next step is to install into a dev environment and exercise `run_repair.ps1` end-to-end against a deliberately-mismatched NPI (still need one where master shows a v1.4.0-buggy primary to exercise the stage-an-amend branch). The three blockers in TODO.md remain: HRP-correct `<maintenanceReasonCode>`, verifying `<updateMode>REPLACE</updateMode>` semantics, and affected-practitioner scope (de-risked since v1.3.0).
