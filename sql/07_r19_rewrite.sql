-- =====================================================================
-- CP4: set-based rewrite of R19 (large-dataset bottleneck)
--
-- The workload file queries/workload_30.sql is NOT modified. This file
-- contains only the alternative used for the R19 comparison.
--
-- Original R19 shape:
--   SELECT d.doctor_id, d.full_name,
--          (SELECT count(*) ... WHERE a.doctor_id = d.doctor_id ...) AS june_consults,
--          (SELECT max(a.consult_ended_at) ... WHERE a.doctor_id = d.doctor_id) AS last_consult_at
--   FROM doctors d
--   WHERE EXISTS (... Bengaluru clinic ...)
--   ORDER BY june_consults DESC;
--
-- Rewrite: aggregate appointments once, then LEFT JOIN, preserving the
-- original's 0 / NULL values for doctors with no matching appointments.
--
-- Equivalence evidence and limitation (2026-11-22):
--   seed DB Practo: 480/480 rows, 0 differences, june sum 1083 (FULL result)
--   large DB sample: 40/40 doctors, 0 differences, june sum 432 (SAMPLE only)
--   Full large-dataset equivalence is NOT established: only 40 of 9,600
--   doctors were compared. The original full query is estimated at ~38.5 min
--   by extrapolation and was not completed. Do not claim full 3M-row
--   equivalence from this file.
--   See benchmarks/results/large/experiments/r19_equivalence_*.txt
--
-- Measured on practo_t0095_large (3,000,000 appointments, only the PK):
--   original: timed out at 60 s (40-doctor sample alone took 9,630 ms)
--   rewrite:  349.5 ms first run; 262.2 / 248.2 / 242.3 ms warm
-- =====================================================================
SET search_path TO practo;

SELECT d.doctor_id,
       d.full_name,
       coalesce(g.june_consults, 0) AS june_consults,
       g.last_consult_at
FROM doctors d
LEFT JOIN (
    SELECT doctor_id,
           count(*) FILTER (
               WHERE status = 'COMPLETED'
                 AND slot_start >= '2026-06-01'
                 AND slot_start <  '2026-07-01'
           ) AS june_consults,
           max(consult_ended_at) AS last_consult_at
    FROM appointments
    GROUP BY doctor_id
) g ON g.doctor_id = d.doctor_id
WHERE EXISTS (
    SELECT 1
    FROM doctor_schedules sc
    JOIN clinics c ON c.clinic_id = sc.clinic_id
    WHERE sc.doctor_id = d.doctor_id
      AND c.city_id = 1
)
ORDER BY june_consults DESC;
