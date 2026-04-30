# TODO

## Blocking before first production run

- [ ] **Get HRP-correct `<maintenanceReasonCode>` values** for a taxonomy-overlay amend. Currently the template mirrors `PractitionerCreateReason / 1` from the existing amend call type, which is wrong for a non-create operation. Update `<codeSetName>` and `<codeEntry>` in `calls/practitioner_taxonomy_repair/practitioner_taxonomy_repair.properties` once known.
- [ ] **Verify `<updateMode>REPLACE</updateMode>` semantics in HRP.** Should replace the practitioner's full taxonomy list with what we send. If HRP actually treats it as `MERGE` (i.e., adds without removing), the overlay won't fix bugs where the wrong primary needs to be demoted. Test on a single practitioner in dev first.
- [ ] **Decide affected-practitioner scope.** Default behavior (no `--npi-file` flag) processes every practitioner in cpe_master with at least one `NPPES`-source taxonomy. Confirm that's the right set, or build an NPI list (e.g., load_run date filter) for a tighter scope.

## Production setup

- [ ] **Apply DDL to production DB:** `sqlcmd -S <server> -d <db> -U <user> -P <pwd> -i sql/create_cpe_repair_objects.sql`. Idempotent; safe to re-run.
- [ ] **Build the jar on the deploy machine:** `mvn clean package -DskipTests`. Requires `claim-provider-data-extractor:1.0.0` in local m2 (run `mvn install -DskipTests` from that project first).
- [ ] **Fill in real DB credentials** in `target/PractitionerTaxonomyRepair.properties` (or pass `--properties-file=<path>` to point at a different config).
- [ ] **Copy the call folder** `calls/practitioner_taxonomy_repair/` onto your loader install at `<install>/Claim_Provider_Data_Loader/practitioner_taxonomy_repair/`.

## First production run

- [ ] **Dry-run sanity check:** `java -jar ... --dry-run`. Confirms NPI count and that NPPES is reachable. No DB writes.
- [ ] **Stage a small pilot batch first:** pick 2–3 known-affected NPIs, run with `--npi-file=pilot.txt`. Verify rows in `cpe_repair.practitioner_repair` and `cpe_repair.practitioner_taxonomy`.
- [ ] **Run loader in LOG_ONLY mode** against the pilot batch_id: `... practitioner_taxonomy_repair --RUN_ID=<n> --LOG_ONLY=true`. Inspect the SOAP envelopes in the log. Confirm correct primary, no fields beyond hcc_id + taxonomies.
- [ ] **Run loader for real** against the pilot batch (drop `--LOG_ONLY=true`). Verify HRP-side: the corrected practitioners now show the right primary in HRP UI/API. `cpe_repair.practitioner_repair.status = 'loaded'` for the pilot rows.
- [ ] **If pilot succeeds, stage the full batch** (no `--npi-file`) and run the loader.

## Post-run verification

- [ ] **Verify all rows loaded:** `SELECT status, COUNT(*) FROM cpe_repair.practitioner_repair WHERE batch_id = <n> GROUP BY status` — should be all `loaded`. Investigate any `failed` rows via `error_message`.
- [ ] **Spot-check HRP** against 5–10 random repaired practitioners — confirm primary taxonomy matches NPPES live.
- [ ] **Document the run** in CLAUDE_NOTES.md "State at Time of Notes" section (batch_id, count, date, any anomalies).

## Future enhancements (nice-to-have, not blocking)

- [ ] **Resume mode:** if a batch partially loaded, allow re-running the loader to pick up only `pending` / `failed` rows. The TVF already filters on `status <> 'loaded'`, so resume is essentially free — just verify behavior end-to-end.
- [ ] **Concurrency for NPPES lookups.** Currently sequential. For a large batch (1000+ NPIs at ~500ms each = 8+ minutes), parallel HTTP calls would be a meaningful speedup. NPPES has rate limits — keep it modest (e.g., 5 concurrent).
- [ ] **Local cache for `cpe_xref.taxonomy` lookups** if running multiple batches back-to-back. Currently fresh DB query per run.
- [ ] **Diff/compare mode:** show what would change in HRP vs current `cpe_master` state without staging or pushing. Useful before committing a large batch.
- [ ] **Release zip + GitHub Release** once the tool is proven on prod data. Mirror the build_package.ps1 pattern from `Claim_Provider_Data_Pipeline`. For now this stays source-only since it's a one-off remediation.

## Done

- [x] DDL: `cpe_repair` schema, `batch` / `practitioner_repair` / `practitioner_taxonomy` tables, TVF, post-call sp — all idempotent
- [x] Java tool: NPI list (file or auto-derive), `NPPESClient` per NPI, combines with claims-source from `cpe_master`, name lookup from `cpe_xref.taxonomy`, INSERTs into `cpe_repair.*`, `--dry-run` mode
- [x] Call folder `calls/practitioner_taxonomy_repair/`: properties (DB query, WS endpoint, taxonomy-only template), sql.json (post-call), report.json
- [x] Verified end-to-end against NPI 1003008574 in LOG_ONLY mode — SOAP renders correctly, post-call SQL targets the right entity_id
- [x] Verified isolation: no writes to `cpe.*`, `cpe_load.*`, or `cpe_master.*`; `cpe_load.load_run` sequence not consumed
- [x] Pushed to GitHub: https://github.com/lostrovsky/Practitioner_Taxonomy_Repair
