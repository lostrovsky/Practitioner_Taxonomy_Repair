# TODO

## Blocking before first production run

- [ ] **Get HRP-correct `<maintenanceReasonCode>` values** for a taxonomy-overlay amend. Currently the template mirrors `PractitionerCreateReason / 1` from the existing amend call type, which is wrong for a non-create operation. Update `<codeSetName>` and `<codeEntry>` in `calls/practitioner_taxonomy_repair/practitioner_taxonomy_repair.properties` once known.
- [ ] **Verify `<updateMode>REPLACE</updateMode>` semantics in HRP.** Should replace the practitioner's full taxonomy list with what we send. If HRP actually treats it as `MERGE` (i.e., adds without removing), the overlay won't fix bugs where the wrong primary needs to be demoted. Test on a single practitioner in dev first.
- [ ] **Decide affected-practitioner scope** (de-risked since v1.3.0 — see note). Default behavior (no `--npi-file` flag) processes every practitioner in cpe_master with at least one `NPPES`-source taxonomy. As of v1.3.0, scope is **no longer correctness-critical** because the tool diffs master vs NPPES per NPI and only stages an amend when they actually disagree — an over-broad scope just makes more NPPES API calls and produces a longer `skipped`-row audit trail, not redundant amends. Scope still affects runtime (NPPES is sequential, ~500ms/NPI) and `cpe_repair` row volume. Two override mechanisms remain:
  - `--npi-file=<path>` — explicit list, one NPI per line (`#` for comments).
  - `db.npi_query` in `PractitionerTaxonomyRepair.properties` — custom SELECT returning one column of NPIs, applied verbatim. Useful for a load_run / bug-window filter without writing the list to a file first. `--npi-file` always wins over `db.npi_query`.

## Production setup

> **Recommended path** (since v1.4.0): download the release zip from
> https://github.com/lostrovsky/Practitioner_Taxonomy_Repair/releases, extract
> it to a temp directory, fill in `install.config` (DB connection, WS URL,
> sqlcmd path), then:
>
>     .\install.ps1
>
> When prompted, point it at your existing pipeline base directory (the one
> that already contains `Claim_Provider_Data_Loader\`). The installer creates
> a `Practitioner_Taxonomy_Repair\` sibling, generates `env.properties` +
> `PractitionerTaxonomyRepair.properties` from install.config, copies the
> call folder into the loader, and optionally applies the DDL. See bundled
> `INSTALL.txt` for the full reference.
>
> The manual steps below remain as a fallback / build-from-source path.

- [ ] **Apply DDL to production DB:** `sqlcmd -S <server> -d <db> -U <user> -P <pwd> -i sql/create_cpe_repair_objects.sql`. Idempotent; safe to re-run; includes embedded v1.x → v1.5 migration.
- [ ] **Build the jar on the deploy machine** (only if not using the release zip): `mvn clean package -DskipTests`. Requires `claim-provider-data-extractor:1.0.0` in local m2 (run `mvn install -DskipTests` from that project first).
- [ ] **Generate / hand-edit** `PractitionerTaxonomyRepair.properties` with real `db.url`/`db.user`/`db.password` + optional `db.npi_query` and `db.taxonomy.lookup.*` overrides (install.ps1 generates this from install.config; only edit by hand if building from source).
- [ ] **Copy the call folder** `calls/practitioner_taxonomy_repair/` onto your loader install at `<install>/Claim_Provider_Data_Loader/practitioner_taxonomy_repair/`.

## First production run

- [ ] **Dry-run sanity check:** `java -jar ... --dry-run`. Confirms NPI count and that NPPES is reachable. No DB writes.
- [ ] **Stage a small pilot run first:** pick 2–3 known-affected NPIs, run with `.\run_repair.ps1 -NpiFile pilot.txt`. Verify rows in `cpe_repair.practitioner_repair` and `cpe_repair.practitioner_taxonomy`.
- [ ] **Run with LOG_ONLY=true** against the pilot (set in env.properties or pass `-LogOnlyOverride`). Inspect the SOAP envelopes in the loader log. Confirm correct primary, no fields beyond hcc_id + taxonomies.
- [ ] **Run for real** against the pilot (LOG_ONLY=false). Verify HRP-side: the corrected practitioners now show the right primary in HRP UI/API. `cpe_repair.practitioner_repair.status = 'loaded'` for the pilot rows.
- [ ] **If pilot succeeds, stage the full population** (no `-NpiFile`) and let `run_repair.ps1` invoke the loader for the new run_id.

## Post-run verification

- [ ] **Verify all rows loaded:** `SELECT status, COUNT(*) FROM cpe_repair.practitioner_repair WHERE run_id = <n> GROUP BY status` — should be `loaded` (sent) + `skipped` (matched master, no amend needed). Investigate any `failed` rows via `error_message`.
- [ ] **Spot-check HRP** against 5–10 random repaired practitioners — confirm primary taxonomy matches NPPES live.
- [ ] **Document the run** in CLAUDE_NOTES.md "State at Time of Notes" section (run_id, count, date, any anomalies).

## Future enhancements (nice-to-have, not blocking)

- [ ] **Resume mode** — already shipped in v1.4.0 (`run_repair.ps1 -RunId <n>` skips the stage phase and re-invokes the loader; TVF filters `status NOT IN ('loaded','skipped')`). Verify end-to-end against a real partial-loader-failure scenario.
- [ ] **Concurrency for NPPES lookups.** Currently sequential. For a large run (1000+ NPIs at ~500ms each = 8+ minutes), parallel HTTP calls would be a meaningful speedup. NPPES has rate limits — keep it modest (e.g., 5 concurrent).
- [ ] **Local cache for the taxonomy lookup** if running multiple runs back-to-back. Currently re-queries `[HRDW_REPLICA].[PAYOR_DW].[PROVIDER_TAXONOMY]` on every invocation.
- [ ] **Standalone diff-report mode** (the in-line diff was built into the staging path in v1.3.0; this would be a separate read-only report). Show what would change in HRP vs current `cpe_master` state without writing anything to `cpe_repair`. `--dry-run` partially covers this today by logging the staged-vs-skipped sample without inserting; a richer human-readable diff per practitioner is the unmet part.

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
- [x] **v1.2.0 GitHub Release** (2026-05-20, commit `242dec0`) — adds `db.npi_query` (operator-configurable verbatim SELECT for the auto-derive NPI scope; `--npi-file` still wins). Bumps pom to 1.2.0 — first honest artifact version (jar in zip is now `practitioner-taxonomy-repair-1.2.0-jar-with-dependencies.jar`). `build_package.ps1` jar path made version-agnostic (glob). https://github.com/lostrovsky/Practitioner_Taxonomy_Repair/releases/tag/v1.2.0
- [x] **v1.3.0 GitHub Release** (2026-05-21, commit `8875334`) — behavior change: per-NPI diff-and-skip. Tool no longer stages amends unconditionally; an amend is only staged when master differs from NPPES (codes or primary). Match decision: `master.codes ⊇ NPPES.codes` AND master's `is_primary=1` code equals NPPES's primary code. Mismatch merge: primary=NPPES, secondary=first non-primary NPPES, others=remaining + master-only, deduped. Skipped NPIs recorded with status='skipped' for audit; TVF filter widened. Pom bumped to 1.3.0. https://github.com/lostrovsky/Practitioner_Taxonomy_Repair/releases/tag/v1.3.0
- [x] **v1.4.0 GitHub Release** (2026-05-21, commit `1cde3aa`) — install + orchestration redesigned to mirror the daily pipeline. New `run_repair.ps1` orchestrator (concurrency lock, transcript log, env.properties parse, DB check, stage → capture BATCH_ID → loader; `-BatchId` resume mode). New `install.config` single-source-of-truth template; `install.ps1` rewritten pipeline-style (prompts for installation directory, creates `<base>\Practitioner_Taxonomy_Repair\` sibling, generates `env.properties` + `PractitionerTaxonomyRepair.properties` from install.config, copies call folder to loader, optional DDL apply). The v1.1.0-v1.3.0 `-LoaderInstallPath` CLI flow is gone; properties file no longer shipped (installer generates it). Pom stays 1.3.0 — no Java change.
- [x] **v1.5.0 GitHub Release** (2026-05-22, commit `e908590`) — corrective release after operator feedback on v1.4.0. (1) **Taxonomy lookup fix**: replaces the fabricated `cpe_xref.taxonomy` query (which doesn't exist in the daily-pipeline ecosystem and only worked locally via a manual NUCC load) with the canonical `[HRDW_REPLICA].[PAYOR_DW].[PROVIDER_TAXONOMY]` (`PROVIDER_TAXONOMY_CODE` / `PROVIDER_TAXONOMY_NAME`) — the same source `sp_resolve_taxonomy_names` uses in the pipeline. Overridable via `db.taxonomy.lookup.{table,code_column,name_column}` properties; `DB_XREF_SCHEMA` dropped from install.config. (2) **Vocab unified with pipeline**: `cpe_repair.batch` → `cpe_repair.repair_run`; `batch_id` column → `run_id`; TVF renamed `..._for_batch_id` → `..._for_run_id`; jar stdout `BATCH_ID=` → `RUN_ID=`; `run_repair.ps1 -BatchId` → `-RunId`. DDL ships with embedded v1.x → v1.5 migration that drops the old batch table and TVF on re-apply. Pom bumped to 1.5.0 (real Java behavior change). Lessons captured in global `~/.claude/CLAUDE.md` "Scaffolding new projects from sibling projects" section.
- [x] **v1.6.0 GitHub Release** (2026-05-23, marked Latest) — hardening release based on senior-dev review of v1.5.0. (1) **Fail-fast on unresolved primary**: PROVIDER_TAXONOMY lookup runs before staging is finalized; any practitioner whose NPPES primary code doesn't resolve is demoted to `skipped` (preventing a SOAP amend with no `<primarySpecialty>`). (2) **Dry-run does the lookup** so unresolvable codes surface before the real run. (3) **`sp_finalize_repair_run`** new stored proc + orchestrator post-loader call -- aggregates per-practitioner statuses into `repair_run.status` (`completed`/`partial`/`failed`/`pending`); the run-level status was previously always `pending`. (4) **Schema hardening**: CHECK constraints on both `status` columns and on `practitioner_taxonomy(NOT (is_primary=1 AND is_secondary=1))`; `taxonomy_name` flipped to NOT NULL (fail-fast guarantees the invariant). (5) **`decide()` extracted as pure testable static method** + 11 JUnit tests in `src/test/java/com/ust/utils/PractitionerTaxonomyRepairDecideTest.java` covering match / mismatch / primary-mismatch / NPPES-new-code / single-NPPES-code / master-extras / dedup / seq ordering. (6) **Drop-existing prompt** in install.ps1 + new `sql/drop_cpe_repair_objects.sql` (ships in zip). (7) Embedded v1.x->v1.5 migration block removed from DDL (fresh installs only; drop script handles rebuild). (8) Tightened `validateQualifiedTableName` regex to `[A-Za-z0-9_ ]` inside brackets + trust-model Javadoc. (9) Doc cleanup of remaining v1.4-era `batch` / `BATCH_ID` references. Pom bumped to 1.6.0.
