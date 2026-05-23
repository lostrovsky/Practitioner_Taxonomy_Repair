# End-to-End Practitioner Taxonomy Repair Regression Test

Manual smoke test that exercises the four interesting code paths in v1.3.0+
(diff-and-skip) under v1.4.0+ (install + run_repair.ps1 orchestration):

1. **Install** — install.config -> generated env.properties + PractitionerTaxonomyRepair.properties; call folder copied to loader; DDL idempotent re-apply
2. **Skip path** — every NPI in the pilot already matches NPPES; repair jar records status='skipped'; loader sees 0 rows from the TVF
3. **Stage-amend path** — at least one NPI differs (master.is_primary on the wrong code); repair jar stages a pending row; loader renders the SOAP envelope (LOG_ONLY) or sends it (real)
4. **Restoration** — any temporary cpe_master mutations used to force a mismatch are reversed cleanly; verified by re-running repair against the same NPI and seeing it skip again

No `run_regression.ps1` for this project -- a one-off remediation tool doesn't
justify the script. Procedure below is short enough to run by hand in ~5 min.

## Prerequisites

- SQL Server running on localhost; `INTEGRATION_PLUS_DB` populated by the daily
  pipeline (so `cpe_master.practitioner_taxonomy` has NPPES-source rows and
  `[HRDW_REPLICA].[PAYOR_DW].[PROVIDER_TAXONOMY]` is accessible to the
  test DB user -- this is the canonical taxonomy code->name source the
  daily pipeline uses; the repair tool queries it for SOAP `<codeName>`
  display names).
- `generic-hrp-ws-call.jar` built locally at
  `~/VSCode_Projects/Generic_HRP_WS_Call/target/generic-hrp-ws-call-1.0.0-jar-with-dependencies.jar`
  (or pointing at any pre-deployed loader install).
- sqlcmd at `C:\Program Files\Microsoft SQL Server\Client SDK\ODBC\170\Tools\Binn\sqlcmd.exe`.
- NPPES API reachable from the local machine.
- A built release zip in `deploy/`. If missing:
  ```powershell
  .\deploy\build_package.ps1
  ```

## Test base layout

```
C:\Tools\PTR_smoke\
├── Claim_Provider_Data_Loader\
│   └── generic-hrp-ws-call.jar       (copied from Generic_HRP_WS_Call\target\)
└── Practitioner_Taxonomy_Repair\     (created by install.ps1)
```

This mirrors the prod-install convention (sibling folders next to the loader)
but keeps the smoke test isolated from any real pipeline install.

## Step 1: Set up the test base

```powershell
# Fresh start
Remove-Item C:\Tools\PTR_smoke,C:\Tools\PTR_smoke_extracted -Recurse -Force -ErrorAction SilentlyContinue

# Loader sibling stub
New-Item -Path C:\Tools\PTR_smoke\Claim_Provider_Data_Loader -ItemType Directory -Force
Copy-Item "$env:USERPROFILE\VSCode_Projects\Generic_HRP_WS_Call\target\generic-hrp-ws-call-1.0.0-jar-with-dependencies.jar" `
          C:\Tools\PTR_smoke\Claim_Provider_Data_Loader\generic-hrp-ws-call.jar

# Extract the release zip
Expand-Archive -Path .\deploy\practitioner_taxonomy_repair_v*.zip `
               -DestinationPath C:\Tools\PTR_smoke_extracted -Force
```

## Step 2: Edit install.config

Open `C:\Tools\PTR_smoke_extracted\install.config` and fill in:

- `DB_URL`, `DB_USER`, `DB_PASSWORD` — your local SQL Server credentials
- `WS_BASE_URL` — copy from `<pipeline-source-or-install>\env.properties`
- `CONNECTOR_ADMIN_PASSWORD` — copy from same env.properties
- `LOG_ONLY=true` — **regression test always runs LOG_ONLY**; loader logs SOAP, never calls HRP
- `SQLCMD_PATH` — default usually fine

Leave `NPI_QUERY` blank (we use `-NpiFile` instead).

## Step 3: Run install.ps1

```powershell
cd C:\Tools\PTR_smoke_extracted
.\install.ps1
# When prompted:
#   "Enter installation directory"            -> C:\Tools\PTR_smoke
#   "Apply database DDL now ... (y/N)"        -> y
```

**Expected:** exit 0; `C:\Tools\PTR_smoke\Practitioner_Taxonomy_Repair\` exists
with jar, install.ps1/config, run_repair.ps1, version.txt, env.properties,
PractitionerTaxonomyRepair.properties, sql\create_cpe_repair_objects.sql.
`C:\Tools\PTR_smoke\Claim_Provider_Data_Loader\practitioner_taxonomy_repair\`
exists with the 3 call-folder files. DDL log line: `cpe_repair objects ready.`

## Step 4: Test the skip path (5-NPI pilot)

Pick 5 NPIs with NPPES-source taxonomies from cpe_master:

```sql
SELECT TOP 5 npi FROM cpe_master.practitioner_taxonomy
WHERE taxonomy_source = 'NPPES' ORDER BY npi;
```

Write them to `C:\Tools\PTR_smoke\Practitioner_Taxonomy_Repair\pilot.txt`
(one per line).

```powershell
cd C:\Tools\PTR_smoke\Practitioner_Taxonomy_Repair
.\run_repair.ps1 -NpiFile pilot.txt -Description "regression: skip path"
```

**Expected:**

- Per-NPI log lines: `master already matches NPPES (primary=...; NPPES codes [...] all present in master) -- recording skip`
- Decision summary: `N staged for amend; 5 skipped as already-matching; ...`
- Loader log line: `Total groups: 0` (TVF correctly excludes status='skipped')
- Run summary: `Status: SUCCESS`, `Run <n> row counts by status: skipped 5`
- exit 0

Note: if the daily pipeline has been running cleanly post-v1.4.1, most/all
practitioners will already match NPPES and skip. That's the *correct* v1.3.0
behavior, but it means the skip-only path is what gets exercised on natural
data. Use Step 5 to force the stage-amend path.

## Step 5: Test the stage-amend path (inject + restore on one NPI)

This step **temporarily mutates** `cpe_master.practitioner_taxonomy` to
simulate the v1.4.0 bug (wrong `is_primary` code), runs the repair, then
restores. The tool itself is read-only on cpe_master; this is operator-side
test scaffolding.

Pick an NPI with >= 2 NPPES-source taxonomy codes; e.g. NPI 1003008574
has codes 208M00000X (NPPES primary) and 207Q00000X.

```sql
-- Snapshot
SELECT npi, taxonomy_code, is_primary, is_secondary
FROM cpe_master.practitioner_taxonomy WHERE npi='1003008574' ORDER BY taxonomy_code;

-- Inject: demote the NPPES primary, promote the wrong code
UPDATE cpe_master.practitioner_taxonomy
   SET is_primary = 0
 WHERE npi='1003008574' AND taxonomy_code='208M00000X';
UPDATE cpe_master.practitioner_taxonomy
   SET is_primary = 1
 WHERE npi='1003008574' AND taxonomy_code='207Q00000X';
```

Write a one-line pilot file and run:

```powershell
"1003008574" | Set-Content inject_test.txt
.\run_repair.ps1 -NpiFile inject_test.txt -Description "regression: inject"
```

**Expected:**

- Repair jar log: `staging amend -- primary mismatch (master=207Q00000X, NPPES=208M00000X)`
- Decision summary: `1 staged for amend; 0 skipped; ...`
- Loader log line: `Total groups: 1`
- Loader log line contains the rendered SOAP envelope with:
  - `<practitionerHccId>P10000001</practitionerHccId>`
  - `<primarySpecialty><codeName>Hospitalist Physician</codeName></primarySpecialty>` (NPPES primary 208M00000X)
  - `<secondarySpecialty><codeName>Family Medicine Physician</codeName></secondarySpecialty>` (2nd NPPES code 207Q00000X)
- Post-call SQL log line: `EXEC [cpe_repair].[sp_mark_practitioner_repair_loaded] @entity_id = <n>, @success = 1, @error_message = NULL`
  (Prepared but not executed in LOG_ONLY -- "SQL executor (dry-run)").
- Run summary: `Run <n> row counts by status: pending 1`
- exit 0

Restore and verify:

```sql
UPDATE cpe_master.practitioner_taxonomy
   SET is_primary = 1
 WHERE npi='1003008574' AND taxonomy_code='208M00000X';
UPDATE cpe_master.practitioner_taxonomy
   SET is_primary = 0
 WHERE npi='1003008574' AND taxonomy_code='207Q00000X';

-- Verify byte-identical to snapshot
SELECT npi, taxonomy_code, is_primary, is_secondary
FROM cpe_master.practitioner_taxonomy WHERE npi='1003008574' ORDER BY taxonomy_code;
```

```powershell
# Re-run repair against the same NPI; should now skip
.\run_repair.ps1 -NpiFile inject_test.txt -Description "regression: restore verify"
# Expected: 1 skipped, 0 staged
```

If both the row-state query AND the verify-rerun confirm restoration, the
inject is clean.

## Step 6: (Optional) Resume mode

After Step 5's inject run produced a `pending` row, re-run the loader against
that same batch:

```powershell
# Replace <n> with the run_id from Step 5
.\run_repair.ps1 -RunId <n>
```

**Expected:** STEP 2 skipped (resume banner printed); STEP 3 runs the loader
again; loader log shows `Total groups: 0` *if you already restored cpe_master
before running this* (because the inject batch's row is still status='pending'
but... wait, the post-call SQL marked it loaded? Only if LOG_ONLY=false.)
For LOG_ONLY=true, the row stays 'pending' so the TVF still returns it; the
loader will re-render the SOAP. exit 0.

## Step 7: Cleanup

```powershell
# Local install dir
Remove-Item C:\Tools\PTR_smoke,C:\Tools\PTR_smoke_extracted -Recurse -Force
```

```sql
-- Remove regression-test batches from cpe_repair (identifiable by description)
DELETE FROM cpe_repair.practitioner_taxonomy
 WHERE entity_id IN (SELECT entity_id FROM cpe_repair.practitioner_repair
                     WHERE run_id IN (SELECT run_id FROM cpe_repair.repair_run
                                        WHERE description LIKE 'regression:%'));
DELETE FROM cpe_repair.practitioner_repair
 WHERE run_id IN (SELECT run_id FROM cpe_repair.repair_run WHERE description LIKE 'regression:%');
DELETE FROM cpe_repair.repair_run WHERE description LIKE 'regression:%';
```

## Important notes

- **LOG_ONLY=true is mandatory for this regression test.** The current call
  template's `<maintenanceReasonCode>` is `PractitionerCreateReason / 1`,
  which is the wrong reason for a non-create amend (long-standing TODO).
  Running with LOG_ONLY=false against a real HRP risks either a 4xx rejection
  or accepted-with-wrong-metadata. Until that's fixed, regression stays in
  LOG_ONLY.
- **The 5-NPI skip pilot may legitimately produce 5/5 skipped** if the daily
  pipeline has re-loaded everyone post-v1.4.1. That's expected; Step 5's
  inject is the one that actually exercises the stage-amend path.
- **TVF filter** (`status NOT IN ('loaded','skipped')`) is what makes the
  skip path safe: skipped rows are recorded for audit but never picked up by
  the loader. Verified by Step 4's `Total groups: 0` line even though 5 rows
  exist for the batch.
- **Concurrency lock** (`repair.lock` next to run_repair.ps1) is created and
  removed automatically. If a prior run crashed, manually delete the lock
  file before retrying.
- **Transcript log** for each run: `repair_<yyyymmddHHmmss>.log`. Prior runs
  archived to `logs/` subfolder automatically on next startup.
