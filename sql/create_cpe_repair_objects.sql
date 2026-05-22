-- ============================================================
-- Practitioner Taxonomy Repair -- isolated cpe_repair schema
-- ============================================================
-- Creates a self-contained schema for one-off NPPES taxonomy
-- repairs. Does NOT touch cpe / cpe_load / cpe_master.
--
-- Vocab mirrors the daily pipeline: per-invocation table is
-- cpe_repair.repair_run (analogous to cpe_load.load_run), keyed
-- by run_id. The loader's --RUN_ID flag and ${RUN_ID} placeholder
-- pass straight through without renaming.
--
-- Embedded v1.x -> v1.5 migration:
-- Older installs of this project had a cpe_repair.batch table with
-- a batch_id column (and a TVF named ..._for_batch_id). Re-running
-- this DDL on such an install drops those objects first and rebuilds
-- under the new names. Existing rows in cpe_repair.* are audit
-- artifacts from prior repair runs -- they're discarded (acceptable
-- for a one-off remediation tool; no operational data lives here).
-- ============================================================

SET QUOTED_IDENTIFIER ON;
SET NOCOUNT ON;

-- 0. Schema
IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'cpe_repair')
    EXEC('CREATE SCHEMA cpe_repair AUTHORIZATION dbo;');
GO

-- 1. Migration: drop old v1.x objects if present (batch_id era).
IF OBJECT_ID('cpe_repair.fn_get_practitioner_taxonomy_repair_for_batch_id', 'IF') IS NOT NULL
    DROP FUNCTION cpe_repair.fn_get_practitioner_taxonomy_repair_for_batch_id;
GO

IF OBJECT_ID('cpe_repair.batch', 'U') IS NOT NULL
BEGIN
    PRINT 'Migrating v1.x: dropping old cpe_repair.batch / practitioner_repair / practitioner_taxonomy';
    IF OBJECT_ID('cpe_repair.practitioner_taxonomy', 'U') IS NOT NULL DROP TABLE cpe_repair.practitioner_taxonomy;
    IF OBJECT_ID('cpe_repair.practitioner_repair', 'U') IS NOT NULL DROP TABLE cpe_repair.practitioner_repair;
    DROP TABLE cpe_repair.batch;
END
GO

-- 2. Run table -- one row per repair invocation
IF OBJECT_ID('cpe_repair.repair_run', 'U') IS NULL
BEGIN
    CREATE TABLE cpe_repair.repair_run (
        run_id         BIGINT        IDENTITY(1,1) NOT NULL,
        description    NVARCHAR(200) NULL,
        status         NVARCHAR(20)  NOT NULL DEFAULT 'pending',  -- pending | loaded | partial | failed
        created_time   DATETIME2     NOT NULL DEFAULT GETDATE(),
        completed_time DATETIME2     NULL,
        CONSTRAINT pk_repair_run PRIMARY KEY (run_id)
    );
END
GO

-- 3. Per-practitioner-per-run row -- the "entity" the loader marks loaded.
--    entity_id is the post-call SQL target. UNIQUE on (run_id, npi) prevents
--    accidental duplicate staging within one run.
IF OBJECT_ID('cpe_repair.practitioner_repair', 'U') IS NULL
BEGIN
    CREATE TABLE cpe_repair.practitioner_repair (
        entity_id           BIGINT        IDENTITY(1,1) NOT NULL,
        run_id              BIGINT        NOT NULL,
        npi                 NVARCHAR(20)  NOT NULL,                 -- audit/lookup, NOT in SOAP payload
        practitioner_hcc_id NVARCHAR(50)  NOT NULL,                 -- the only field in the SOAP payload
        status              NVARCHAR(20)  NOT NULL DEFAULT 'pending', -- pending | loaded | failed | skipped (no amend needed; master already matches NPPES)
        error_message       NVARCHAR(MAX) NULL,
        loaded_time         DATETIME2     NULL,
        created_time        DATETIME2     NOT NULL DEFAULT GETDATE(),
        CONSTRAINT pk_repair_practitioner PRIMARY KEY (entity_id),
        CONSTRAINT uq_repair_practitioner_run_npi UNIQUE (run_id, npi)
    );
    CREATE INDEX ix_repair_practitioner_run ON cpe_repair.practitioner_repair(run_id);

    ALTER TABLE cpe_repair.practitioner_repair WITH NOCHECK
        ADD CONSTRAINT fk_repair_practitioner_run
            FOREIGN KEY (run_id) REFERENCES cpe_repair.repair_run(run_id);
END
GO

-- 4. Taxonomies for each practitioner_repair entity
IF OBJECT_ID('cpe_repair.practitioner_taxonomy', 'U') IS NULL
BEGIN
    CREATE TABLE cpe_repair.practitioner_taxonomy (
        entity_id      BIGINT        NOT NULL,
        taxonomy_code  NVARCHAR(20)  NOT NULL,
        taxonomy_name  NVARCHAR(255) NULL,
        seq_num        INT           NOT NULL,
        is_primary     BIT           NOT NULL,
        is_secondary   BIT           NOT NULL,
        created_time   DATETIME2     NOT NULL DEFAULT GETDATE(),
        CONSTRAINT pk_repair_taxonomy PRIMARY KEY (entity_id, taxonomy_code)
    );

    ALTER TABLE cpe_repair.practitioner_taxonomy WITH NOCHECK
        ADD CONSTRAINT fk_repair_taxonomy_practitioner
            FOREIGN KEY (entity_id) REFERENCES cpe_repair.practitioner_repair(entity_id);
END
GO

-- 5. TVF used by the loader's practitioner_taxonomy_repair call type.
--    Returns one row per (practitioner, "other" taxonomy) plus scalar
--    primary/secondary slots -- same row shape as cpe_load's amend TVFs.
--    The loader's existing template can render it without changes.
--    Filters status NOT IN ('loaded','skipped') so resume is free and
--    skipped rows are never sent to HRP.
CREATE OR ALTER FUNCTION cpe_repair.fn_get_practitioner_taxonomy_repair_for_run_id(@run_id BIGINT)
RETURNS TABLE
AS
RETURN
(
    WITH PTXN (entity_id, run_id, practitioner_hcc_id, seq_num, taxonomy_code, taxonomy_name, is_primary, is_secondary) AS
    (
        SELECT pr.entity_id,
               pr.run_id,
               pr.practitioner_hcc_id,
               pt.seq_num,
               pt.taxonomy_code,
               pt.taxonomy_name,
               pt.is_primary,
               pt.is_secondary
        FROM cpe_repair.practitioner_repair pr
        JOIN cpe_repair.practitioner_taxonomy pt ON pt.entity_id = pr.entity_id
        WHERE pr.run_id = @run_id
          AND pr.status NOT IN ('loaded', 'skipped')
    )
    SELECT
        pr.entity_id,
        pr.run_id,
        pr.practitioner_hcc_id,
        prt_primary.taxonomy_name   AS primary_taxonomy_name,
        prt_secondary.taxonomy_name AS secondary_taxonomy_name,
        prt_other.taxonomy_name     AS other_taxonomy_name,
        prt_other.seq_num           AS other_taxonomy_seq_num
    FROM cpe_repair.practitioner_repair pr
    LEFT JOIN PTXN prt_primary
           ON prt_primary.entity_id = pr.entity_id
          AND prt_primary.is_primary = 1
    LEFT JOIN PTXN prt_secondary
           ON prt_secondary.entity_id = pr.entity_id
          AND prt_secondary.is_secondary = 1
    LEFT JOIN PTXN prt_other
           ON prt_other.entity_id = pr.entity_id
          AND prt_other.is_primary = 0
          AND prt_other.is_secondary = 0
    WHERE pr.run_id = @run_id
      AND pr.status NOT IN ('loaded', 'skipped')
      -- Exclude rows with no taxonomies at all (defensive; shouldn't happen)
      AND (prt_primary.taxonomy_name   IS NOT NULL
        OR prt_secondary.taxonomy_name IS NOT NULL
        OR prt_other.taxonomy_name     IS NOT NULL)
);
GO

-- 6. Stored proc to mark a single practitioner_repair entity as loaded.
--    Called from the call type's sql.json post-call SQL.
CREATE OR ALTER PROCEDURE cpe_repair.sp_mark_practitioner_repair_loaded
    @entity_id     BIGINT,
    @success       BIT,
    @error_message NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE cpe_repair.practitioner_repair
       SET status        = CASE WHEN @success = 1 THEN 'loaded' ELSE 'failed' END,
           loaded_time   = CASE WHEN @success = 1 THEN GETDATE() ELSE loaded_time END,
           error_message = @error_message
     WHERE entity_id = @entity_id;
END
GO

PRINT 'cpe_repair objects ready.';
GO
