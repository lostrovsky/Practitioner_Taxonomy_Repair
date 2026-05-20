package com.ust.utils;

import java.net.URI;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.sql.CallableStatement;
import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.sql.Statement;
import java.sql.Types;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.logging.Level;
import java.util.logging.Logger;

/**
 * One-off remediation tool. For each practitioner that has at least one
 * NPPES-source taxonomy in cpe_master, re-fetch NPPES via NPPESClient,
 * compute the corrected primary designation (NPPES's current is_primary
 * code wins), and stage a complete-overlay taxonomy list in cpe_repair.
 *
 * Reads (no writes):
 *   cpe_master.practitioner             -- to get practitioner_hcc_id
 *   cpe_master.practitioner_taxonomy    -- to get the existing claims+NPPES rows
 *   cpe_xref.taxonomy                   -- to look up display_name from code
 *
 * Writes (only):
 *   cpe_repair.batch                    -- one new row (the batch this tool is producing)
 *   cpe_repair.practitioner_repair      -- one row per practitioner staged
 *   cpe_repair.practitioner_taxonomy    -- one row per (practitioner, taxonomy) combination
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
 *   --description=<text>                (optional: stored on cpe_repair.batch.description for audit)
 *   --dry-run                           (optional: do everything except the final INSERTs; logs what would be staged)
 */
public class PractitionerTaxonomyRepair {

    private static final String DEFAULT_LOG_OUTPUT = "both";

    private static Logger logger;
    private static ConfigLoader config;
    private static DBManager dbManager;
    private static String masterSchema;
    private static String repairSchema;
    private static String xrefSchema;
    private static String npiQueryOverride;   // optional db.npi_query; null/blank => use built-in default

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

            // 2. Pre-load supporting data: hcc_id per NPI, claims-source taxonomies per NPI.
            Map<String, String> hccIdByNpi = loadHccIdsByNpi(npis);
            Map<String, List<MasterTaxonomy>> claimsByNpi = loadClaimsTaxonomiesByNpi(npis);

            // 3. NPPES lookup loop -- builds the corrected taxonomy lists.
            NPPESClient nppesClient = new NPPESClient(logger);
            List<RepairRow> staged = new ArrayList<>();
            int notFound = 0;

            for (String npi : npis) {
                String hccId = hccIdByNpi.get(npi);
                if (hccId == null) {
                    logger.warning("Skipping NPI " + npi + ": not found in " + masterSchema + ".practitioner");
                    continue;
                }
                NPPESClient.NPPESResult r = nppesClient.lookupNpi(npi);
                if (!r.isFound() || !r.hasTaxonomyCodes()) {
                    notFound++;
                    logger.warning("Skipping NPI " + npi + ": NPPES not found or no taxonomies");
                    continue;
                }

                // Combine claims-source (preserved) + current NPPES taxonomies (deduped by code).
                Set<String> seenCodes = new LinkedHashSet<>();
                List<TaxonomyEntry> combined = new ArrayList<>();
                for (MasterTaxonomy m : claimsByNpi.getOrDefault(npi, List.of())) {
                    if (seenCodes.add(m.taxonomyCode)) {
                        combined.add(new TaxonomyEntry(m.taxonomyCode, "claims"));
                    }
                }
                for (String c : r.getTaxonomyCodes()) {
                    if (seenCodes.add(c)) {
                        combined.add(new TaxonomyEntry(c, "NPPES"));
                    }
                }

                // Apply primary designation: NPPES's current primary code wins.
                String nppesPrimaryCode = r.getPrimaryTaxonomyCode();
                if (nppesPrimaryCode == null) {
                    logger.warning("NPI " + npi + ": NPPES result has no primary marker; primary slot will be empty");
                }
                int seq = 1;
                for (TaxonomyEntry e : combined) {
                    e.seqNum = seq++;
                    e.isPrimary = nppesPrimaryCode != null && nppesPrimaryCode.equals(e.taxonomyCode);
                    e.isSecondary = false;  // repair scope: not picking secondary
                }

                staged.add(new RepairRow(npi, hccId, combined));
            }

            logger.info("Staged in memory: " + staged.size() + " practitioners; NPPES-not-found: " + notFound);

            if (dryRun) {
                logger.info("--dry-run set: skipping all INSERTs. Sample of first 5 staged rows:");
                for (int i = 0; i < Math.min(5, staged.size()); i++) {
                    RepairRow rr = staged.get(i);
                    logger.info("  " + rr.npi + "  hcc_id=" + rr.hccId + "  taxonomies=" + rr.taxonomies);
                }
                return;
            }

            // 4. Resolve taxonomy_name for every code in scope (single batched lookup).
            Set<String> allCodes = new HashSet<>();
            for (RepairRow rr : staged) {
                for (TaxonomyEntry e : rr.taxonomies) allCodes.add(e.taxonomyCode);
            }
            Map<String, String> codeToName = lookupTaxonomyNames(allCodes);

            // 5. Persist: one batch + N practitioner_repair + M practitioner_taxonomy.
            long batchId = persistBatch(description, staged, codeToName);
            logger.info("Repair batch " + batchId + " staged successfully. " +
                    "Run the loader with --RUN_ID=" + batchId + " against the practitioner_taxonomy_repair call folder.");
            // Emit on stdout too so wrapper scripts can capture without parsing the log.
            System.out.println("BATCH_ID=" + batchId);
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
        xrefSchema   = nonBlank(config.get("db.xref.schema"),   "cpe_xref");
        validateSchemaName(masterSchema);
        validateSchemaName(repairSchema);
        validateSchemaName(xrefSchema);
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

    // ============================================================
    // Read paths -- all targeting cpe_master (read-only) and cpe_xref
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

    private static Map<String, List<MasterTaxonomy>> loadClaimsTaxonomiesByNpi(List<String> npis) throws SQLException {
        Map<String, List<MasterTaxonomy>> map = new LinkedHashMap<>();
        if (npis.isEmpty()) return map;
        // Pull both claims and NPPES rows from master so we can preserve the existing taxonomy code list;
        // we only filter on source='claims' to mark which were already-trusted vs we'll get from NPPES live.
        String sql = "SELECT npi, taxonomy_code, taxonomy_source FROM " + masterSchema + ".practitioner_taxonomy " +
                "WHERE taxonomy_source = 'claims' AND npi IN (" + commaPlaceholders(npis.size()) + ")";
        Connection conn = dbManager.getConnection();
        try (PreparedStatement ps = conn.prepareStatement(sql)) {
            for (int i = 0; i < npis.size(); i++) ps.setString(i + 1, npis.get(i));
            try (ResultSet rs = ps.executeQuery()) {
                while (rs.next()) {
                    map.computeIfAbsent(rs.getString(1), k -> new ArrayList<>())
                       .add(new MasterTaxonomy(rs.getString(2), rs.getString(3)));
                }
            }
        }
        return map;
    }

    private static Map<String, String> lookupTaxonomyNames(Set<String> codes) throws SQLException {
        Map<String, String> map = new HashMap<>();
        if (codes.isEmpty()) return map;
        List<String> codeList = new ArrayList<>(codes);
        String sql = "SELECT code, display_name FROM " + xrefSchema + ".taxonomy WHERE code IN ("
                + commaPlaceholders(codeList.size()) + ")";
        Connection conn = dbManager.getConnection();
        try (PreparedStatement ps = conn.prepareStatement(sql)) {
            for (int i = 0; i < codeList.size(); i++) ps.setString(i + 1, codeList.get(i));
            try (ResultSet rs = ps.executeQuery()) {
                while (rs.next()) map.put(rs.getString(1), rs.getString(2));
            }
        }
        // Anything not found → log; the SQL INSERT will use NULL for taxonomy_name.
        for (String c : codes) if (!map.containsKey(c))
            logger.warning("No display_name in " + xrefSchema + ".taxonomy for code " + c + " (will insert NULL)");
        return map;
    }

    // ============================================================
    // Write path -- INSERTs into cpe_repair only
    // ============================================================
    private static long persistBatch(String description, List<RepairRow> rows, Map<String, String> codeToName) throws SQLException {
        Connection conn = dbManager.getConnection();
        boolean prevAutoCommit = conn.getAutoCommit();
        try {
            conn.setAutoCommit(false);

            // 1. cpe_repair.batch
            long batchId;
            String batchSql = "INSERT INTO " + repairSchema + ".batch (description) OUTPUT INSERTED.batch_id VALUES (?)";
            try (PreparedStatement ps = conn.prepareStatement(batchSql)) {
                if (description == null) ps.setNull(1, Types.NVARCHAR); else ps.setString(1, description);
                try (ResultSet rs = ps.executeQuery()) {
                    if (!rs.next()) throw new SQLException("INSERT into batch returned no row");
                    batchId = rs.getLong(1);
                }
            }
            logger.info("Created cpe_repair.batch row: batch_id=" + batchId);

            // 2. cpe_repair.practitioner_repair (one per RepairRow); collect entity_ids back
            String prSql = "INSERT INTO " + repairSchema + ".practitioner_repair " +
                    "(batch_id, npi, practitioner_hcc_id) OUTPUT INSERTED.entity_id VALUES (?, ?, ?)";
            try (PreparedStatement ps = conn.prepareStatement(prSql)) {
                for (RepairRow rr : rows) {
                    ps.setLong(1, batchId);
                    ps.setString(2, rr.npi);
                    ps.setString(3, rr.hccId);
                    try (ResultSet rs = ps.executeQuery()) {
                        if (!rs.next()) throw new SQLException("INSERT into practitioner_repair returned no row for NPI " + rr.npi);
                        rr.entityId = rs.getLong(1);
                    }
                }
            }

            // 3. cpe_repair.practitioner_taxonomy in batches
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
            logger.info("Inserted " + rows.size() + " practitioner_repair rows and " + taxRows + " practitioner_taxonomy rows");

            conn.commit();
            return batchId;
        } catch (SQLException e) {
            try { conn.rollback(); logger.warning("persistBatch rolled back due to: " + e.getMessage()); } catch (SQLException ignored) {}
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
    private static class MasterTaxonomy {
        final String taxonomyCode;
        final String taxonomySource;
        MasterTaxonomy(String c, String s) { this.taxonomyCode = c; this.taxonomySource = s; }
    }

    private static class TaxonomyEntry {
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
