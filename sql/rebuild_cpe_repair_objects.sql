-- ============================================================
-- Practitioner Taxonomy Repair -- FULL REBUILD of the cpe_repair schema
-- ============================================================
-- DESTRUCTIVE, one-shot. Drops EVERY cpe_repair object -- both the current
-- (v1.5+) names AND the legacy pre-v1.5 names (cpe_repair.batch,
-- fn_..._for_batch_id) -- then recreates the full current schema from scratch.
--
-- Use this to bring a database installed at ANY prior version (v1.0.0 .. v1.6.x)
-- to the current schema in a single run, when you do NOT need to preserve any
-- existing cpe_repair data. All rows in repair_run / practitioner_repair /
-- practitioner_taxonomy (and the legacy batch table) are erased.
--
-- Does NOT touch cpe / cpe_load / cpe_master.
--
-- MAINTENANCE: this file inlines the DROP logic of drop_cpe_repair_objects.sql
-- and the CREATE logic of create_cpe_repair_objects.sql so it is self-contained
-- (a single `sqlcmd -i` with no path-fragile :r includes). If you change the
-- schema in create_cpe_repair_objects.sql, mirror the change in the CREATE
-- section below.
--
--   sqlcmd -S <server> -d <db> -U <user> -P '<pwd>' -i sql/rebuild_cpe_repair_objects.sql
-- ============================================================

SET QUOTED_IDENTIFIER ON;
SET NOCOUNT ON;

PRINT '--- DROP phase: removing all cpe_repair objects (current + legacy names) ---';
GO

-- ============================================================
-- DROP phase -- reverse dependency order. IF EXISTS guards make every
-- line a no-op when the object is absent, so this runs cleanly against a
-- v1.0.0 .. v1.6.x schema or an empty/partial one.
-- ============================================================

-- Stored procedures first (no inbound dependencies)
IF OBJECT_ID('cpe_repair.sp_finalize_repair_run', 'P') IS NOT NULL
    DROP PROCEDURE cpe_repair.sp_finalize_repair_run;            -- added v1.6.0
GO

IF OBJECT_ID('cpe_repair.sp_mark_practitioner_repair_loaded', 'P') IS NOT NULL
    DROP PROCEDURE cpe_repair.sp_mark_practitioner_repair_loaded;
GO

-- TVFs -- current name and legacy (pre-v1.5) name
IF OBJECT_ID('cpe_repair.fn_get_practitioner_taxonomy_repair_for_run_id', 'IF') IS NOT NULL
    DROP FUNCTION cpe_repair.fn_get_practitioner_taxonomy_repair_for_run_id;
GO

IF OBJECT_ID('cpe_repair.fn_get_practitioner_taxonomy_repair_for_batch_id', 'IF') IS NOT NULL
    DROP FUNCTION cpe_repair.fn_get_practitioner_taxonomy_repair_for_batch_id;  -- legacy <= v1.4.0
GO

-- Child tables before parent (FK order)
IF OBJECT_ID('cpe_repair.practitioner_taxonomy', 'U') IS NOT NULL
    DROP TABLE cpe_repair.practitioner_taxonomy;
GO

IF OBJECT_ID('cpe_repair.practitioner_repair', 'U') IS NOT NULL
    DROP TABLE cpe_repair.practitioner_repair;
GO

-- Run table -- current name and legacy (pre-v1.5) name. Dropped after
-- practitioner_repair so any old batch_id -> batch FK is already gone.
IF OBJECT_ID('cpe_repair.repair_run', 'U') IS NOT NULL
    DROP TABLE cpe_repair.repair_run;
GO

IF OBJECT_ID('cpe_repair.batch', 'U') IS NOT NULL
    DROP TABLE cpe_repair.batch;                                 -- legacy <= v1.4.0
GO

PRINT '--- CREATE phase: building current cpe_repair schema ---';
GO

-- ============================================================
-- CREATE phase -- mirrors create_cpe_repair_objects.sql.
-- ============================================================

-- 1. Schema
IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'cpe_repair')
    EXEC('CREATE SCHEMA cpe_repair AUTHORIZATION dbo;');
GO

-- 2. Run table -- one row per repair invocation
IF OBJECT_ID('cpe_repair.repair_run', 'U') IS NULL
BEGIN
    CREATE TABLE cpe_repair.repair_run (
        run_id         BIGINT        IDENTITY(1,1) NOT NULL,
        description    NVARCHAR(200) NULL,
        status         NVARCHAR(20)  NOT NULL DEFAULT 'pending',  -- pending | completed | partial | failed
        created_time   DATETIME2     NOT NULL DEFAULT GETDATE(),
        completed_time DATETIME2     NULL,
        CONSTRAINT pk_repair_run PRIMARY KEY (run_id),
        CONSTRAINT ck_repair_run_status CHECK (status IN ('pending','completed','partial','failed'))
    );
END
GO

-- 3. Per-practitioner-per-run row -- the "entity" the loader marks loaded.
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
        CONSTRAINT uq_repair_practitioner_run_npi UNIQUE (run_id, npi),
        CONSTRAINT ck_repair_practitioner_status CHECK (status IN ('pending','loaded','failed','skipped'))
    );
    CREATE INDEX ix_repair_practitioner_run ON cpe_repair.practitioner_repair(run_id);

    ALTER TABLE cpe_repair.practitioner_repair WITH NOCHECK
        ADD CONSTRAINT fk_repair_practitioner_run
            FOREIGN KEY (run_id) REFERENCES cpe_repair.repair_run(run_id);
END
GO

-- 4. Taxonomies for each practitioner_repair entity.
IF OBJECT_ID('cpe_repair.practitioner_taxonomy', 'U') IS NULL
BEGIN
    CREATE TABLE cpe_repair.practitioner_taxonomy (
        entity_id      BIGINT        NOT NULL,
        taxonomy_code  NVARCHAR(20)  NOT NULL,
        taxonomy_name  NVARCHAR(255) NOT NULL,
        seq_num        INT           NOT NULL,
        is_primary     BIT           NOT NULL,
        is_secondary   BIT           NOT NULL,
        created_time   DATETIME2     NOT NULL DEFAULT GETDATE(),
        CONSTRAINT pk_repair_taxonomy PRIMARY KEY (entity_id, taxonomy_code),
        CONSTRAINT ck_repair_taxonomy_primary_xor_secondary
            CHECK (NOT (is_primary = 1 AND is_secondary = 1))
    );

    ALTER TABLE cpe_repair.practitioner_taxonomy WITH NOCHECK
        ADD CONSTRAINT fk_repair_taxonomy_practitioner
            FOREIGN KEY (entity_id) REFERENCES cpe_repair.practitioner_repair(entity_id);
END
GO

-- 5. TVF used by the loader's practitioner_taxonomy_repair call type.
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
);
GO

-- 6. Stored proc to mark a single practitioner_repair entity as loaded.
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

-- 7. Stored proc to finalize a repair_run after the loader completes.
CREATE OR ALTER PROCEDURE cpe_repair.sp_finalize_repair_run
    @run_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @loaded INT, @failed INT, @pending INT;
    SELECT
        @loaded  = SUM(CASE WHEN status = 'loaded'  THEN 1 ELSE 0 END),
        @failed  = SUM(CASE WHEN status = 'failed'  THEN 1 ELSE 0 END),
        @pending = SUM(CASE WHEN status = 'pending' THEN 1 ELSE 0 END)
    FROM cpe_repair.practitioner_repair
    WHERE run_id = @run_id;

    DECLARE @new_status NVARCHAR(20);
    SET @new_status =
        CASE
            WHEN @loaded > 0 AND @failed = 0 AND @pending = 0 THEN 'completed'
            WHEN @loaded > 0 AND (@failed > 0 OR @pending > 0) THEN 'partial'
            WHEN @loaded = 0 AND @failed > 0                   THEN 'failed'
            ELSE 'pending'   -- no movement (skip-only run, or loader didn't run)
        END;

    UPDATE cpe_repair.repair_run
       SET status         = @new_status,
           completed_time = CASE WHEN @new_status IN ('completed','partial','failed') THEN GETDATE() ELSE completed_time END
     WHERE run_id = @run_id;
END
GO

PRINT 'cpe_repair schema rebuilt -- all objects dropped (current + legacy) and recreated.';
GO
