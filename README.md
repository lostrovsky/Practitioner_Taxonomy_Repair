# Practitioner Taxonomy Repair

One-off remediation tool for practitioners loaded with the wrong primary taxonomy by [Claim_Provider_Data_Extractor](https://github.com/lostrovsky/Claim_Provider_Data_Pipeline) versions before v1.4.1.

**Latest release:** [v1.4.0](https://github.com/lostrovsky/Practitioner_Taxonomy_Repair/releases/latest) -- mirrors the daily pipeline's install pattern (install.config + install.ps1) and adds a `run_repair.ps1` orchestrator that handles both the stage step and the loader call.

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

- Reads (read-only): `cpe_master.practitioner`, `cpe_master.practitioner_taxonomy`, `cpe_xref.taxonomy`
- Writes: `cpe_repair.batch`, `cpe_repair.practitioner_repair`, `cpe_repair.practitioner_taxonomy` only
- Does **not** modify any code in sibling projects (`Claim_Provider_Data_Extractor`, `Generic_HRP_WS_Call`, `Claim_Provider_Data_Pipeline`)
- Does **not** consume a `cpe_load.load_run.run_id`. Uses its own `cpe_repair.batch.batch_id` IDENTITY sequence.

## Quick start

This is an add-on to your existing Claim Provider Data Pipeline install. It creates a `Practitioner_Taxonomy_Repair\` sibling folder next to your existing `Claim_Provider_Data_Extractor\` / `Claim_Provider_Data_Loader\`, with its own `env.properties` and a `run_repair.ps1` orchestrator script (same pattern as `run_pipeline.ps1`).

### Install

1. Download the latest release zip from the [releases page](https://github.com/lostrovsky/Practitioner_Taxonomy_Repair/releases/latest) and extract it to a **temporary** directory (not on top of your existing install) -- e.g., `C:\temp\ptr_v1.4.0\`.
2. Open `install.config` in the extracted folder and fill in the values: `DB_URL`, `DB_USER`, `DB_PASSWORD`, `WS_BASE_URL`, `CONNECTOR_ADMIN_PASSWORD`, `LOG_ONLY`, `SQLCMD_PATH`. (Most can be copy-pasted from your daily pipeline's `env.properties`.)
3. Run the installer:

   ```powershell
   cd C:\temp\ptr_v1.4.0
   .\install.ps1
   ```

   It prompts for your installation directory -- give the SAME base folder that already contains `Claim_Provider_Data_Extractor\` and `Claim_Provider_Data_Loader\`. The installer creates `<base>\Practitioner_Taxonomy_Repair\`, generates `env.properties` + `PractitionerTaxonomyRepair.properties` from your `install.config`, drops the new call folder into the loader, and optionally applies the DDL.

See bundled `INSTALL.txt` for the full reference.

### Run

```powershell
cd <base>\Practitioner_Taxonomy_Repair

# Dry-run a pilot (no DB writes, no loader call)
.\run_repair.ps1 -NpiFile pilot.txt -DryRun

# Stage + load. Loader honors LOG_ONLY from env.properties (verify SOAP first).
.\run_repair.ps1 -NpiFile pilot.txt

# Full batch (auto-derive NPI list; honors db.npi_query if set in install.config)
.\run_repair.ps1 -Description "Production repair batch"

# Resume a previous batch (re-invoke loader only; TVF skips already-loaded/skipped rows)
.\run_repair.ps1 -BatchId 7
```

`run_repair.ps1` calls the repair jar first, captures the `BATCH_ID` from its stdout, then invokes `generic-hrp-ws-call.jar practitioner_taxonomy_repair --RUN_ID=<batch> --env-file=...\env.properties`. End-of-run summary prints per-status row counts from `cpe_repair.practitioner_repair`. Concurrency-locked; transcript log written to `repair_<timestamp>.log` next to the script.

### Restricting to specific NPIs

Two mechanisms:

**Explicit list** -- a text file, one NPI per line (`#` for comments):
```powershell
echo 1003008574 > pilot.txt
echo 1234567890 >> pilot.txt
.\run_repair.ps1 -NpiFile pilot.txt -DryRun
```

**Custom SQL** -- set `NPI_QUERY` in `install.config` (re-run `install.ps1` to regenerate the properties file). The jar uses it verbatim when `--npi-file` is not passed; useful for a `cpe_load.load_run` bug-window filter. Example:
```
NPI_QUERY=SELECT DISTINCT pt.npi FROM cpe_master.practitioner_taxonomy pt JOIN cpe_load.<...> lr ON ... WHERE pt.taxonomy_source='NPPES' AND lr.run_date BETWEEN '<start>' AND '<end>'
```

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
