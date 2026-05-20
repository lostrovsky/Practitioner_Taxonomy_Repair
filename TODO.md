# TODO

## Blocking before first production run

- [ ] **Get HRP-correct `<maintenanceReasonCode>` values** for a taxonomy-overlay amend. Currently the template mirrors `PractitionerCreateReason / 1` from the existing amend call type, which is wrong for a non-create operation. Update `<codeSetName>` and `<codeEntry>` in `calls/practitioner_taxonomy_repair/practitioner_taxonomy_repair.properties` once known.
- [ ] **Verify `<updateMode>REPLACE</updateMode>` semantics in HRP.** Should replace the practitioner's full taxonomy list with what we send. If HRP actually treats it as `MERGE` (i.e., adds without removing), the overlay won't fix bugs where the wrong primary needs to be demoted. Test on a single practitioner in dev first.
- [ ] **Decide affected-practitioner scope.** Default behavior (no `--npi-file` flag) processes every practitioner in cpe_master with at least one `NPPES`-source taxonomy. Confirm that's the right set, or scope it tighter. Two override mechanisms:
  - `--npi-file=<path>` — explicit list, one NPI per line (`#` for comments).
  - `db.npi_query` in `PractitionerTaxonomyRepair.properties` — custom SELECT returning one column of NPIs, applied verbatim. Useful for a load_run / bug-window filter without writing the list to a file first. `--npi-file` always wins over `db.npi_query`.

## Production setup

> **Recommended path** (since v1.1.0): download the release zip from
> https://github.com/lostrovsky/Practitioner_Taxonomy_Repair/releases, extract
> it, fill the three `db.*` lines in `PractitionerTaxonomyRepair.properties`,
> then:
>
>     .\install.ps1 -LoaderInstallPath <existing install>\Claim_Provider_Data_Loader
>
> That one command applies the DDL, copies the call folder, and finishes the
> setup. The manual steps below remain as the fallback / detailed reference
> (and are still needed if you're building from source instead of using the
> release zip).

- [ ] **Apply DDL to production DB:** `sqlcmd -S <server> -d <db> -U <user> -P <pwd> -i sql/create_cpe_repair_objects.sql`. Idempotent; safe to re-run.
- [ ] **Build the jar on the deploy machine** (only if not using the release zip): `mvn clean package -DskipTests`. Requires `claim-provider-data-extractor:1.0.0` in local m2 (run `mvn install -DskipTests` from that project first).
- [ ] **Fill in real DB credentials** in `PractitionerTaxonomyRepair.properties` (in the extracted release dir, or `target/` if building from source; or pass `--properties-file=<path>` to point at a different config).
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

## Done

- [x] DDL: `cpe_repair` schema, `batch` / `practitioner_repair` / `practitioner_taxonomy` tables, TVF, post-call sp — all idempotent
- [x] Java tool: NPI list (file or auto-derive), `NPPESClient` per NPI, combines with claims-source from `cpe_master`, name lookup from `cpe_xref.taxonomy`, INSERTs into `cpe_repair.*`, `--dry-run` mode
- [x] Call folder `calls/practitioner_taxonomy_repair/`: properties (DB query, WS endpoint, taxonomy-only template), sql.json (post-call), report.json
- [x] Verified end-to-end against NPI 1003008574 in LOG_ONLY mode — SOAP renders correctly, post-call SQL targets the right entity_id
- [x] Verified isolation: no writes to `cpe.*`, `cpe_load.*`, or `cpe_master.*`; `cpe_load.load_run` sequence not consumed
- [x] Pushed to GitHub: https://github.com/lostrovsky/Practitioner_Taxonomy_Repair
- [x] Automated installer `deploy/install.ps1`. Reads DB connection from `PractitionerTaxonomyRepair.properties` (parses `db.url`/`db.user`/`db.password`; CLI params optional and override per-field; only `-LoaderInstallPath` mandatory). Applies DDL, configures, copies call folder. Idempotent and upgrade-safe per Mindful File Replacement doctrine (properties file untouched unless explicitly overriding placeholders or `-Force`; call folder backed up before `-Force` replace). `-WhatIf`/`-Force`/`-SkipDdl`/`-SqlcmdPath`/`-DbPort`. Wired into `build_package.ps1` (staged at zip root); INSTALL.txt updated with a quick-install section.
- [x] **v1.0.0 GitHub Release** (2026-05-01, commit `b7c60bc`) — initial release with jar, DDL, call folder, `build_package.ps1`, `INSTALL.txt`. No installer; manual setup only. https://github.com/lostrovsky/Practitioner_Taxonomy_Repair/releases/tag/v1.0.0
- [x] **v1.1.0 GitHub Release** (2026-05-19, commit `72a94c6`) — adds `install.ps1`; hardens `build_package.ps1` packaging with `ZipFile::CreateFromDirectory` + post-zip manifest check after a `Compress-Archive`/Windows-Defender race silently dropped a file in the first build attempt. Java code unchanged (jar still 1.0.0). https://github.com/lostrovsky/Practitioner_Taxonomy_Repair/releases/tag/v1.1.0
- [x] **v1.2.0 GitHub Release** (2026-05-20, commit `242dec0`, marked Latest) — adds `db.npi_query` (operator-configurable verbatim SELECT for the auto-derive NPI scope; `--npi-file` still wins). Bumps pom to 1.2.0 — first honest artifact version (jar in zip is now `practitioner-taxonomy-repair-1.2.0-jar-with-dependencies.jar`). `build_package.ps1` jar path made version-agnostic (glob). https://github.com/lostrovsky/Practitioner_Taxonomy_Repair/releases/tag/v1.2.0
