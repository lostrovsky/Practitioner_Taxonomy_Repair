# Claude Code -- Project Bootstrap

On every new conversation, read these files to establish full project context:

1. `CLAUDE_NOTES.md` -- What this is, why it exists, how it works end-to-end
2. `TODO.md` -- Pending and completed work items

Also read memory files for user preferences and cross-session context:
- `~/.claude/projects/c--Users-lostrovsky-VSCode-Projects-Practitioner-Taxonomy-Repair/memory/MEMORY.md`

## What this project is

One-off remediation tool for a v1.4.1 bug in `Claim_Provider_Data_Extractor` that wiped the NPPES `is_primary` marker before the practitioner-create-ranking CTE could use it. Practitioners loaded before the fix may have the wrong taxonomy designated as primary in HRP.

This tool fixes that. It re-fetches NPPES live for affected practitioners, stages a complete-overlay taxonomy list in a new `cpe_repair` schema, and feeds it into a new `practitioner_taxonomy_repair` call type that's run via the existing `Generic_HRP_WS_Call` loader (no modifications to that loader).

## Sibling projects

- `Claim_Provider_Data_Extractor` -- the v1.4.1-fixed extractor whose `NPPESClient` this tool reuses (imported as a Maven dependency, unchanged)
- `Generic_HRP_WS_Call` -- the loader that consumes the call folder this project ships
- `Claim_Provider_Data_Pipeline` -- the daily pipeline orchestrator. **Not touched** by this project; the repair flow runs out-of-band.

## Constraints (load-bearing)

- Does NOT modify any code in any other project
- Does NOT read or write `cpe.*`, `cpe_load.*`, or `cpe_master.*` for writes (reads from `cpe_master.practitioner` and `cpe_master.practitioner_taxonomy` are read-only and necessary)
- Does NOT consume a `cpe_load.load_run.run_id`. Uses its own `cpe_repair.repair_run.run_id` IDENTITY sequence (same column name as the pipeline -- different schema means no PK collision).
- Database footprint is the new `cpe_repair` schema only.
