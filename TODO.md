# TODO / Enhancements

## Pending
- [ ] Confirm correct HRP `<maintenanceReasonCode>` `<codeSetName>` and `<codeEntry>` for a taxonomy-overlay amend (currently mirrors the existing amend template's `PractitionerCreateReason / 1`)
- [ ] Confirm HRP behavior on `<updateMode>REPLACE</updateMode>` matches "complete overlay" semantics (i.e., HRP replaces the taxonomy list; doesn't merge)
- [ ] Decide whether to run against real-data batch on prod once the two items above are confirmed

## Completed
- [x] DDL: `cpe_repair` schema, `batch` / `practitioner_repair` / `practitioner_taxonomy` tables, TVF, post-call sp -- all idempotent
- [x] Java tool: reads NPI list (file or auto-derive), calls `NPPESClient` per NPI, combines with claims-source taxonomies from `cpe_master`, looks up names from `cpe_xref.taxonomy`, INSERTs into `cpe_repair.*`. `--dry-run` mode for safety.
- [x] Call folder `calls/practitioner_taxonomy_repair/`: properties (DB query, WS endpoint, taxonomy-only template), sql.json (post-call), report.json
- [x] Verified end-to-end against NPI 1003008574 in LOG_ONLY mode -- SOAP renders correctly, post-call SQL targets the right entity_id
- [x] Verified isolation: no writes to `cpe.*`, `cpe_load.*`, or `cpe_master.*`; `cpe_load.load_run` sequence not consumed
