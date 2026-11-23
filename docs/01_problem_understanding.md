# Problem Understanding — Practo Doctor Appointments Database

**Team:** T0095 Dwelling · **Section:** C · **Mentor:** Satyaki · **Course:** DBMS CP1
**Members:** Animesh Priyanshu, Atul Panda, Ishan Chetwani, Rishabh Singh

---

## 1. Project Context & Objectives

Practo is a healthcare platform that links patients with doctors for in-clinic and video consultations. The database supports searching for doctors, managing schedules, booking appointments, clinical prescriptions and reviews. Because it was assembled without a formal schema, the current system experiences operational latency and reporting timeouts. This project turns an unconstrained PostgreSQL database into a normalized, well-constrained relational schema that serves present operations over 150,000 appointments (the baseline) and scales to the 20× target (~3,000,000 appointments).

---

## 2. Problem Statements (P1–P7)

| # | Business Need | Key Stakeholders | Classification | Workload Queries |
| **P1** | Quick doctor search by specialization, city and language; viewing the timetable and computing free slots dynamically. | Patients, Doctors | Customer-facing / Real-time | R01, R02, R03, R18 |
| **P2** | Prompt patient sign-in, a "My appointments" dashboard, prescription viewing and slot booking. | Patients, Support Team | Customer-facing / Real-time | R04, R06, R07, W01 |
| **P3** | A live clinic reception queue and quick recording of patient check-ins. | Clinic Reception, Doctors | Customer-facing / Real-time | R05, W02 |
| **P4** | Safety checks: spotting allergy conflicts (e.g., penicillin vs. amoxicillin), follow-ups that were never booked, and doctor shopping. | Care Team, Patient Safety | Real-time & Analytics | R10, R11, R25, W03 |
| **P5** | Partnership auditing: finding clinics in which no doctor holds an active schedule. | Clinic Partnerships | Reporting / Analytics | R13 |
| **P6** | Operational quality reports: no-show rates per specialization, clinic wait times, doctor ratings and double bookings. | Quality Team, Management | Reporting / Analytics | R08, R09, R14, R24, W04 |
| **P7** | Platform analytics: clinic revenue, the most prescribed medicines, population health demographics and 20× scalability. | Finance, Pharmacy, Insights | Reporting / Analytics | R12, R15, R16, R17, R19, R20, R21, R22, R23, W05 |

---

## 3. Core Business Rules & Assumptions

1. **Identifiers & Integrity:** Every master entity (`doctors`, `patients`, `clinics`, `appointments`) is identified by a unique integer primary key.
2. **Specializations:** A doctor may hold several specializations, and exactly one of them is expected to be the primary; the database permits at most one through a partial unique index (`WHERE is_primary`).
3. **Consultation Channels:** An `IN_CLINIC` visit needs a valid `clinic_id` and allows reception check-in; a `VIDEO` visit must have `clinic_id IS NULL` and admits no check-in.
4. **Clinical Safety:** Prescriptions stand 1:1 with appointments and link to 1:N medicine items; a patient's allergies (`TEXT[]`) have to be cross-checked while prescribing.
5. **Patient Identity:** Sign-in relies on the phone number as the required UNIQUE candidate key; email is nullable (~35% missing); gender may be `'M'`, `'F'` or `'X'`.
6. **Appointments & Financials:** Booking fees are kept historically; cancelled visits are refunded according to the cancellation policy that applies; the system scales from the 150k baseline up to 3 million appointments.
