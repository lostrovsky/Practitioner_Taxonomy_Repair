-- ============================================================
-- Practitioner Taxonomy Repair -- drop all cpe_repair objects
-- ============================================================
-- DESTRUCTIVE. Drops all objects in cpe_repair schema (and their data).
-- Used by install.ps1's "Drop existing cpe_repair objects first?" prompt
-- when an operator wants a fresh install. Safe to re-run (IF EXISTS guards).
-- Does NOT touch cpe / cpe_load / cpe_master.
--
-- Handles BOTH the current (v1.5+) object names and the legacy pre-v1.5
-- names (cpe_repair.batch, fn_..._for_batch_id) so a DB last installed at
-- v1.4.0 or earlier rebuilds cleanly. (v1.6.1 fix: prior versions of this
-- script dropped only the current names and orphaned the legacy objects.)
-- ============================================================

SET QUOTED_IDENTIFIER ON;
SET NOCOUNT ON;

-- Reverse FK order
IF OBJECT_ID('cpe_repair.sp_finalize_repair_run', 'P') IS NOT NULL
    DROP PROCEDURE cpe_repair.sp_finalize_repair_run;
GO

IF OBJECT_ID('cpe_repair.sp_mark_practitioner_repair_loaded', 'P') IS NOT NULL
    DROP PROCEDURE cpe_repair.sp_mark_practitioner_repair_loaded;
GO

IF OBJECT_ID('cpe_repair.fn_get_practitioner_taxonomy_repair_for_run_id', 'IF') IS NOT NULL
    DROP FUNCTION cpe_repair.fn_get_practitioner_taxonomy_repair_for_run_id;
GO

-- Legacy v1.x (pre-v1.5) TVF name -- present only when upgrading a DB that was
-- last installed at v1.4.0 or earlier. v1.5 renamed _for_batch_id -> _for_run_id.
IF OBJECT_ID('cpe_repair.fn_get_practitioner_taxonomy_repair_for_batch_id', 'IF') IS NOT NULL
    DROP FUNCTION cpe_repair.fn_get_practitioner_taxonomy_repair_for_batch_id;
GO

IF OBJECT_ID('cpe_repair.practitioner_taxonomy', 'U') IS NOT NULL
    DROP TABLE cpe_repair.practitioner_taxonomy;
GO

IF OBJECT_ID('cpe_repair.practitioner_repair', 'U') IS NOT NULL
    DROP TABLE cpe_repair.practitioner_repair;
GO

IF OBJECT_ID('cpe_repair.repair_run', 'U') IS NOT NULL
    DROP TABLE cpe_repair.repair_run;
GO

-- Legacy v1.x (pre-v1.5) run table name -- v1.5 renamed batch -> repair_run.
-- Dropped after practitioner_repair so its FK (batch_id -> batch) is gone first.
IF OBJECT_ID('cpe_repair.batch', 'U') IS NOT NULL
    DROP TABLE cpe_repair.batch;
GO

PRINT 'cpe_repair objects dropped (schema cpe_repair retained -- harmless).';
GO
