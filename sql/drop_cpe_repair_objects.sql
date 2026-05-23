-- ============================================================
-- Practitioner Taxonomy Repair -- drop all cpe_repair objects
-- ============================================================
-- DESTRUCTIVE. Drops all objects in cpe_repair schema (and their data).
-- Used by install.ps1's "Drop existing cpe_repair objects first?" prompt
-- when an operator wants a fresh install. Safe to re-run (IF EXISTS guards).
-- Does NOT touch cpe / cpe_load / cpe_master.
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

IF OBJECT_ID('cpe_repair.practitioner_taxonomy', 'U') IS NOT NULL
    DROP TABLE cpe_repair.practitioner_taxonomy;
GO

IF OBJECT_ID('cpe_repair.practitioner_repair', 'U') IS NOT NULL
    DROP TABLE cpe_repair.practitioner_repair;
GO

IF OBJECT_ID('cpe_repair.repair_run', 'U') IS NOT NULL
    DROP TABLE cpe_repair.repair_run;
GO

PRINT 'cpe_repair objects dropped (schema cpe_repair retained -- harmless).';
GO
