# Problem Understanding — Practo Doctor Appointments Database

**Team:** T0095 Dwelling · **Section:** C · **Mentor:** Satyaki · **Course:** DBMS CP1
**Members:** Animesh Priyanshu, Atul Panda, Ishan Chetwani, Rishabh Singh

---

## 1. Project Context & Objectives

Practo is a healthcare platform connecting patients with doctors for in-clinic and video consultations. The database powers doctor search, schedule management, appointment booking, clinical prescriptions, and reviews. Assembled without a formal schema, the current system suffers from operational latency and reporting timeouts. This project rebuilds an unconstrained PostgreSQL database into a normalized, well-constrained relational schema supporting current operations on 150,000 appointments (baseline) and scaling to the 20× target (~3,000,000 appointments).

---

## 2. Problem Statements (P1–P7)

| # | Business Need | Key Stakeholders | Classification | Workload Queries |
|---|---|---|---|---|
| **P1** | Fast doctor search by specialization, city, language; timetable viewing and dynamic free slot calculation. | Patients, Doctors | Customer-facing / Real-time | R01, R02, R03, R18 |
| **P2** | Responsive patient sign-in, "My appointments" dashboard, prescription viewing, and slot booking. | Patients, Support Team | Customer-facing / Real-time | R04, R06, R07, W01 |
| **P3** | Real-time clinic reception queue and rapid patient check-in recording. | Clinic Reception, Doctors | Customer-facing / Real-time | R05, W02 |
| **P4** | Safety checks: detecting allergy conflicts (e.g., penicillin vs. amoxicillin), unbooked follow-ups, and doctor shopping. | Care Team, Patient Safety | Real-time & Analytics | R10, R11, R25, W03 |
| **P5** | Partnership auditing: identifying clinics where no doctor has an active schedule. | Clinic Partnerships | Reporting / Analytics | R13 |
| **P6** | Operational quality reports: specialization no-show rates, clinic wait times, doctor ratings, and double bookings. | Quality Team, Management | Reporting / Analytics | R08, R09, R14, R24, W04 |
| **P7** | Platform analytics: clinic revenue, most prescribed medicines, population health demographics, and 20× scalability. | Finance, Pharmacy, Insights | Reporting / Analytics | R12, R15, R16, R17, R19, R20, R21, R22, R23, W05 |

---

## 3. Core Business Rules & Assumptions

1. **Identifiers & Integrity:** Master entities (`doctors`, `patients`, `clinics`, `appointments`) have unique integer primary keys.
2. **Specializations:** Doctors can hold multiple specializations, with exactly one expected to be primary; the database enforces at most one via a partial unique index (`WHERE is_primary`).
3. **Consultation Channels:** `IN_CLINIC` visits require a valid `clinic_id` and allow reception check-in; `VIDEO` visits must have `clinic_id IS NULL` and no check-in.
4. **Clinical Safety:** Prescriptions are 1:1 with appointments and link to 1:N medicine items; patient allergies (`TEXT[]`) must be cross-checked during prescribing.
5. **Patient Identity:** Phone number is the required UNIQUE candidate key for sign-in; email is nullable (~35% missing); gender allows `'M'`, `'F'`, and `'X'`.
6. **Appointments & Financials:** Booking fees are preserved historically; refunds for cancelled visits follow the applicable cancellation policy; system scales from the 150k baseline to 3 million appointments.
