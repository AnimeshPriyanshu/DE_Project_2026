-- =====================================================================
-- Practo Doctor Appointments Database — Schema
-- Team T0095 Dwelling
--
-- Run on a fresh PostgreSQL 15+ database:
--   psql -d <database> -f sql/01_schema.sql
--
-- Creates the "practo" schema with 11 tables, all constraints (PK, FK,
-- UNIQUE, NOT NULL, CHECK). The partial unique index enforces the
-- at-most-one-primary-specialization rule.
-- =====================================================================

-- Start clean: drop the schema if it already exists (CASCADE removes
-- all objects inside it).
DROP SCHEMA IF EXISTS practo CASCADE;
CREATE SCHEMA practo;
SET search_path TO practo;

-- =====================================================================
-- 1. cities — Reference table of Indian cities
-- =====================================================================
CREATE TABLE cities (
    city_id     INTEGER     PRIMARY KEY,
    city_name   VARCHAR(60) NOT NULL,
    state       VARCHAR(60) NOT NULL,

    -- City names must be unique within a state
    CONSTRAINT uq_cities_name_state UNIQUE (city_name, state)
);

-- =====================================================================
-- 2. specializations — Medical specializations offered on the platform
-- =====================================================================
CREATE TABLE specializations (
    spec_id     INTEGER     PRIMARY KEY,
    spec_name   VARCHAR(60) NOT NULL UNIQUE
);

-- =====================================================================
-- 3. doctors — Registered doctors on the platform
-- =====================================================================
CREATE TABLE doctors (
    doctor_id           INTEGER         PRIMARY KEY,
    full_name           VARCHAR(120)    NOT NULL,
    registration_no     VARCHAR(30)     NOT NULL UNIQUE,       -- Medical council registration; natural candidate key
    gender              CHAR(1)         NOT NULL,
    experience_years    INTEGER         NOT NULL,
    consultation_fee    NUMERIC(10, 2)  NOT NULL,              -- In-clinic fee; always present
    video_fee           NUMERIC(10, 2),                        -- NULL when the doctor does not offer video consultations
    languages           TEXT[]          NOT NULL,               -- PostgreSQL array of spoken languages
    is_verified         BOOLEAN         NOT NULL DEFAULT FALSE,
    joined_on           DATE            NOT NULL,

    -- CHECK constraints
    CONSTRAINT chk_doctors_gender         CHECK (gender IN ('M', 'F', 'X')),
    CONSTRAINT chk_doctors_experience     CHECK (experience_years >= 0),
    CONSTRAINT chk_doctors_consult_fee    CHECK (consultation_fee > 0),
    CONSTRAINT chk_doctors_video_fee      CHECK (video_fee IS NULL OR video_fee > 0),
    CONSTRAINT chk_doctors_reg_no_format  CHECK (registration_no ~ '^[A-Z]{2,4}MC-\d{6}$')
    -- Format observed: 4-letter state code + "MC-" + 6 digits, e.g. DLMC-010007
);

-- =====================================================================
-- 4. doctor_specializations — M:N relationship between doctors and
--    specializations, with at most one primary per doctor
-- =====================================================================
CREATE TABLE doctor_specializations (
    doctor_id   INTEGER     NOT NULL REFERENCES doctors (doctor_id)   ON DELETE CASCADE,
    spec_id     INTEGER     NOT NULL REFERENCES specializations (spec_id) ON DELETE RESTRICT,
    is_primary  BOOLEAN     NOT NULL DEFAULT FALSE,

    -- Each (doctor, specialization) pair is unique
    PRIMARY KEY (doctor_id, spec_id)
);
-- Business rule: at most one primary per doctor.  Enforced with a
-- partial unique index (which is the PostgreSQL-idiomatic way):
CREATE UNIQUE INDEX uq_doctor_one_primary
    ON doctor_specializations (doctor_id) WHERE is_primary;

-- =====================================================================
-- 5. clinics — Physical clinics where doctors consult
-- =====================================================================
CREATE TABLE clinics (
    clinic_id       INTEGER         PRIMARY KEY,
    clinic_name     VARCHAR(120)    NOT NULL,
    city_id         INTEGER         NOT NULL REFERENCES cities (city_id) ON DELETE RESTRICT,
    locality        VARCHAR(100)    NOT NULL,
    latitude        NUMERIC(9, 6)   NOT NULL,
    longitude       NUMERIC(9, 6)   NOT NULL,
    phone           VARCHAR(20)     NOT NULL,

    -- CHECK constraints
    CONSTRAINT chk_clinics_latitude   CHECK (latitude  BETWEEN -90  AND 90),
    CONSTRAINT chk_clinics_longitude  CHECK (longitude BETWEEN -180 AND 180)
);

-- =====================================================================
-- 6. doctor_schedules — Weekly recurring schedule blocks
--    A row says "this doctor works on <weekday> from <start_time> to
--    <end_time> at <clinic_id> (or video if NULL) with <slot_minutes>
--    minute slots".
-- =====================================================================
CREATE TABLE doctor_schedules (
    doctor_id       INTEGER     NOT NULL REFERENCES doctors (doctor_id) ON DELETE CASCADE,
    weekday         SMALLINT    NOT NULL,            -- ISO weekday: 1=Mon … 7=Sun
    start_time      TIME        NOT NULL,
    end_time        TIME        NOT NULL,
    clinic_id       INTEGER     REFERENCES clinics (clinic_id) ON DELETE RESTRICT,
                                                     -- NULL ⇒ video consultation slot
    slot_minutes    SMALLINT    NOT NULL,

    -- Composite PK: a doctor has one schedule block per weekday + start_time
    -- (clinic_id cannot be in PK because it is nullable for video slots)
    PRIMARY KEY (doctor_id, weekday, start_time),

    -- CHECK constraints
    CONSTRAINT chk_schedules_weekday      CHECK (weekday BETWEEN 1 AND 7),
    CONSTRAINT chk_schedules_time_order   CHECK (end_time > start_time),
    CONSTRAINT chk_schedules_slot_minutes CHECK (slot_minutes IN (10, 15, 20))
);

-- =====================================================================
-- 7. patients — Registered patients
-- =====================================================================
CREATE TABLE patients (
    patient_id      INTEGER             PRIMARY KEY,
    full_name       VARCHAR(120)        NOT NULL,
    phone           VARCHAR(15)         NOT NULL UNIQUE,        -- Mobile sign-in; candidate key
    email           VARCHAR(120)        UNIQUE,                 -- Candidate key; NULL for ~35% of patients
    dob             DATE                NOT NULL,
    gender          CHAR(1)             NOT NULL,
    blood_group     VARCHAR(5),                                 -- NULL when not recorded
    allergies       TEXT[],                                     -- PostgreSQL array; NULL when none
    city_id         INTEGER             NOT NULL REFERENCES cities (city_id) ON DELETE RESTRICT,
    created_at      TIMESTAMPTZ         NOT NULL DEFAULT NOW(),

    -- CHECK constraints
    CONSTRAINT chk_patients_gender      CHECK (gender IN ('M', 'F', 'X')),
    CONSTRAINT chk_patients_blood_group CHECK (
        blood_group IS NULL OR blood_group IN ('A+', 'A-', 'B+', 'B-', 'AB+', 'AB-', 'O+', 'O-')
    )
);

-- =====================================================================
-- 8. appointments — Every booked appointment on the platform
-- =====================================================================
CREATE TABLE appointments (
    appointment_id      INTEGER         PRIMARY KEY,
    patient_id          INTEGER         NOT NULL REFERENCES patients (patient_id)  ON DELETE RESTRICT,
    doctor_id           INTEGER         NOT NULL REFERENCES doctors (doctor_id)    ON DELETE RESTRICT,
    clinic_id           INTEGER         REFERENCES clinics (clinic_id)             ON DELETE RESTRICT,
                                                    -- NULL ⇒ video consultation
    consult_type        VARCHAR(10)     NOT NULL,
    booked_at           TIMESTAMPTZ     NOT NULL,
    slot_start          TIMESTAMPTZ     NOT NULL,
    slot_end            TIMESTAMPTZ     NOT NULL,
    reason              VARCHAR(200)    NOT NULL,
    status              VARCHAR(12)     NOT NULL,
    checked_in_at       TIMESTAMPTZ,              -- NULL for video / not yet checked in
    consult_started_at  TIMESTAMPTZ,              -- NULL until consultation starts
    consult_ended_at    TIMESTAMPTZ,              -- NULL until consultation ends
    fee                 NUMERIC(10, 2)  NOT NULL,
    payment_status      VARCHAR(10)     NOT NULL,

    -- CHECK constraints
    CONSTRAINT chk_appt_consult_type    CHECK (consult_type IN ('IN_CLINIC', 'VIDEO')),
    CONSTRAINT chk_appt_status          CHECK (status IN ('BOOKED', 'CHECKED_IN', 'COMPLETED', 'CANCELLED', 'NO_SHOW')),
    CONSTRAINT chk_appt_payment_status  CHECK (payment_status IN ('PENDING', 'PAID', 'REFUNDED')),
    CONSTRAINT chk_appt_slot_order      CHECK (slot_end > slot_start),
    CONSTRAINT chk_appt_fee_positive    CHECK (fee > 0),
    -- Video consultations have no clinic; in-clinic consultations must have a clinic
    CONSTRAINT chk_appt_clinic_type     CHECK (
        (consult_type = 'VIDEO'     AND clinic_id IS NULL) OR
        (consult_type = 'IN_CLINIC' AND clinic_id IS NOT NULL)
    ),
    -- Only in-clinic appointments can have a check-in timestamp
    CONSTRAINT chk_appt_checkin_clinic  CHECK (
        checked_in_at IS NULL OR consult_type = 'IN_CLINIC'
    ),
    -- Refunds only for cancelled appointments
    CONSTRAINT chk_appt_refund_cancel   CHECK (
        payment_status <> 'REFUNDED' OR status = 'CANCELLED'
    )
);

-- =====================================================================
-- 9. prescriptions — At most one prescription per appointment
-- =====================================================================
CREATE TABLE prescriptions (
    prescription_id     INTEGER         PRIMARY KEY,
    appointment_id      INTEGER         NOT NULL UNIQUE          -- 1:1 with appointment
                        REFERENCES appointments (appointment_id) ON DELETE CASCADE,
    diagnosis           VARCHAR(200)    NOT NULL,
    notes               TEXT,                                    -- Optional clinical notes
    follow_up_date      DATE,                                   -- NULL when no follow-up needed
    issued_at           TIMESTAMPTZ     NOT NULL
);

-- =====================================================================
-- 10. prescription_items — Medicines on a prescription (1:N)
-- =====================================================================
CREATE TABLE prescription_items (
    prescription_id     INTEGER     NOT NULL
                        REFERENCES prescriptions (prescription_id) ON DELETE CASCADE,
    line_no             SMALLINT    NOT NULL,
    medicine_name       VARCHAR(120) NOT NULL,
    dosage              VARCHAR(20)  NOT NULL,           -- Format: X-Y-Z (morning-afternoon-night)
    duration_days       INTEGER      NOT NULL,
    instructions        VARCHAR(200),                    -- Optional e.g. "After food"

    PRIMARY KEY (prescription_id, line_no),

    -- CHECK constraints
    CONSTRAINT chk_pi_line_no_positive    CHECK (line_no >= 1),
    CONSTRAINT chk_pi_duration_positive   CHECK (duration_days > 0),
    CONSTRAINT chk_pi_dosage_format       CHECK (dosage ~ '^\d+-\d+-\d+$')
    -- Validates the morning-afternoon-night dosage pattern (e.g. 1-0-1, 0-0-1)
);

-- =====================================================================
-- 11. doctor_reviews — Patient reviews; intended for completed consultations
-- =====================================================================
CREATE TABLE doctor_reviews (
    review_id           INTEGER         PRIMARY KEY,
    appointment_id      INTEGER         NOT NULL UNIQUE          -- One review per appointment
                        REFERENCES appointments (appointment_id) ON DELETE CASCADE,
    rating              SMALLINT        NOT NULL,
    recommends          BOOLEAN         NOT NULL,
    wait_time_bucket    VARCHAR(15),                             -- e.g. "<15 min", "30-60 min", ">1 hr"
    review_text         TEXT,                                    -- Optional free text
    created_at          TIMESTAMPTZ     NOT NULL,

    -- CHECK constraints
    CONSTRAINT chk_reviews_rating         CHECK (rating BETWEEN 1 AND 5),
    CONSTRAINT chk_reviews_wait_bucket    CHECK (
        wait_time_bucket IS NULL OR wait_time_bucket IN ('<15 min', '15-30 min', '30-60 min', '>1 hr')
    )
);

-- =====================================================================
-- Summary of CHECK constraints (≥ 12 required):
--
--  1.  chk_doctors_gender           — gender IN ('M','F','X')
--  2.  chk_doctors_experience       — experience_years >= 0
--  3.  chk_doctors_consult_fee      — consultation_fee > 0
--  4.  chk_doctors_video_fee        — video_fee > 0 when present
--  5.  chk_doctors_reg_no_format    — registration_no matches pattern
--  6.  chk_clinics_latitude         — latitude [-90, 90]
--  7.  chk_clinics_longitude        — longitude [-180, 180]
--  8.  chk_schedules_weekday        — weekday 1–7
--  9.  chk_schedules_time_order     — end_time > start_time
-- 10.  chk_schedules_slot_minutes   — slot_minutes IN (10, 15, 20)
-- 11.  chk_patients_gender          — gender IN ('M','F','X')
-- 12.  chk_patients_blood_group     — valid blood group values
-- 13.  chk_appt_consult_type        — IN_CLINIC or VIDEO
-- 14.  chk_appt_status              — valid appointment statuses
-- 15.  chk_appt_payment_status      — PENDING, PAID, REFUNDED
-- 16.  chk_appt_slot_order          — slot_end > slot_start
-- 17.  chk_appt_fee_positive        — fee > 0
-- 18.  chk_appt_clinic_type         — clinic ↔ consult_type consistency
-- 19.  chk_appt_checkin_clinic      — only in-clinic appts checked in
-- 20.  chk_appt_refund_cancel       — refunds only for cancellations
-- 21.  chk_pi_line_no_positive      — line_no >= 1
-- 22.  chk_pi_duration_positive     — duration_days > 0
-- 23.  chk_pi_dosage_format         — dosage matches X-Y-Z pattern
-- 24.  chk_reviews_rating           — rating 1–5
-- 25.  chk_reviews_wait_bucket      — valid wait time buckets
-- =====================================================================
