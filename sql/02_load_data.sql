-- =====================================================================
-- Practo Doctor Appointments Database — Seed Data Loading
-- Team T0095 Dwelling
--
-- Prerequisites:
--   1. Run sql/01_schema.sql first to create the schema and tables.
--   2. Unzip seed_data.zip in the project root (creates seed_data/).
--
-- Usage:
--   psql -d <database> -f sql/02_load_data.sql
--
-- Tables are loaded in dependency order (parents before children).
-- Uses \copy which runs client-side and reads local CSV files.
-- =====================================================================

\set ON_ERROR_STOP on
BEGIN;
SET search_path TO practo;

-- =====================================================================
-- 1. cities — No dependencies (root table)
-- =====================================================================
\copy cities FROM 'seed_data/cities.csv' WITH (FORMAT csv, HEADER true)

-- =====================================================================
-- 2. specializations — No dependencies (root table)
-- =====================================================================
\copy specializations FROM 'seed_data/specializations.csv' WITH (FORMAT csv, HEADER true)

-- =====================================================================
-- 3. doctors — No dependencies on other loaded tables
-- =====================================================================
\copy doctors FROM 'seed_data/doctors.csv' WITH (FORMAT csv, HEADER true)

-- =====================================================================
-- 4. doctor_specializations — Depends on: doctors, specializations
-- =====================================================================
\copy doctor_specializations FROM 'seed_data/doctor_specializations.csv' WITH (FORMAT csv, HEADER true)

-- =====================================================================
-- 5. clinics — Depends on: cities
-- =====================================================================
\copy clinics FROM 'seed_data/clinics.csv' WITH (FORMAT csv, HEADER true)

-- =====================================================================
-- 6. doctor_schedules — Depends on: doctors, clinics
-- =====================================================================
\copy doctor_schedules FROM 'seed_data/doctor_schedules.csv' WITH (FORMAT csv, HEADER true)

-- =====================================================================
-- 7. patients — Depends on: cities
-- =====================================================================
\copy patients FROM 'seed_data/patients.csv' WITH (FORMAT csv, HEADER true)

-- =====================================================================
-- 8. appointments — Depends on: patients, doctors, clinics
-- =====================================================================
\copy appointments FROM 'seed_data/appointments.csv' WITH (FORMAT csv, HEADER true)

-- =====================================================================
-- 9. prescriptions — Depends on: appointments
-- =====================================================================
\copy prescriptions FROM 'seed_data/prescriptions.csv' WITH (FORMAT csv, HEADER true)

-- =====================================================================
-- 10. prescription_items — Depends on: prescriptions
-- =====================================================================
\copy prescription_items FROM 'seed_data/prescription_items.csv' WITH (FORMAT csv, HEADER true)

-- =====================================================================
-- 11. doctor_reviews — Depends on: appointments
-- =====================================================================
\copy doctor_reviews FROM 'seed_data/doctor_reviews.csv' WITH (FORMAT csv, HEADER true)

-- =====================================================================
-- Update table statistics for the query planner
-- =====================================================================
ANALYZE;

-- =====================================================================
-- Verify row counts
-- =====================================================================
SELECT 'cities' AS table_name, count(*) AS rows FROM cities
UNION ALL SELECT 'specializations', count(*) FROM specializations
UNION ALL SELECT 'doctors', count(*) FROM doctors
UNION ALL SELECT 'doctor_specializations', count(*) FROM doctor_specializations
UNION ALL SELECT 'clinics', count(*) FROM clinics
UNION ALL SELECT 'doctor_schedules', count(*) FROM doctor_schedules
UNION ALL SELECT 'patients', count(*) FROM patients
UNION ALL SELECT 'appointments', count(*) FROM appointments
UNION ALL SELECT 'prescriptions', count(*) FROM prescriptions
UNION ALL SELECT 'prescription_items', count(*) FROM prescription_items
UNION ALL SELECT 'doctor_reviews', count(*) FROM doctor_reviews
ORDER BY table_name;

COMMIT;
