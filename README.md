# Practitioner Taxonomy Repair

One-off remediation tool for practitioners loaded with the wrong primary taxonomy by [Claim_Provider_Data_Extractor](https://github.com/lostrovsky/Claim_Provider_Data_Pipeline) versions before v1.4.1.

The bug wiped the NPPES `is_primary` marker before the create-ranking CTE could use it, so practitioners with NPPES-source taxonomies got an arbitrary primary in HRP instead of the NPPES-marked one. v1.4.1 fixed the extractor going forward but did not retroactively fix already-loaded practitioners. This tool does that.

## How it works

1. Re-fetches NPPES live for each affected practitioner via the same `NPPESClient` the extractor uses (imported as a Maven dependency, never modified).
2. Combines the live NPPES taxonomies with the practitioner's existing `claims`-source taxonomies from `cpe_master`.
3. Stages a complete-overlay taxonomy list in a new isolated `cpe_repair` schema. NPPES's current primary marker becomes `is_primary=1`.
4. The bundled call folder `practitioner_taxonomy_repair/` is run via the existing `Generic_HRP_WS_Call` loader to push taxonomy-only amends to HRP.

## Footprint

- Reads (read-only): `cpe_master.practitioner`, `cpe_master.practitioner_taxonomy`, `cpe_xref.taxonomy`
- Writes: `cpe_repair.batch`, `cpe_repair.practitioner_repair`, `cpe_repair.practitioner_taxonomy` only
- Does **not** modify any code in sibling projects (`Claim_Provider_Data_Extractor`, `Generic_HRP_WS_Call`, `Claim_Provider_Data_Pipeline`)
- Does **not** consume a `cpe_load.load_run.run_id`. Uses its own `cpe_repair.batch.batch_id` IDENTITY sequence.

## Quick start

### One-time DB setup

```bash
sqlcmd -S <server> -d <database> -U <user> -P <pwd> -i sql/create_cpe_repair_objects.sql
```

Idempotent. Re-running is a no-op.

### One-time install

```bash
mvn clean package -DskipTests
```

Produces `target/practitioner-taxonomy-repair-1.0.0-jar-with-dependencies.jar`. Drop alongside `target/PractitionerTaxonomyRepair.properties` (auto-copied during package). Edit the properties file to fill in real `db.url` / `db.user` / `db.password`.

Copy the call folder onto your loader install:

```
calls/practitioner_taxonomy_repair/  ->  <install>/Claim_Provider_Data_Loader/practitioner_taxonomy_repair/
```

### Operator flow

```bash
# 1. Stage corrections (defaults: every practitioner with NPPES-source taxonomies)
java -jar target/practitioner-taxonomy-repair-1.0.0-jar-with-dependencies.jar
   -> BATCH_ID=7

# 2. Verify SOAP in LOG_ONLY mode
java -jar generic-hrp-ws-call.jar practitioner_taxonomy_repair \
     --RUN_ID=7 --LOG_ONLY=true \
     --env-file=<install>/Claim_Provider_Data_Pipeline/env.properties

# 3. Push for real
java -jar generic-hrp-ws-call.jar practitioner_taxonomy_repair \
     --RUN_ID=7 \
     --env-file=<install>/Claim_Provider_Data_Pipeline/env.properties
```

### Restricting to specific NPIs

```bash
echo 1003008574 > npis.txt
echo 1234567890 >> npis.txt
java -jar practitioner-taxonomy-repair-1.0.0-jar-with-dependencies.jar --npi-file=npis.txt --dry-run
```

`--dry-run` does everything except the final INSERTs and logs what would be staged. Use it before committing a large batch.

## Stack

Java 21, Maven, [ust-utils-core](https://github.com/lostrovsky/ust-utils-core) (DBManager / ConfigLoader / LoggerFactory), [Claim_Provider_Data_Extractor](https://github.com/lostrovsky/Claim_Provider_Data_Extractor) imported for `NPPESClient`, mssql-jdbc.

## See also

- `CLAUDE_NOTES.md` for full design + verification notes
- `TODO.md` for known unknowns (HRP `<maintenanceReasonCode>`, `<updateMode>` semantics)
