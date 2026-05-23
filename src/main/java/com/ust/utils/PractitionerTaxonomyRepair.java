package com.ust.utils;

import java.net.URI;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.sql.Statement;
import java.sql.Types;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.HashSet;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.logging.Level;
import java.util.logging.Logger;

/**
 * One-off remediation tool. For each practitioner in the input list, re-fetch
 * NPPES via NPPESClient, compare to what's currently in cpe_master, and either:
 *   - skip the NPI (no amend) if master already matches NPPES, OR
 *   - stage a merged taxonomy list in cpe_repair (NPPES wins on the primary
 *     designation; master's taxonomies are preserved; deduped by code).
 *
 * "Master matches NPPES" means:
 *   master.codes ⊇ NPPES.codes   (every NPPES code is already in master)
 *   AND the code with is_primary=1 in master is the same code NPPES marks primary.
 *
 * On a mismatch, the staged amend is built as:
 *   primary     = NPPES primary code
 *   secondary   = first non-primary code in NPPES's taxonomy list (if NPPES
 *                 returned >= 2 codes; NPPES itself has no "secondary" marker)
 *   others      = remaining NPPES codes + all master codes not already in the list
 *   (deduped by code; one row per unique taxonomy code)
 *
 * Reads (no writes):
 *   cpe_master.practitioner                       -- to get practitioner_hcc_id
 *   cpe_master.practitioner_taxonomy              -- ALL rows for each NPI, with is_primary
 *   [HRDW_REPLICA].[PAYOR_DW].[PROVIDER_TAXONOMY] -- to look up taxonomy name from code
 *                                                   (same source the daily pipeline's
 *                                                   sp_resolve_taxonomy_names uses;
 *                                                   table + columns overridable via
 *                                                   db.taxonomy.lookup.{table,code_column,name_column}
 *                                                   properties)
 *
 * Writes (only):
 *   cpe_repair.repair_run               -- one new row per invocation (run_id IDENTITY)
 *   cpe_repair.practitioner_repair      -- one row per NPI considered; status:
 *                                          'pending' (staged for amend) or
 *                                          'skipped' (already matched NPPES;
 *                                          loader will not pick these up because
 *                                          the TVF filters status NOT IN
 *                                          ('loaded','skipped'))
 *   cpe_repair.practitioner_taxonomy    -- only for pending rows; none for skipped
 *
 * Calls NPPESClient (from claim-provider-data-extractor.jar) directly. No
 * modifications to that class.
 *
 * CLI args:
 *   --log-output=both|file|console     (default: both)
 *   --properties-file=<path>            (default: <jar-dir>/PractitionerTaxonomyRepair.properties)
 *   --npi-file=<path>                   (optional: text file with one NPI per line; lines starting with # are comments;
 *                                                   if omitted, the tool runs the auto-derive query -- by default
 *                                                   SELECT DISTINCT npi FROM <master>.practitioner_taxonomy
 *                                                   WHERE taxonomy_source = 'NPPES'. To override that default,
 *                                                   set the db.npi_query property to a custom SELECT returning
 *                                                   one column of NPIs (e.g. scoped to a bug-window load_run).
 *                                                   --npi-file always wins over db.npi_query.)
 *   --description=<text>                (optional: stored on cpe_repair.repair_run.description for audit)
 *   --dry-run                           (optional: do everything except the final INSERTs; logs what would be staged)
 */
public class PractitionerTaxonomyRepair {

    private static final String DEFAULT_LOG_OUTPUT = "both";

    private static Logger logger;
    private static ConfigLoader config;
    private static DBManager dbManager;
    private static String masterSchema;
    private static String repairSchema;
    private static String taxonomyLookupTable;   // default [HRDW_REPLICA].[PAYOR_DW].[PROVIDER_TAXONOMY]
    private static String taxonomyCodeColumn;    // default PROVIDER_TAXONOMY_CODE
    private static String taxonomyNameColumn;    // default PROVIDER_TAXONOMY_NAME
    private static String npiQueryOverride;      // optional db.npi_query; null/blank => use built-in default

    public static void main(String[] args) {
        int exitCode = 0;
        try {
            String logOutput = DEFAULT_LOG_OUTPUT;
            String cliPropertiesFile = null;
            String npiFile = null;
            String description = null;
            boolean dryRun = false;
            for (String arg : args) {
                if (arg.startsWith("--log-output=")) {
                    logOutput = arg.substring("--log-output=".length());
                } else if (arg.startsWith("--properties-file=")) {
                    cliPropertiesFile = arg.substring("--properties-file=".length());
                } else if (arg.startsWith("--npi-file=")) {
                    npiFile = arg.substring("--npi-file=".length());
                } else if (arg.startsWith("--description=")) {
                    description = arg.substring("--description=".length());
                } else if (arg.equals("--dry-run")) {
                    dryRun = true;
                } else {
                    System.err.println("Unknown argument: " + arg);
                    System.exit(1);
                }
            }

            initialSetup(logOutput, cliPropertiesFile);

            dbManager.connect();

            // 1. Resolve target NPI list.
            if (npiFile != null && npiQueryOverride != null) {
                logger.warning("--npi-file is set; db.npi_query in the properties file will be ignored.");
            }
            List<String> npis = (npiFile != null)
                    ? readNpiFile(npiFile)
                    : queryNpisWithNppesTaxonomies();
            logger.info("Target NPI count: " + npis.size());
            if (npis.isEmpty()) {
                logger.info("No practitioners to process. Exiting.");
                return;
            }

            // 2. Pre-load supporting data: hcc_id per NPI, full master taxonomy snapshot per NPI.
            Map<String, String>          hccIdByNpi  = loadHccIdsByNpi(npis);
            Map<String, MasterSnapshot>  masterByNpi = loadMasterSnapshotsByNpi(npis);

            // 3. NPPES lookup loop -- decides per NPI: stage an amend (master differs from NPPES)
            //    or record a skip (master already matches NPPES; the loader will not pick it up).
            NPPESClient nppesClient = new NPPESClient(logger);
            List<RepairRow> staged  = new ArrayList<>();
            List<SkipRow>   skipped = new ArrayList<>();
            int notInMaster    = 0;
            int nppesNotFound  = 0;

            for (String npi : npis) {
                String hccId = hccIdByNpi.get(npi);
                if (hccId == null) {
                    notInMaster++;
                    logger.warning("NPI " + npi + ": not found in " + masterSchema + ".practitioner -- skipping (cannot address an amend without practitioner_hcc_id)");
                    continue;
                }
                NPPESClient.NPPESResult r = nppesClient.lookupNpi(npi);
                if (!r.isFound() || !r.hasTaxonomyCodes()) {
                    nppesNotFound++;
                    logger.warning("NPI " + npi + ": NPPES not found or returned no taxonomies -- skipping");
                    continue;
                }
                String nppesPrimary = r.getPrimaryTaxonomyCode();
                if (nppesPrimary == null) {
                    logger.warning("NPI " + npi + ": NPPES result has no primary marker; cannot evaluate match -- skipping");
                    nppesNotFound++;
                    continue;
                }

                MasterSnapshot master = masterByNpi.getOrDefault(npi, MasterSnapshot.EMPTY);
                Decision d = decide(nppesPrimary, r.getTaxonomyCodes(), master);
                logger.info("NPI " + npi + ": " + d.reason);
                if (d.kind == Decision.Kind.MATCH) {
                    skipped.add(new SkipRow(npi, hccId, d.reason));
                } else { // STAGE
                    staged.add(new RepairRow(npi, hccId, d.staged));
                }
            }

            // 4. Resolve taxonomy_name for every staged code (single batched lookup).
            //    Done BEFORE the final decision summary so the H3/O1 fail-fast can downgrade
            //    practitioners whose primary code doesn't resolve. Also runs in --dry-run so
            //    unresolvable codes surface early (instead of biting on the real run).
            Set<String> allCodes = new HashSet<>();
            for (RepairRow rr : staged) {
                for (TaxonomyEntry e : rr.taxonomies) allCodes.add(e.taxonomyCode);
            }
            Map<String, String> codeToName = lookupTaxonomyNames(allCodes);

            // H3/O1 fail-fast: if a staged practitioner's NPPES primary code didn't resolve in
            // the taxonomy lookup table, the SOAP <primarySpecialty> would render empty (the
            // template's data-optional drops the tag) and HRP would receive an amend with no
            // primary specialty -- silently undoing the whole point of the repair. Demote those
            // to skip with a clear reason instead of letting them through.
            int unresolvedPrimary = 0;
            List<RepairRow> filteredStaged = new ArrayList<>(staged.size());
            for (RepairRow rr : staged) {
                String primaryCode = null;
                for (TaxonomyEntry e : rr.taxonomies) if (e.isPrimary) { primaryCode = e.taxonomyCode; break; }
                if (primaryCode != null && !codeToName.containsKey(primaryCode)) {
                    String reason = "primary taxonomy code " + primaryCode + " not found in " + taxonomyLookupTable +
                            " -- cannot render a valid SOAP <primarySpecialty>, refusing to stage";
                    logger.warning("NPI " + rr.npi + ": " + reason);
                    skipped.add(new SkipRow(rr.npi, rr.hccId, reason));
                    unresolvedPrimary++;
                } else {
                    filteredStaged.add(rr);
                }
            }
            staged = filteredStaged;

            int matchSkipped = skipped.size() - unresolvedPrimary;
            logger.info(String.format(
                    "Decision summary: %d staged for amend; %d skipped (%d already-matching, %d primary-name-not-resolved); %d NPPES-not-found/no-primary; %d not-in-master (total NPIs considered: %d)",
                    staged.size(), skipped.size(), matchSkipped, unresolvedPrimary, nppesNotFound, notInMaster, npis.size()));

            if (dryRun) {
                logger.info("--dry-run set: skipping all INSERTs.");
                logger.info("Sample of first 5 to-be-staged rows:");
                for (int i = 0; i < Math.min(5, staged.size()); i++) {
                    RepairRow rr = staged.get(i);
                    logger.info("  STAGE  " + rr.npi + "  hcc_id=" + rr.hccId + "  taxonomies=" + rr.taxonomies);
                }
                logger.info("Sample of first 5 to-be-skipped rows:");
                for (int i = 0; i < Math.min(5, skipped.size()); i++) {
                    SkipRow sr = skipped.get(i);
                    logger.info("  SKIP   " + sr.npi + "  hcc_id=" + sr.hccId + "  (" + sr.reason + ")");
                }
                return;
            }

            if (staged.isEmpty() && skipped.isEmpty()) {
                logger.info("Nothing to persist (no staged amends, no skipped rows). Exiting without creating a run.");
                return;
            }

            // 5. Persist: one run + N pending practitioner_repair (+ M practitioner_taxonomy)
            //              + K skipped practitioner_repair (with status='skipped' and reason).
            long runId = persistRun(description, staged, skipped, codeToName);
            logger.info("Repair run " + runId + " staged successfully. " +
                    "Run the loader with --RUN_ID=" + runId + " against the practitioner_taxonomy_repair call folder.");
            // Emit on stdout too so wrapper scripts can capture without parsing the log.
            System.out.println("RUN_ID=" + runId);
        } catch (Exception e) {
            if (logger != null) logger.log(Level.SEVERE, "Repair failed", e);
            else { System.err.println("Repair failed: " + e.getMessage()); e.printStackTrace(); }
            exitCode = 1;
        } finally {
            try { if (dbManager != null) dbManager.disconnect(); } catch (Exception ignored) {}
        }
        if (exitCode != 0) System.exit(exitCode);
    }

    // ============================================================
    // Setup
    // ============================================================
    private static void initialSetup(String logOutput, String cliPropertiesFile) throws Exception {
        Path jarPath = Paths.get(getJarLocation());
        Path baseDir = jarPath.getParent() != null ? jarPath.getParent() : Paths.get(".").toAbsolutePath();
        String className = PractitionerTaxonomyRepair.class.getSimpleName();
        Path logFile = baseDir.resolve(className + ".log");
        Path propsFile = cliPropertiesFile != null
                ? Paths.get(cliPropertiesFile)
                : baseDir.resolve(className + ".properties");
        logger = LoggerFactory.createLogger(className, logFile.toString(), logOutput);
        config = new ConfigLoader(propsFile.toString());
        dbManager = new DBManager(config.getProperties(), logger);
        masterSchema = nonBlank(config.get("db.master.schema"), "cpe_master");
        repairSchema = nonBlank(config.get("db.repair.schema"), "cpe_repair");
        validateSchemaName(masterSchema);
        validateSchemaName(repairSchema);
        // Taxonomy code -> name lookup. Defaults match the daily pipeline's
        // sp_resolve_taxonomy_names source (same DB user `cpp` already has access).
        // Overridable for environments where the replica DB / schema / column names differ.
        taxonomyLookupTable = nonBlank(config.get("db.taxonomy.lookup.table"),
                "[HRDW_REPLICA].[PAYOR_DW].[PROVIDER_TAXONOMY]");
        taxonomyCodeColumn  = nonBlank(config.get("db.taxonomy.lookup.code_column"),
                "PROVIDER_TAXONOMY_CODE");
        taxonomyNameColumn  = nonBlank(config.get("db.taxonomy.lookup.name_column"),
                "PROVIDER_TAXONOMY_NAME");
        validateIdentifier(taxonomyCodeColumn);
        validateIdentifier(taxonomyNameColumn);
        // taxonomyLookupTable can be a 3-part name with brackets ([db].[schema].[table]) --
        // validated by a looser regex.
        validateQualifiedTableName(taxonomyLookupTable);
        // Optional verbatim SQL for the auto-derive path. Not validated -- operator-controlled
        // trust boundary, same as the loader's db.query in the call folder. Ignored when --npi-file is passed.
        String raw = config.get("db.npi_query");
        npiQueryOverride = (raw == null || raw.isBlank()) ? null : raw.trim();
        logger.info("Properties loaded from: " + propsFile);
    }

    private static URI getJarLocation() throws Exception {
        return PractitionerTaxonomyRepair.class.getProtectionDomain().getCodeSource().getLocation().toURI();
    }

    private static String nonBlank(String v, String def) { return (v == null || v.isBlank()) ? def : v.trim(); }

    private static void validateSchemaName(String s) {
        if (s == null || !s.matches("^[a-zA-Z_][a-zA-Z0-9_]*$"))
            throw new IllegalArgumentException("Invalid schema name: " + s);
    }

    /**
     * Bare SQL identifier (column or unbracketed table name). The character set is the C-style
     * identifier rule, not the full set SQL Server actually permits in brackets.
     * <p>
     * Trust model: the values flow from operator-edited install.config / properties; this
     * validator's job is to surface a typo as a clear error early, not to defend against a
     * malicious config (the same operator owns sqlcmd already). A tighter regex would reject
     * legal SQL identifiers like names with spaces/hyphens; we accept that limitation here.
     */
    private static void validateIdentifier(String s) {
        if (s == null || !s.matches("^[a-zA-Z_][a-zA-Z0-9_]*$"))
            throw new IllegalArgumentException("Invalid SQL identifier: " + s);
    }

    /**
     * Up-to-3-part qualified table name; each part is either a bare identifier or a bracketed
     * name whose body is restricted to [A-Za-z0-9_ ] (alphanumerics + underscore + space).
     * That charset rejects the SQL injection vectors -- semicolons, comment markers (-- or
     * /* *&#47;), quotes, parentheses, brackets-inside-brackets, newlines -- while still
     * accepting realistic SQL Server bracketed names (including "Name With Spaces"). Same
     * trust-model caveat as validateIdentifier above.
     */
    private static void validateQualifiedTableName(String s) {
        if (s == null) throw new IllegalArgumentException("Invalid table name: null");
        String part = "(?:\\[[A-Za-z0-9_ ]+\\]|[a-zA-Z_][a-zA-Z0-9_]*)";
        if (!s.matches("^" + part + "(?:\\." + part + "){0,2}$"))
            throw new IllegalArgumentException("Invalid qualified table name: " + s);
    }

    // ============================================================
    // Decision logic (pure, side-effect-free, unit-testable)
    // ============================================================
    /**
     * Given live NPPES taxonomy data and the current cpe_master snapshot for one NPI,
     * decide whether master already matches NPPES (skip, no amend) or differs (stage an
     * amend with the merged taxonomy list).
     * <p>
     * Pre-conditions (caller's responsibility): the NPI exists in cpe_master.practitioner
     * (we have a hcc_id), NPPES returned at least one taxonomy, and {@code nppesPrimary}
     * is non-null. This function has no side effects, no DB / NPPES / logger calls --
     * it's purely a function of its arguments. Designed for direct JUnit testing.
     *
     * @param nppesPrimary NPPES's primary taxonomy code (non-null)
     * @param nppesCodes   NPPES's full taxonomy code list (non-empty, must contain nppesPrimary)
     * @param master       master snapshot for the same NPI (may be MasterSnapshot.EMPTY)
     * @return MATCH (skip with reason) or STAGE (with merged taxonomy list and reason)
     */
    static Decision decide(String nppesPrimary, List<String> nppesCodes, MasterSnapshot master) {
        Set<String> nppesCodeSet = new LinkedHashSet<>(nppesCodes);

        // "Same" check: every NPPES code is already in master AND master's is_primary=1 code
        // is the same code NPPES marks primary. Master may have additional codes NPPES doesn't
        // return -- that's still "same" (no signal NPPES wants them removed; daily pipeline
        // re-derives master from claims+NPPES anyway).
        boolean masterHasAllNppes = master.codes.containsAll(nppesCodeSet);
        boolean primaryMatches    = nppesPrimary.equals(master.primaryCode);
        if (masterHasAllNppes && primaryMatches) {
            String reason = "master already matches NPPES (primary=" + nppesPrimary +
                    "; NPPES codes " + nppesCodes + " all present in master) -- recording skip, no amend will be sent";
            return Decision.match(reason);
        }

        // Mismatch -- build merged taxonomy list. Order: NPPES primary, NPPES secondary
        // (= 1st non-primary NPPES code, if any), remaining NPPES codes, then master codes
        // not already covered. Dedup by code; NPPES wins on the primary designation.
        String nppesSecondary = null;
        for (String c : nppesCodes) {
            if (!c.equals(nppesPrimary)) { nppesSecondary = c; break; }
        }

        Set<String>         seen     = new LinkedHashSet<>();
        List<TaxonomyEntry> combined = new ArrayList<>();
        TaxonomyEntry primaryEntry = new TaxonomyEntry(nppesPrimary, "NPPES");
        primaryEntry.isPrimary = true;
        combined.add(primaryEntry);
        seen.add(nppesPrimary);
        if (nppesSecondary != null && seen.add(nppesSecondary)) {
            TaxonomyEntry secondaryEntry = new TaxonomyEntry(nppesSecondary, "NPPES");
            secondaryEntry.isSecondary = true;
            combined.add(secondaryEntry);
        }
        for (String c : nppesCodes) {
            if (seen.add(c)) combined.add(new TaxonomyEntry(c, "NPPES"));
        }
        for (String c : master.codes) {
            if (seen.add(c)) combined.add(new TaxonomyEntry(c, "master"));
        }

        int seq = 1;
        for (TaxonomyEntry e : combined) e.seqNum = seq++;

        String why = !primaryMatches
                ? "staging amend -- primary mismatch (master=" + master.primaryCode + ", NPPES=" + nppesPrimary + ")"
                : "staging amend -- NPPES has codes not in master";
        return Decision.stage(why, combined);
    }

    // ============================================================
    // Read paths -- cpe_master.* (read-only) and the configured taxonomy lookup
    // ============================================================
    private static List<String> queryNpisWithNppesTaxonomies() throws SQLException {
        String sql;
        if (npiQueryOverride != null) {
            sql = npiQueryOverride;
            logger.info("Using custom NPI query from db.npi_query (expected to return one column of NPIs)");
        } else {
            sql = "SELECT DISTINCT npi FROM " + masterSchema + ".practitioner_taxonomy " +
                  "WHERE taxonomy_source = 'NPPES'";
            logger.info("Using built-in default NPI query (db.npi_query not set in properties)");
        }
        // Log the SQL itself so operators can see exactly what produced their NPI list.
        // Trim very long custom queries to keep the log readable.
        logger.info("NPI query: " + (sql.length() > 500 ? sql.substring(0, 500) + " ... [truncated]" : sql));
        Connection conn = dbManager.getConnection();
        List<String> npis = new ArrayList<>();
        try (Statement st = conn.createStatement(); ResultSet rs = st.executeQuery(sql)) {
            while (rs.next()) npis.add(rs.getString(1));
        }
        return npis;
    }

    private static List<String> readNpiFile(String path) throws Exception {
        List<String> npis = new ArrayList<>();
        for (String line : java.nio.file.Files.readAllLines(Paths.get(path))) {
            String t = line.trim();
            if (t.isEmpty() || t.startsWith("#")) continue;
            npis.add(t);
        }
        return npis;
    }

    private static Map<String, String> loadHccIdsByNpi(List<String> npis) throws SQLException {
        Map<String, String> map = new HashMap<>();
        if (npis.isEmpty()) return map;
        String sql = "SELECT npi, practitioner_hcc_id FROM " + masterSchema + ".practitioner WHERE npi IN ("
                + commaPlaceholders(npis.size()) + ")";
        Connection conn = dbManager.getConnection();
        try (PreparedStatement ps = conn.prepareStatement(sql)) {
            for (int i = 0; i < npis.size(); i++) ps.setString(i + 1, npis.get(i));
            try (ResultSet rs = ps.executeQuery()) {
                while (rs.next()) map.put(rs.getString(1), rs.getString(2));
            }
        }
        return map;
    }

    /**
     * Load every cpe_master.practitioner_taxonomy row for the input NPIs, regardless of
     * taxonomy_source ('claims' vs 'NPPES'). Returns a per-NPI MasterSnapshot with the
     * full code set and the code with is_primary=1 (first encountered if more than one).
     */
    private static Map<String, MasterSnapshot> loadMasterSnapshotsByNpi(List<String> npis) throws SQLException {
        Map<String, MasterSnapshot> result = new HashMap<>();
        if (npis.isEmpty()) return result;
        String sql = "SELECT npi, taxonomy_code, is_primary FROM " + masterSchema + ".practitioner_taxonomy " +
                "WHERE npi IN (" + commaPlaceholders(npis.size()) + ")";
        Map<String, Set<String>> codesByNpi   = new HashMap<>();
        Map<String, String>      primaryByNpi = new HashMap<>();
        Connection conn = dbManager.getConnection();
        try (PreparedStatement ps = conn.prepareStatement(sql)) {
            for (int i = 0; i < npis.size(); i++) ps.setString(i + 1, npis.get(i));
            try (ResultSet rs = ps.executeQuery()) {
                while (rs.next()) {
                    String npi  = rs.getString(1);
                    String code = rs.getString(2);
                    boolean isPrimary = rs.getBoolean(3);
                    codesByNpi.computeIfAbsent(npi, k -> new LinkedHashSet<>()).add(code);
                    if (isPrimary) {
                        String existing = primaryByNpi.putIfAbsent(npi, code);
                        if (existing != null && !existing.equals(code)) {
                            logger.warning("NPI " + npi + " has multiple is_primary=1 rows in " + masterSchema +
                                    ".practitioner_taxonomy (" + existing + ", " + code + "); using first encountered: " + existing);
                        }
                    }
                }
            }
        }
        for (Map.Entry<String, Set<String>> e : codesByNpi.entrySet()) {
            result.put(e.getKey(), new MasterSnapshot(e.getValue(), primaryByNpi.get(e.getKey())));
        }
        return result;
    }

    private static Map<String, String> lookupTaxonomyNames(Set<String> codes) throws SQLException {
        Map<String, String> map = new HashMap<>();
        if (codes.isEmpty()) return map;
        List<String> codeList = new ArrayList<>(codes);
        String sql = "SELECT " + taxonomyCodeColumn + ", " + taxonomyNameColumn +
                     " FROM " + taxonomyLookupTable +
                     " WHERE " + taxonomyCodeColumn + " IN (" + commaPlaceholders(codeList.size()) + ")";
        Connection conn = dbManager.getConnection();
        try (PreparedStatement ps = conn.prepareStatement(sql)) {
            for (int i = 0; i < codeList.size(); i++) ps.setString(i + 1, codeList.get(i));
            try (ResultSet rs = ps.executeQuery()) {
                while (rs.next()) map.put(rs.getString(1), rs.getString(2));
            }
        }
        // Anything not found → log; the SQL INSERT will use NULL for taxonomy_name.
        for (String c : codes) if (!map.containsKey(c))
            logger.warning("No " + taxonomyNameColumn + " in " + taxonomyLookupTable + " for code " + c + " (will insert NULL)");
        return map;
    }

    // ============================================================
    // Write path -- INSERTs into cpe_repair only
    // ============================================================
    private static long persistRun(String description, List<RepairRow> rows, List<SkipRow> skipped,
                                   Map<String, String> codeToName) throws SQLException {
        Connection conn = dbManager.getConnection();
        boolean prevAutoCommit = conn.getAutoCommit();
        try {
            conn.setAutoCommit(false);

            // 1. cpe_repair.repair_run
            long runId;
            String runSql = "INSERT INTO " + repairSchema + ".repair_run (description) OUTPUT INSERTED.run_id VALUES (?)";
            try (PreparedStatement ps = conn.prepareStatement(runSql)) {
                if (description == null) ps.setNull(1, Types.NVARCHAR); else ps.setString(1, description);
                try (ResultSet rs = ps.executeQuery()) {
                    if (!rs.next()) throw new SQLException("INSERT into repair_run returned no row");
                    runId = rs.getLong(1);
                }
            }
            logger.info("Created " + repairSchema + ".repair_run row: run_id=" + runId);

            // 2a. cpe_repair.practitioner_repair for staged rows (status defaults to 'pending');
            //     collect entity_ids back so the taxonomy rows can FK to them.
            String prPendingSql = "INSERT INTO " + repairSchema + ".practitioner_repair " +
                    "(run_id, npi, practitioner_hcc_id) OUTPUT INSERTED.entity_id VALUES (?, ?, ?)";
            try (PreparedStatement ps = conn.prepareStatement(prPendingSql)) {
                for (RepairRow rr : rows) {
                    ps.setLong(1, runId);
                    ps.setString(2, rr.npi);
                    ps.setString(3, rr.hccId);
                    try (ResultSet rs = ps.executeQuery()) {
                        if (!rs.next()) throw new SQLException("INSERT into practitioner_repair returned no row for NPI " + rr.npi);
                        rr.entityId = rs.getLong(1);
                    }
                }
            }

            // 2b. cpe_repair.practitioner_repair for skipped rows (status='skipped'; reason in error_message,
            //     which doubles as the decision-trail column for non-pending statuses). No taxonomy rows.
            String prSkippedSql = "INSERT INTO " + repairSchema + ".practitioner_repair " +
                    "(run_id, npi, practitioner_hcc_id, status, error_message) VALUES (?, ?, ?, 'skipped', ?)";
            int skipInserts = 0;
            if (!skipped.isEmpty()) {
                try (PreparedStatement ps = conn.prepareStatement(prSkippedSql)) {
                    for (SkipRow sr : skipped) {
                        ps.setLong(1, runId);
                        ps.setString(2, sr.npi);
                        ps.setString(3, sr.hccId);
                        ps.setString(4, sr.reason);
                        ps.addBatch();
                    }
                    int[] counts = ps.executeBatch();
                    for (int c : counts) if (c >= 0 || c == Statement.SUCCESS_NO_INFO) skipInserts++;
                }
            }

            // 3. cpe_repair.practitioner_taxonomy in batches (staged rows only).
            String txSql = "INSERT INTO " + repairSchema + ".practitioner_taxonomy " +
                    "(entity_id, taxonomy_code, taxonomy_name, seq_num, is_primary, is_secondary) " +
                    "VALUES (?, ?, ?, ?, ?, ?)";
            int taxRows = 0;
            try (PreparedStatement ps = conn.prepareStatement(txSql)) {
                for (RepairRow rr : rows) {
                    for (TaxonomyEntry e : rr.taxonomies) {
                        ps.setLong(1, rr.entityId);
                        ps.setString(2, e.taxonomyCode);
                        String name = codeToName.get(e.taxonomyCode);
                        if (name == null) ps.setNull(3, Types.NVARCHAR); else ps.setString(3, name);
                        ps.setInt(4, e.seqNum);
                        ps.setBoolean(5, e.isPrimary);
                        ps.setBoolean(6, e.isSecondary);
                        ps.addBatch();
                        taxRows++;
                    }
                }
                ps.executeBatch();
            }
            logger.info("Inserted " + rows.size() + " pending + " + skipInserts + " skipped practitioner_repair rows; "
                    + taxRows + " practitioner_taxonomy rows");

            conn.commit();
            return runId;
        } catch (SQLException e) {
            try { conn.rollback(); logger.warning("persistRun rolled back due to: " + e.getMessage()); } catch (SQLException ignored) {}
            throw e;
        } finally {
            try { conn.setAutoCommit(prevAutoCommit); } catch (SQLException ignored) {}
        }
    }

    // ============================================================
    // Helpers
    // ============================================================
    private static String commaPlaceholders(int n) {
        StringBuilder sb = new StringBuilder();
        for (int i = 0; i < n; i++) { if (i > 0) sb.append(','); sb.append('?'); }
        return sb.toString();
    }

    // ============================================================
    // POJOs
    // ============================================================
    /** Snapshot of one practitioner's taxonomies in cpe_master, used for the diff check. */
    static class MasterSnapshot {
        static final MasterSnapshot EMPTY = new MasterSnapshot(new LinkedHashSet<>(), null);
        final Set<String> codes;          // all distinct taxonomy_code values across all rows for this NPI
        final String primaryCode;          // the code with is_primary=1 (first encountered if more than one)
        MasterSnapshot(Set<String> codes, String primaryCode) {
            this.codes = codes;
            this.primaryCode = primaryCode;
        }
    }

    /** A practitioner the tool decided to NOT amend, because master already matches NPPES. */
    private static class SkipRow {
        final String npi;
        final String hccId;
        final String reason;
        SkipRow(String npi, String hccId, String reason) {
            this.npi = npi; this.hccId = hccId; this.reason = reason;
        }
    }

    /** Result of decide(): MATCH (no amend) or STAGE (amend with merged taxonomy list). */
    static class Decision {
        enum Kind { MATCH, STAGE }
        final Kind kind;
        final String reason;
        final List<TaxonomyEntry> staged;  // populated only for STAGE; null for MATCH
        private Decision(Kind k, String r, List<TaxonomyEntry> s) {
            this.kind = k; this.reason = r; this.staged = s;
        }
        static Decision match(String reason) { return new Decision(Kind.MATCH, reason, null); }
        static Decision stage(String reason, List<TaxonomyEntry> staged) { return new Decision(Kind.STAGE, reason, staged); }
    }

    static class TaxonomyEntry {
        final String taxonomyCode;
        final String origin;       // "claims" or "NPPES" -- audit only, not stored
        int seqNum;
        boolean isPrimary;
        boolean isSecondary;
        TaxonomyEntry(String c, String o) { this.taxonomyCode = c; this.origin = o; }
        @Override public String toString() {
            return taxonomyCode + "[seq=" + seqNum + ",p=" + isPrimary + ",s=" + isSecondary + ",src=" + origin + "]";
        }
    }

    private static class RepairRow {
        final String npi;
        final String hccId;
        final List<TaxonomyEntry> taxonomies;
        long entityId;
        RepairRow(String npi, String hccId, List<TaxonomyEntry> ts) {
            this.npi = npi; this.hccId = hccId; this.taxonomies = ts;
        }
    }
}
