# Practitioner Taxonomy Repair

One-off remediation tool for practitioners loaded with the wrong primary taxonomy by [Claim_Provider_Data_Extractor](https://github.com/lostrovsky/Claim_Provider_Data_Pipeline) versions before v1.4.1.

**Latest release:** [v1.6.6](https://github.com/lostrovsky/Practitioner_Taxonomy_Repair/releases/latest) -- batches every `IN (...)` lookup so the tool works at full population size. Previously any NPI list over ~2,100 died on SQL Server's parameter ceiling (`The incoming request has too many parameters`), which is what a 17,841-NPI UAT run hit. (v1.6.5 reduced the safety controls to one knob per axis; v1.6.4 fixed a critical bug where `$HrpCallsLogMode = $true` did not actually suppress HRP calls -- **v1.6.3 must not be used**; v1.6.2 made dry-run the default; v1.6.0 added fail-fast on unresolved primary, `sp_finalize_repair_run`, CHECK constraints, and JUnit tests.)

The bug wiped the NPPES `is_primary` marker before the create-ranking CTE could use it, so practitioners with NPPES-source taxonomies got an arbitrary primary in HRP instead of the NPPES-marked one. v1.4.1 fixed the extractor going forward but did not retroactively fix already-loaded practitioners. This tool does that.

## How it works

For each NPI in the input list:

1. **Re-fetch NPPES live** via the same `NPPESClient` the extractor uses (imported as a Maven dependency, never modified). Skip the NPI if NPPES doesn't know it or returns no taxonomies.
2. **Diff against `cpe_master`** — load all of the practitioner's taxonomies (any source) and check whether master *already contains* NPPES's codes AND master's `is_primary=1` code matches NPPES's primary code.
3. **If same**, record a `status='skipped'` row in `cpe_repair.practitioner_repair` (for audit) and move on. The loader will not pick it up — no SOAP amend is sent.
4. **If different**, stage a merged taxonomy list in a new isolated `cpe_repair` schema:
   - Primary = NPPES's primary code
   - Secondary = the first non-primary code in NPPES's list (if any; NPPES itself has no secondary marker — this is the tool's convention)
   - Others = remaining NPPES codes + master codes NPPES doesn't return, deduped
5. The bundled call folder `practitioner_taxonomy_repair/` is run via the existing `Generic_HRP_WS_Call` loader to push the taxonomy-only amend to HRP — only for practitioners staged in step 4.

## Footprint

- Reads (read-only): `cpe_master.practitioner`, `cpe_master.practitioner_taxonomy`, `[HRDW_REPLICA].[PAYOR_DW].[PROVIDER_TAXONOMY]` (same taxonomy-name source the daily pipeline's `sp_resolve_taxonomy_names` uses; overridable via `db.taxonomy.lookup.*` properties)
- Writes: `cpe_repair.repair_run`, `cpe_repair.practitioner_repair`, `cpe_repair.practitioner_taxonomy` only
- Does **not** modify any code in sibling projects (`Claim_Provider_Data_Extractor`, `Generic_HRP_WS_Call`, `Claim_Provider_Data_Pipeline`)
- Does **not** consume a `cpe_load.load_run.run_id`. Uses its own `cpe_repair.repair_run.run_id` IDENTITY sequence (same column name, different schema — schema isolation prevents PK collision).

## Quick start

This is an add-on to your existing Claim Provider Data Pipeline install. It creates a `Practitioner_Taxonomy_Repair\` sibling folder next to your existing `Claim_Provider_Data_Extractor\` / `Claim_Provider_Data_Loader\`, with its own `env.properties` and a `run_repair.ps1` orchestrator script (same pattern as `run_pipeline.ps1`).

### Install

1. Download the latest release zip from the [releases page](https://github.com/lostrovsky/Practitioner_Taxonomy_Repair/releases/latest) and extract it to a **temporary** directory (not on top of your existing install) -- e.g., `C:\temp\ptr_v1.6.6\`.
2. Open `install.config` in the extracted folder and fill in the values: `DB_URL`, `DB_USER`, `DB_PASSWORD`, `WS_BASE_URL`, `CONNECTOR_ADMIN_PASSWORD`, `LOG_ONLY`, `SQLCMD_PATH`. (Most can be copy-pasted from your daily pipeline's `env.properties`.)
3. Run the installer:

   ```powershell
   cd C:\temp\ptr_v1.6.6
   .\install.ps1
   ```

   It prompts for your installation directory -- give the SAME base folder that already contains `Claim_Provider_Data_Extractor\` and `Claim_Provider_Data_Loader\`. The installer creates `<base>\Practitioner_Taxonomy_Repair\`, generates `env.properties` + `PractitionerTaxonomyRepair.properties` from your `install.config`, drops the new call folder into the loader, and optionally applies the DDL.

See bundled `INSTALL.txt` for the full reference.

### Run

**Two safety knobs, both safe by default (since v1.6.3).** They live in the `param()` block at the top of `run_repair.ps1` and are meant to be *edited there*, not passed on the command line:

```powershell
[switch]$DryRun = $true,           # $true = stage nothing, never invoke the loader
[switch]$HrpCallsLogMode = $true   # $true = log SOAP envelopes, never call HRP
```

A bare `.\run_repair.ps1` therefore writes nothing and calls nothing. Work through the phases by editing the two knobs:

| Phase | `$DryRun` | `$HrpCallsLogMode` | `env.properties` | Effect |
|---|---|---|---|---|
| 1 -- dry run | `$true` | `$true` | -- | NPPES diff only; no writes, no calls |
| 2 -- stage only | `$false` | `$true` | `LOG_ONLY=true` | rows staged `pending`; envelopes logged |
| 3 -- send | `$false` | `$false` | `LOG_ONLY=false` | amends sent; rows marked `loaded` |

Set `$NpiFile` for a pilot list, or `$RunId` to resume an existing run in phase 3.

**HRP calls need both gates open.** `$HrpCallsLogMode = $false` alone is not enough -- `env.properties` must also say `LOG_ONLY=false`. If they disagree, the run aborts during prerequisite validation with a message naming both files. The script can tighten safety but can never enable HRP calls on its own.

```powershell
cd <base>\Practitioner_Taxonomy_Repair
.\run_repair.ps1                      # honors whatever the param block says
.\run_repair.ps1 -NpiFile pilot.txt   # same, scoped to a pilot list
```

**Delivery is verified from the database, not the loader's exit code.** `Generic_HRP_WS_Call` exits 0 even when every SOAP call fails -- if the call throws (endpoint down, refused, TLS, DNS) it logs the error and swallows it, and its post-call SQL never runs, so rows are left `pending` with no error recorded. After a live run `run_repair.ps1` therefore re-queries `cpe_repair.practitioner_repair`; any row still `pending`/`failed` produces `Status: FAILED`, exit 1, and a resume hint. Without this, a total HRP outage reported success.

`run_repair.ps1` calls the repair jar first, captures the `RUN_ID` from its stdout, then invokes `generic-hrp-ws-call.jar practitioner_taxonomy_repair --RUN_ID=<n> --env-file=...\env.properties`. End-of-run summary prints the invocation, explicit `DB writes:` / `HRP calls:` / `HRP decided by:` statements, and per-status row counts from `cpe_repair.practitioner_repair`. Concurrency-locked; transcript log written to `repair_<timestamp>.log` next to the script.

### Restricting to specific NPIs

Two mechanisms:

**Explicit list** -- a text file, one NPI per line (`#` for comments):
```powershell
echo 1003008574 > pilot.txt
echo 1234567890 >> pilot.txt
.\run_repair.ps1 -NpiFile pilot.txt      # dry-run + log-only by default
```

**Custom SQL** -- set `NPI_QUERY` in `install.config` (re-run `install.ps1` to regenerate the properties file). The jar uses it verbatim when `--npi-file` is not passed. The practical use is scoping to the bug window: `cpe_master.practitioner_taxonomy` carries `created_time`, so no join is needed.
```
NPI_QUERY=SELECT DISTINCT npi FROM cpe_master.practitioner_taxonomy WHERE taxonomy_source='NPPES' AND created_time < '<day after the fixed build was deployed>'
```
Cut *after* the deployment day, not on it -- a build deployed mid-day still produced bad rows that morning. Over-selecting is free (matching NPIs are recorded as `skipped`); under-selecting leaves wrong primaries in HRP.

`-NpiFile` always wins over `NPI_QUERY`. When neither is set, the jar uses the built-in default (every practitioner with at least one `NPPES`-source taxonomy in `cpe_master`).

### Build from source (alternative)

If you'd rather build locally instead of using the release zip:

```bash
mvn clean package -DskipTests
sqlcmd -S <server> -d <database> -U <user> -P <pwd> -i sql/create_cpe_repair_objects.sql
```

Maven produces `target/practitioner-taxonomy-repair-*-jar-with-dependencies.jar`. Requires `claim-provider-data-extractor:1.0.0` in local m2 (run `mvn install -DskipTests` from that project first). You'll need to hand-edit a properties file and run the jar + loader yourself; the release zip's `install.ps1` / `run_repair.ps1` take care of that.

## Stack

Java 21, Maven, [ust-utils-core](https://github.com/lostrovsky/ust-utils-core) (DBManager / ConfigLoader / LoggerFactory), [Claim_Provider_Data_Extractor](https://github.com/lostrovsky/Claim_Provider_Data_Extractor) imported for `NPPESClient`, mssql-jdbc.

## See also

- `CLAUDE_NOTES.md` for full design + verification notes
- `TODO.md` for known unknowns (HRP `<maintenanceReasonCode>`, `<updateMode>` semantics)
