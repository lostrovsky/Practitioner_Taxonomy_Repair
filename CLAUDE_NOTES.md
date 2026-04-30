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
                          │  - Read claims-source taxonomies from cpe_master │
                          │  - For each NPI: NPPESClient.lookupNpi(npi)      │
                          │  - Combine + apply NPPES primary -> is_primary=1 │
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
| `cpe_repair.practitioner_repair` | One row per (batch, practitioner). `entity_id` IDENTITY -- the post-call SQL target. Carries `practitioner_hcc_id` (used in SOAP) and `npi` (for ops audit). |
| `cpe_repair.practitioner_taxonomy` | One row per (entity, taxonomy). FK to `practitioner_repair`. Carries the NPPES-corrected `is_primary` flag. |
| `cpe_repair.fn_get_practitioner_taxonomy_repair_for_batch_id(@batch_id)` | TVF the loader queries. Returns one row per (practitioner, "other" taxonomy) plus scalar primary/secondary slots -- same row shape as `cpe_load.fn_get_practitioner_amends_for_run_id` so the loader's existing template engine handles it. |
| `cpe_repair.sp_mark_practitioner_repair_loaded(@entity_id, @success, @error_message)` | Post-call SQL target. Mirrors `cpe_load.sp_mark_entity_loaded` shape. |

DDL lives at `sql/create_cpe_repair_objects.sql`. Idempotent (`IF NOT EXISTS` on schema and tables; `CREATE OR ALTER` on TVF and proc).

## Layout

```
Practitioner_Taxonomy_Repair/
├── pom.xml
├── PractitionerTaxonomyRepair.properties      (template, ships with YOUR_* placeholder DB creds)
├── CLAUDE.md, CLAUDE_NOTES.md, TODO.md, README.md
├── .claude/settings.local.json
├── .gitignore
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
java -jar practitioner-taxonomy-repair-1.0.0-jar-with-dependencies.jar \
    [--log-output=both|file|console] \
    [--properties-file=<path>] \
    [--npi-file=<path>] \
    [--description=<text>] \
    [--dry-run]
```

- `--npi-file=<path>`: text file, one NPI per line; lines starting with `#` are comments. If omitted, defaults to "all practitioners with at least one NPPES-source taxonomy in `cpe_master.practitioner_taxonomy`."
- `--dry-run`: do everything except the final INSERTs. Logs what would be staged. Useful before committing a large batch.
- `--description`: stored on `cpe_repair.batch.description` for audit.

## Operator flow

```bash
# 1. Stage the corrections
java -jar practitioner-taxonomy-repair-1.0.0-jar-with-dependencies.jar
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

## State at Time of Notes

Initial scaffold complete. DDL applied to dev DB. Smoke tested end-to-end against NPI 1003008574 in LOG_ONLY mode. Repository is its own GitHub repo. Not yet run against a real-data batch in production.
