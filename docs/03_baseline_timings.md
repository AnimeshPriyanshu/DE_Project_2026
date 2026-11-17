# Baseline Timings: Practo Doctor Appointments Database

**Team:** T0095 Dwelling · **Database:** PostgreSQL 18.6 · **Dataset:** 150,000 appointments (Seed Data)
**Benchmark Method:** 3 runs per query using `EXPLAIN (ANALYZE, BUFFERS)`, write queries wrapped in `BEGIN ... ROLLBACK`.

---

## 1. Timing Summary Table

| SQL Query | Type | Run 1 (ms) | Run 2 (ms) | Run 3 (ms) | Average (ms) |
|---|---|---:|---:|---:|---:|
| R01: Find a doctor: verified dermatologists practising in Bengaluru, most experienced first | READ | 2.685 | 1.906 | 2.012 | 2.201 |
| R02: Doctor profile: doctor 217's weekly timetable with clinic names | READ | 0.360 | 0.648 | 0.580 | 0.529 |
| R03: Slot picker: doctor 217's free in-clinic slots on Friday 3 July 2026 | READ | 15.754 | 10.614 | 9.460 | 11.943 |
| R04: "My appointments": patient 90's upcoming appointments | READ | 7.977 | 8.133 | 8.227 | 8.112 |
| R05: Doctor's queue: doctor 16's appointments on 30 June 2026 | READ | 7.740 | 7.461 | 6.693 | 7.298 |
| R06: Sign-in with mobile number | READ | 0.035 | 0.023 | 0.027 | 0.028 |
| R07: Prescription view: the prescription and medicines of appointment 18872 | READ | 0.222 | 0.048 | 0.119 | 0.130 |
| R08: Quality: no-show rate per specialization in 2026 | READ | 29.724 | 29.598 | 31.064 | 30.129 |
| R09: Clinic experience: average minutes patients waited after their slot time, per clinic (June 2026) | READ | 32.078 | 10.953 | 10.110 | 17.714 |
| R10: Patient safety: patients allergic to penicillin who were prescribed amoxicillin | READ | 25.018 | 21.086 | 20.863 | 22.322 |
| R11: Care team: follow-ups due in the first week of July 2026 that the patient has not booked yet | READ | 17.569 | 16.775 | 18.022 | 17.455 |
| R12: Product analytics: video vs in-clinic appointments per month in 2026 | READ | 24.142 | 24.551 | 24.670 | 24.454 |
| R13: Clinic partnerships: clinics where no doctor has any schedule | READ | 2.837 | 2.503 | 3.145 | 2.828 |
| R14: Doctor ranking: average rating and recommendation rate (at least 10 reviews) | READ | 27.087 | 21.902 | 23.616 | 24.202 |
| R15: Pharmacy partners: most prescribed medicines per primary specialization in June 2026 | READ | 25.692 | 25.221 | 24.563 | 25.159 |
| R16: Finance: fees collected per clinic in June 2026 | READ | 11.962 | 9.800 | 10.994 | 10.919 |
| R17: Population health: completed appointments by patient age group and blood group (2026) | READ | 49.517 | 49.584 | 49.029 | 49.377 |
| R18: Search filter: Tamil-speaking doctors with Chennai clinics | READ | 4.461 | 4.638 | 4.216 | 4.438 |
| R19: City report: June 2026 completed consultations and latest consultation of every doctor with a Bengaluru clinic | READ | 4789.756 | 5227.031 | 4769.460 | 4928.749 |
| R20: Platform analytics: completed appointments per day and running total, June 2026 | READ | 9.320 | 9.082 | 9.179 | 9.194 |
| R21: Finance: completed in-clinic consultations whose fee is still unpaid | READ | 24.588 | 10.982 | 10.494 | 15.355 |
| R22: Support console: all appointments, newest first, page 4,001 (25 per page) | READ | 36.733 | 36.833 | 36.054 | 36.540 |
| R23: Verification team: look up a doctor by medical council registration number | READ | 0.032 | 0.030 | 0.031 | 0.031 |
| R24: Data quality: two active appointments of the same doctor in the same slot (double bookings) | READ | 29.910 | 27.481 | 26.894 | 28.095 |
| R25: Care quality: patients who saw 3 or more different doctors of the same specialization in 2026 | READ | 21.173 | 20.468 | 19.735 | 20.459 |
| W01: Book: patient 90 books doctor 217's 10:30 slot on Friday 3 July 2026 | WRITE | 0.591 | 0.630 | 0.507 | 0.576 |
| W02: Reception: check in the earliest BOOKED in-clinic appointment of 1 July 2026 | WRITE | 8.603 | 7.734 | 8.066 | 8.134 |
| W03: Doctor: add notes and a follow-up date to the prescription of appointment 18872 | WRITE | 0.200 | 0.134 | 0.119 | 0.151 |
| W04: Nightly job (run at 00:00 on 2 July 2026): BOOKED appointments whose slot has ended become NO_SHOW | WRITE | 10.579 | 10.666 | 10.670 | 10.638 |
| W05: Doctor on leave: cancel and refund all of doctor 504's appointments on 3 July 2026 | WRITE | 7.463 | 8.057 | 7.514 | 7.678 |
| **Total (sum of all 30)** | | **5223.808** | **5604.572** | **5146.133** | **5324.838** |

---

## 2. Scan Type & Execution Analysis per Query

### R01: Find a doctor: verified dermatologists practising in Bengaluru, most experienced first
- **Query Type:** READ
- **Average Execution Time:** 2.201 ms
- **Scan Types in Execution Plan:** `Seq Scan on doctor_specializations/specializations/clinics; Index Scan on doctors/schedules`
- **Why it is fast/slow:** Performs multiple table scans and joins across 5 tables; limited by LIMIT 20 but incurs sorting overhead on experience_years.

### R02: Doctor profile: doctor 217's weekly timetable with clinic names
- **Query Type:** READ
- **Average Execution Time:** 0.529 ms
- **Scan Types in Execution Plan:** `Index Scan using doctor_schedules_pkey on doctor_schedules | Seq Scan on clinics`
- **Why it is fast/slow:** Fast due to primary key index lookup on doctor_id in doctor_schedules, with a lightweight hash join to clinics.

### R03: Slot picker: doctor 217's free in-clinic slots on Friday 3 July 2026
- **Query Type:** READ
- **Average Execution Time:** 11.943 ms
- **Scan Types in Execution Plan:** `Index Scan using doctor_schedules_pkey on doctor_schedules | Seq Scan on appointments`
- **Why it is fast/slow:** Slow because the NOT EXISTS subquery triggers a full sequential scan on 150,000 appointments to check slot collisions.

### R04: "My appointments": patient 90's upcoming appointments
- **Query Type:** READ
- **Average Execution Time:** 8.112 ms
- **Scan Types in Execution Plan:** `Seq Scan on appointments | Index Scan using doctors_pkey on doctors | Seq Scan on clinics`
- **Why it is fast/slow:** Slow because filtering patient_id = 90 requires scanning the entire 150,000-row appointments table without a foreign key index.

### R05: Doctor's queue: doctor 16's appointments on 30 June 2026
- **Query Type:** READ
- **Average Execution Time:** 7.298 ms
- **Scan Types in Execution Plan:** `Seq Scan on appointments | Index Scan using patients_pkey on patients`
- **Why it is fast/slow:** Slow due to full sequential scan on appointments evaluating DATE(slot_start) = 2026-06-30 across all 150,000 rows.

### R06: Sign-in with mobile number
- **Query Type:** READ
- **Average Execution Time:** 0.028 ms
- **Scan Types in Execution Plan:** `Index Scan using patients_phone_key on patients`
- **Why it is fast/slow:** Extremely fast (sub-millisecond) because phone has a UNIQUE constraint and automatic B-tree index.

### R07: Prescription view: the prescription and medicines of appointment 18872
- **Query Type:** READ
- **Average Execution Time:** 0.130 ms
- **Scan Types in Execution Plan:** `Index Scan using prescriptions_appointment_id_key on prescriptions | Index Scan using prescription_items_pkey on prescription_items`
- **Why it is fast/slow:** Very fast as both appointment_id (UNIQUE) and prescription_id (PK) utilize index lookups.

### R08: Quality: no-show rate per specialization in 2026
- **Query Type:** READ
- **Average Execution Time:** 30.129 ms
- **Scan Types in Execution Plan:** `Seq Scan on appointments | Seq Scan on doctor_specializations | Seq Scan on specializations`
- **Why it is fast/slow:** Slow because it scans all 150,000 appointments and calculates date extractions and conditional aggregations without an index on slot_start.

### R09: Clinic experience: average minutes patients waited after their slot time, per clinic (June 2026)
- **Query Type:** READ
- **Average Execution Time:** 17.714 ms
- **Scan Types in Execution Plan:** `Seq Scan on appointments`
- **Why it is fast/slow:** Scans the entire appointments table to filter June 2026 appointments and computes epoch differences.

### R10: Patient safety: patients allergic to penicillin who were prescribed amoxicillin
- **Query Type:** READ
- **Average Execution Time:** 22.322 ms
- **Scan Types in Execution Plan:** `Seq Scan on appointments | Seq Scan on patients | Index Scan on prescriptions | Index Scan on prescription_items`
- **Why it is fast/slow:** Scans patients for GIN array membership and appointments for joins without an index on allergies or appointment patient_id.

### R11: Care team: follow-ups due in the first week of July 2026 that the patient has not booked yet
- **Query Type:** READ
- **Average Execution Time:** 17.455 ms
- **Scan Types in Execution Plan:** `Seq Scan on appointments | Seq Scan on prescriptions | Index Scan on appointments`
- **Why it is fast/slow:** Subquery NOT EXISTS causes correlated index scans on appointments for each follow-up prescription in range.

### R12: Product analytics: video vs in-clinic appointments per month in 2026
- **Query Type:** READ
- **Average Execution Time:** 24.454 ms
- **Scan Types in Execution Plan:** `Seq Scan on appointments`
- **Why it is fast/slow:** Scans all 150,000 appointments to group by date_trunc and consult_type.

### R13: Clinic partnerships: clinics where no doctor has any schedule
- **Query Type:** READ
- **Average Execution Time:** 2.828 ms
- **Scan Types in Execution Plan:** `Seq Scan on clinics | Seq Scan on doctor_schedules`
- **Why it is fast/slow:** Performs NOT IN subquery against doctor_schedules; returns 0 rows (incorrectly) due to NULL clinic_id handling in SQL.

### R14: Doctor ranking: average rating and recommendation rate (at least 10 reviews)
- **Query Type:** READ
- **Average Execution Time:** 24.202 ms
- **Scan Types in Execution Plan:** `Seq Scan on appointments | Seq Scan on doctor_reviews`
- **Why it is fast/slow:** Full scan and hash join across 30,339 reviews and 150,000 appointments with group by doctor_id.

### R15: Pharmacy partners: most prescribed medicines per primary specialization in June 2026
- **Query Type:** READ
- **Average Execution Time:** 25.159 ms
- **Scan Types in Execution Plan:** `Seq Scan on prescription_items | Seq Scan on appointments | Seq Scan on prescriptions | Seq Scan on doctor_specializations | Seq Scan on specializations`
- **Why it is fast/slow:** Heavy 5-table join across 243,085 items, 97,234 prescriptions, and 150,000 appointments with multiple sequential scans.

### R16: Finance: fees collected per clinic in June 2026
- **Query Type:** READ
- **Average Execution Time:** 10.919 ms
- **Scan Types in Execution Plan:** `Seq Scan on appointments | Seq Scan on clinics`
- **Why it is fast/slow:** Scans appointments for payment_status = PAID and date range, then aggregates by clinic.

### R17: Population health: completed appointments by patient age group and blood group (2026)
- **Query Type:** READ
- **Average Execution Time:** 49.377 ms
- **Scan Types in Execution Plan:** `Seq Scan on appointments | Seq Scan on patients`
- **Why it is fast/slow:** Hash join on 150k appointments and 40k patients followed by age function calculation and aggregation.

### R18: Search filter: Tamil-speaking doctors with Chennai clinics
- **Query Type:** READ
- **Average Execution Time:** 4.438 ms
- **Scan Types in Execution Plan:** `Seq Scan on doctor_schedules | Seq Scan on doctors | Seq Scan on clinics`
- **Why it is fast/slow:** Requires unindexed array scan (Tamil = ANY(languages)) and multi-table join across schedules and clinics.

### R19: City report: June 2026 completed consultations and latest consultation of every doctor with a Bengaluru clinic
- **Query Type:** READ
- **Average Execution Time:** 4928.749 ms
- **Scan Types in Execution Plan:** `Seq Scan on doctor_schedules | Seq Scan on clinics | Seq Scan on doctors | Seq Scan on appointments`
- **Why it is fast/slow:** Extremely slow (~4.9 seconds); correlated scalar subqueries execute full sequential scans on 150,000 appointments for each Bengaluru doctor.

### R20: Platform analytics: completed appointments per day and running total, June 2026
- **Query Type:** READ
- **Average Execution Time:** 9.194 ms
- **Scan Types in Execution Plan:** `Seq Scan on appointments`
- **Why it is fast/slow:** Sequential scan on appointments to filter June completed records, then sorts and executes window function.

### R21: Finance: completed in-clinic consultations whose fee is still unpaid
- **Query Type:** READ
- **Average Execution Time:** 15.355 ms
- **Scan Types in Execution Plan:** `Seq Scan on appointments`
- **Why it is fast/slow:** Full sequential scan across 150,000 rows filtering status = COMPLETED and payment_status = PENDING with ORDER BY.

### R22: Support console: all appointments, newest first, page 4,001 (25 per page)
- **Query Type:** READ
- **Average Execution Time:** 36.540 ms
- **Scan Types in Execution Plan:** `Seq Scan on appointments`
- **Why it is fast/slow:** Slow due to high OFFSET (100,000) requiring PostgreSQL to scan and discard 100,000 rows after sorting.

### R23: Verification team: look up a doctor by medical council registration number
- **Query Type:** READ
- **Average Execution Time:** 0.031 ms
- **Scan Types in Execution Plan:** `Index Scan using doctors_registration_no_key on doctors`
- **Why it is fast/slow:** Instantaneous (<0.05 ms) due to B-tree index on registration_no (UNIQUE constraint).

### R24: Data quality: two active appointments of the same doctor in the same slot (double bookings)
- **Query Type:** READ
- **Average Execution Time:** 28.095 ms
- **Scan Types in Execution Plan:** `Seq Scan on appointments`
- **Why it is fast/slow:** Self-join on 150,000 appointments requires scanning the appointments table without an index on (doctor_id, slot_start).

### R25: Care quality: patients who saw 3 or more different doctors of the same specialization in 2026
- **Query Type:** READ
- **Average Execution Time:** 20.459 ms
- **Scan Types in Execution Plan:** `Seq Scan on appointments | Seq Scan on doctor_specializations`
- **Why it is fast/slow:** Large hash aggregate over 150,000 appointments joined to doctor_specializations.

### W01: Book: patient 90 books doctor 217's 10:30 slot on Friday 3 July 2026
- **Query Type:** WRITE
- **Average Execution Time:** 0.576 ms
- **Scan Types in Execution Plan:** `Index Scan using doctor_schedules_pkey on doctor_schedules | Index Scan using doctors_pkey on doctors`
- **Why it is fast/slow:** Fast single-row INSERT selecting doctor fee and clinic via primary key lookups.

### W02: Reception: check in the earliest BOOKED in-clinic appointment of 1 July 2026
- **Query Type:** WRITE
- **Average Execution Time:** 8.134 ms
- **Scan Types in Execution Plan:** `Seq Scan on appointments | Index Scan using appointments_pkey on appointments`
- **Why it is fast/slow:** Subquery scans appointments sequentially to find the minimum slot_start before updating via PK.

### W03: Doctor: add notes and a follow-up date to the prescription of appointment 18872
- **Query Type:** WRITE
- **Average Execution Time:** 0.151 ms
- **Scan Types in Execution Plan:** `Index Scan using prescriptions_appointment_id_key on prescriptions`
- **Why it is fast/slow:** Extremely fast single-row update using the unique index on appointment_id in prescriptions.

### W04: Nightly job (run at 00:00 on 2 July 2026): BOOKED appointments whose slot has ended become NO_SHOW
- **Query Type:** WRITE
- **Average Execution Time:** 10.638 ms
- **Scan Types in Execution Plan:** `Seq Scan on appointments`
- **Why it is fast/slow:** Scans the full appointments table to locate 329 expired bookings and update their status.

### W05: Doctor on leave: cancel and refund all of doctor 504's appointments on 3 July 2026
- **Query Type:** WRITE
- **Average Execution Time:** 7.678 ms
- **Scan Types in Execution Plan:** `Seq Scan on appointments`
- **Why it is fast/slow:** Scans appointments sequentially for doctor_id = 504 and date range to update cancelled status.

