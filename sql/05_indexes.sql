-- =====================================================================
-- Practo Doctor Appointments Database — CP3 Index Design
-- Team T0095 Dwelling
--
-- Run after CP1/CP2 (schema + seed load) on the same database:
--   psql -d <database> -f sql/05_indexes.sql
--
-- Scope of this file
-- ------------------
-- Adds 11 performance indexes to the `practo` schema. No table, column,
-- constraint or existing index is modified: the 19 implicit PK/UNIQUE
-- indexes from CP2 stay exactly as they are, and every statement below is
-- repeatable (CREATE INDEX IF NOT EXISTS).
--
-- Design rules applied
-- --------------------
--   * Equality columns before range/Sort columns, so a single B-tree can
--     serve WHERE + ORDER BY (e.g. patient_id, status, slot_start).
--   * Partial indexes only where a status is genuinely a small subset
--     (BOOKED = 1,823 of 150,000 rows; BOOKED/CHECKED_IN and not yet
--     closed; COMPLETED + PENDING). A partial index on COMPLETED alone was
--     rejected: COMPLETED is 121,409 of 150,000 rows (81%), so it would not
--     be more selective than the plain index.
--   * Covering INCLUDE columns so the report queries can use index-only
--     scans on appointments instead of reading the 21 MB heap.
--   * One GIN index, only where an array predicate is selective: R10's
--     allergies @> ARRAY[...] (1,737 of 40,000 patients) uses the index.
--     A GIN index on doctors.languages was evaluated and removed: 'Tamil'
--     matches 360 of 3,000 doctors, and the planner kept choosing a
--     sequential scan, so it would only have added write cost.
--   * No duplicate leading columns: the one index that starts with
--     slot_start also carries appointment_id as a tie-breaker/keyset
--     column, replacing two nearly identical slot indexes.
--
-- Every index is linked to the workload query IDs it serves.
-- =====================================================================
SET search_path TO practo;

-- ---------------------------------------------------------------------
-- 1. appointments (patient_id, status, slot_start)      -> R04
--    "My appointments": one patient's BOOKED visits, ordered by slot_start.
--    Equality on patient_id/status, index-ordered ORDER BY slot_start.
-- ---------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_appt_patient_status_slot
    ON appointments (patient_id, status, slot_start);

-- ---------------------------------------------------------------------
-- 2. appointments (doctor_id, slot_start)               -> R03, R05, R19, W05
--    Doctor queue / slot picker / "doctor on leave" update:
--    one doctor over a date range, or one doctor+slot equality probe for
--    the NOT EXISTS anti-join in R03.
-- ---------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_appt_doctor_slot
    ON appointments (doctor_id, slot_start);

-- ---------------------------------------------------------------------
-- 3. appointments (patient_id, doctor_id, slot_start)   -> R11
--    Anti-join "has this patient already booked a later appointment with
--    this doctor?": equality on the first two columns then a range on
--    slot_start, which is exactly this composite's prefix.
-- ---------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_appt_patient_doctor_slot
    ON appointments (patient_id, doctor_id, slot_start);

-- ---------------------------------------------------------------------
-- 4. appointments (slot_start, appointment_id) INCLUDE (...)
--                                          -> R08, R09, R12, R16, R17,
--                                             R20, R22, R25
--    The single covering index for all date-range reports and for the
--    support console's newest-first page. slot_start is the range key;
--    appointment_id is the tie-breaker so a backward index scan satisfies
--    ORDER BY slot_start DESC for R22 without a sort. The INCLUDE columns
--    are the ones those queries read, enabling index-only scans:
--      status, consult_type  -> R08, R12, R09, R20
--      patient_id, doctor_id -> R17, R25, R22
--      clinic_id, fee        -> R16 (fee is read from the heap only for
--                               the 6,362 June PAID rows)
-- ---------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_appt_slot_start_appt
    ON appointments (slot_start, appointment_id)
    INCLUDE (status, consult_type, patient_id, doctor_id, clinic_id);

-- ---------------------------------------------------------------------
-- 5. appointments partial: unpaid completed visits      -> R21
--    Only 24,683 of 150,000 rows qualify, and they are stored in
--    slot_start DESC order, so the "latest 100 unpaid" page is an index
--    scan with no sort at all. Partial predicate matches the query exactly.
-- ---------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_appt_completed_pending
    ON appointments (slot_start DESC)
    INCLUDE (patient_id, clinic_id, fee)
    WHERE status = 'COMPLETED' AND payment_status = 'PENDING';

-- ---------------------------------------------------------------------
-- 6. appointments partial: open in-clinic bookings      -> W02
--    Reception check-in looks for the earliest BOOKED in-clinic
--    appointment of a day. BOOKED is only 1,823 rows, so this partial
--    index is tiny and answers ORDER BY slot_start LIMIT 1 directly.
-- ---------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_appt_booked_inclinic_slot
    ON appointments (slot_start)
    WHERE status = 'BOOKED' AND consult_type = 'IN_CLINIC';

-- ---------------------------------------------------------------------
-- 7. appointments partial: unclosed open visits         -> W04
--    The nightly no-show job touches BOOKED/CHECKED_IN rows with no
--    consult_ended_at. The predicate is identical to the query's, and the
--    index is on slot_end because the job filters by it.
-- ---------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_appt_pending_noshow_slot
    ON appointments (slot_end)
    WHERE status IN ('BOOKED', 'CHECKED_IN') AND consult_ended_at IS NULL;

-- ---------------------------------------------------------------------
-- 8. doctor_schedules (clinic_id) WHERE clinic_id IS NOT NULL  -> R13
--    Anti-join "clinics with no schedule". Video schedule rows have
--    clinic_id IS NULL and are of no interest to the anti-join; excluding
--    them keeps the index small and lets PostgreSQL answer R13 with an
--    index-only scan over the 24,600 in-clinic schedule rows.
-- ---------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_sched_clinic
    ON doctor_schedules (clinic_id)
    WHERE clinic_id IS NOT NULL;

-- ---------------------------------------------------------------------
-- 9. prescriptions (follow_up_date) WHERE follow_up_date IS NOT NULL -> R11
--    Only 29,050 of the 97,234 prescriptions carry a follow_up_date, and R11
--    asks for 1-7 July; the partial index starts from that window instead of
--    scanning the whole table.
-- ---------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_rx_followup
    ON prescriptions (follow_up_date)
    WHERE follow_up_date IS NOT NULL;

-- ---------------------------------------------------------------------
-- 10. prescriptions (issued_at) INCLUDE (appointment_id)   -> R15
--     June-2026 prescription volume per medicine/specialization. Lets the
--     planner start from the June range (5,503 prescriptions) rather than
--     from all 243,085 prescription_items, and INCLUDE supplies
--     appointment_id without a heap visit.
-- ---------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_rx_issued
    ON prescriptions (issued_at)
    INCLUDE (appointment_id);

-- ---------------------------------------------------------------------
-- 11. patients GIN (allergies)                             -> R10
--     Array containment (@> ARRAY['Penicillin']) has no B-tree access
--     path. GIN finds the 1,737 allergic patients directly; the medicine
--     ILIKE '%amoxicillin%' predicate is intentionally left as a filter
--     because a trigram index over 243,085 items (16,206 matches, 6.7%)
--     would not be selective enough to pay for its write cost.
-- ---------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_patients_allergies
    ON patients USING gin (allergies);

-- Refresh planner statistics so the new indexes are costed correctly.
ANALYZE;

-- ---------------------------------------------------------------------
-- Post-creation inventory (for the report / verification)
-- ---------------------------------------------------------------------
SELECT c.relname AS index_name,
       pg_size_pretty(pg_relation_size(c.oid)) AS size,
       i.indisvalid AS valid
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
JOIN pg_index i     ON i.indexrelid = c.oid
WHERE n.nspname = 'practo' AND c.relname LIKE 'idx_%'
ORDER BY c.relname;
