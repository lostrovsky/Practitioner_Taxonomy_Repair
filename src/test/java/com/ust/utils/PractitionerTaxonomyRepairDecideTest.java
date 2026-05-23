package com.ust.utils;

import com.ust.utils.PractitionerTaxonomyRepair.Decision;
import com.ust.utils.PractitionerTaxonomyRepair.MasterSnapshot;
import com.ust.utils.PractitionerTaxonomyRepair.TaxonomyEntry;
import org.junit.jupiter.api.Test;

import java.util.Arrays;
import java.util.Collections;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Set;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * Tests for {@link PractitionerTaxonomyRepair#decide(String, List, MasterSnapshot)} — the
 * pure-function decision/merge logic. Each test sets up a fictional NPPES result + master
 * snapshot, calls decide(), and asserts on Decision.kind, reason, and (for STAGE) the
 * staged taxonomy list's shape + primary/secondary flags + dedup + ordering.
 */
class PractitionerTaxonomyRepairDecideTest {

    // ---------- helpers ----------
    private static MasterSnapshot master(String primary, String... codes) {
        Set<String> set = new LinkedHashSet<>(Arrays.asList(codes));
        return new MasterSnapshot(set, primary);
    }

    private static String codeOf(List<TaxonomyEntry> staged, int i) {
        return staged.get(i).taxonomyCode;
    }

    private static TaxonomyEntry findByCode(List<TaxonomyEntry> staged, String code) {
        for (TaxonomyEntry e : staged) if (e.taxonomyCode.equals(code)) return e;
        return null;
    }

    // ---------- MATCH (skip) cases ----------

    @Test
    void match_exactSetAndPrimary() {
        // NPPES = {A primary, B}; master = {A primary, B}
        Decision d = PractitionerTaxonomyRepair.decide("A", Arrays.asList("A", "B"), master("A", "A", "B"));
        assertEquals(Decision.Kind.MATCH, d.kind);
        assertNull(d.staged);
        assertTrue(d.reason.contains("master already matches NPPES"));
    }

    @Test
    void match_masterHasExtraCodesNppesDoesnt() {
        // NPPES = {A primary, B}; master = {A primary, B, C, D claims-only}. Still a match --
        // master's extras don't trigger a stage (we have no signal NPPES wants them removed).
        Decision d = PractitionerTaxonomyRepair.decide("A", Arrays.asList("A", "B"), master("A", "A", "B", "C", "D"));
        assertEquals(Decision.Kind.MATCH, d.kind);
    }

    @Test
    void match_singleCodeBothSides() {
        Decision d = PractitionerTaxonomyRepair.decide("A", Collections.singletonList("A"), master("A", "A"));
        assertEquals(Decision.Kind.MATCH, d.kind);
    }

    // ---------- STAGE (amend) cases ----------

    @Test
    void stage_primaryMismatch_sameSet() {
        // Classic v1.4.0-bug case: master has the right codes but wrong is_primary.
        // NPPES says A is primary; master has B marked primary.
        Decision d = PractitionerTaxonomyRepair.decide("A", Arrays.asList("A", "B"), master("B", "A", "B"));
        assertEquals(Decision.Kind.STAGE, d.kind);
        assertNotNull(d.staged);
        assertEquals(2, d.staged.size());
        // Primary is A (NPPES wins)
        TaxonomyEntry a = findByCode(d.staged, "A");
        assertTrue(a.isPrimary,   "A must be marked primary (NPPES wins)");
        assertFalse(a.isSecondary);
        // B is demoted to secondary (1st non-primary NPPES code)
        TaxonomyEntry b = findByCode(d.staged, "B");
        assertFalse(b.isPrimary);
        assertTrue(b.isSecondary, "B must be marked secondary (2nd NPPES code)");
        assertTrue(d.reason.contains("primary mismatch"));
        assertTrue(d.reason.contains("master=B"));
        assertTrue(d.reason.contains("NPPES=A"));
    }

    @Test
    void stage_nppesHasNewCodeMasterDoesnt() {
        // NPPES knows a code master doesn't have (e.g. provider added it post-load).
        // Master primary matches NPPES primary, but the set diverges.
        Decision d = PractitionerTaxonomyRepair.decide("A", Arrays.asList("A", "D"), master("A", "A"));
        assertEquals(Decision.Kind.STAGE, d.kind);
        // A primary, D secondary (1st non-primary NPPES)
        assertTrue(findByCode(d.staged, "A").isPrimary);
        assertTrue(findByCode(d.staged, "D").isSecondary);
        assertTrue(d.reason.contains("NPPES has codes not in master"));
    }

    @Test
    void stage_masterExtrasPreservedAsOthers() {
        // NPPES = {A primary, B}; master = {A primary, B, C, D}. Wait -- this is a MATCH case
        // per the rule "master may have extras". Different scenario: force a stage by varying
        // primary. NPPES primary = A, master primary = B, master extras = C, D.
        Decision d = PractitionerTaxonomyRepair.decide(
                "A", Arrays.asList("A", "B"), master("B", "A", "B", "C", "D"));
        assertEquals(Decision.Kind.STAGE, d.kind);
        assertEquals(4, d.staged.size(), "all 4 codes present (NPPES 2 + master extras 2)");
        // Order: A primary, B secondary, then NPPES exhausted -> master-only codes C, D
        assertEquals("A", codeOf(d.staged, 0));
        assertEquals("B", codeOf(d.staged, 1));
        // C and D in either order (master.codes is LinkedHashSet so insertion order preserved)
        assertEquals("C", codeOf(d.staged, 2));
        assertEquals("D", codeOf(d.staged, 3));
        // Neither C nor D is primary/secondary
        assertFalse(findByCode(d.staged, "C").isPrimary);
        assertFalse(findByCode(d.staged, "C").isSecondary);
        assertFalse(findByCode(d.staged, "D").isPrimary);
        assertFalse(findByCode(d.staged, "D").isSecondary);
        // seq_num assigned 1..N
        assertEquals(1, d.staged.get(0).seqNum);
        assertEquals(4, d.staged.get(3).seqNum);
    }

    @Test
    void stage_nppesSingleCode_noSecondary() {
        // NPPES has only one code. Master has the wrong one as primary.
        // Stage: primary=A, NO secondary, no others.
        Decision d = PractitionerTaxonomyRepair.decide("A", Collections.singletonList("A"), master("X", "X"));
        assertEquals(Decision.Kind.STAGE, d.kind);
        // 2 codes total: A (primary, from NPPES) + X (master-only "other")
        assertEquals(2, d.staged.size());
        assertTrue(findByCode(d.staged, "A").isPrimary);
        // No row should have isSecondary=true (NPPES only gave us one code)
        for (TaxonomyEntry e : d.staged) assertFalse(e.isSecondary,
                "no row should be marked secondary when NPPES returns a single code");
    }

    @Test
    void stage_masterEmpty() {
        // NPPES has codes; master has none (practitioner not yet in cpe_master.practitioner_taxonomy).
        // Stage: primary from NPPES + secondary + remaining NPPES.
        Decision d = PractitionerTaxonomyRepair.decide(
                "A", Arrays.asList("A", "B", "C"), MasterSnapshot.EMPTY);
        assertEquals(Decision.Kind.STAGE, d.kind);
        assertEquals(3, d.staged.size());
        assertTrue(findByCode(d.staged, "A").isPrimary);
        assertTrue(findByCode(d.staged, "B").isSecondary);
        assertFalse(findByCode(d.staged, "C").isPrimary);
        assertFalse(findByCode(d.staged, "C").isSecondary);
    }

    @Test
    void stage_primaryAndSecondaryDedup_doesNotDoubleAdd() {
        // Defensive: if NPPES somehow returns the primary code in position 0 AND position 1
        // (duplicate), the secondary search picks the next distinct code (or null if none).
        // Here NPPES returns [A, A, B] -- defensive case. Secondary should be B, not the
        // duplicate A.
        Decision d = PractitionerTaxonomyRepair.decide(
                "A", Arrays.asList("A", "A", "B"), master("B", "A", "B"));
        assertEquals(Decision.Kind.STAGE, d.kind);
        // 2 distinct codes (A, B) since A appears twice in NPPES
        assertEquals(2, d.staged.size());
        assertTrue(findByCode(d.staged, "A").isPrimary);
        assertTrue(findByCode(d.staged, "B").isSecondary);
    }

    @Test
    void stage_primaryIsAlwaysFirstWithSeq1() {
        Decision d = PractitionerTaxonomyRepair.decide(
                "Z", Arrays.asList("Z", "Y", "X"), master("Y", "Y", "X"));
        assertEquals(Decision.Kind.STAGE, d.kind);
        assertEquals("Z", codeOf(d.staged, 0));
        assertEquals(1, d.staged.get(0).seqNum);
        assertTrue(d.staged.get(0).isPrimary);
    }

    @Test
    void stage_isPrimaryAndIsSecondaryAreMutuallyExclusive() {
        // Sanity: no staged row should have BOTH flags set.
        Decision d = PractitionerTaxonomyRepair.decide(
                "A", Arrays.asList("A", "B", "C"), master("B", "A", "B", "C"));
        assertEquals(Decision.Kind.STAGE, d.kind);
        for (TaxonomyEntry e : d.staged) {
            assertFalse(e.isPrimary && e.isSecondary,
                    "row " + e.taxonomyCode + " has both is_primary and is_secondary set");
        }
    }
}
