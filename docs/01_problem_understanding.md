# Problem Understanding — Team T0095

## P1. Doctor Search and Slot Picker

Patients face delays when searching for doctors, viewing their profiles and checking available appointment slots. The system should help patients find verified doctors based on city, specialization and language, and show their available slots quickly.

**Stakeholders:** Patients, Patient App team.

**Classification:** Customer-facing / Real-time.

## P2. Patient Appointments and Booking

Patients face delays when checking their appointments, signing in using their mobile numbers and viewing their prescriptions. The system should make it easy to access appointment details and book new appointments.

**Stakeholders:** Patients, Patient App team.

**Classification:** Customer-facing / Real-time.

## P3. Doctor Queue and Check-in

Clinic receptionists need to see all appointments for a doctor on a particular day. They should also be able to check patients in and record their check-in time without delays.

**Stakeholders:** Clinic receptionists, doctors, Clinics team.

**Classification:** Operational / Real-time.

## P4. Patient Safety

The system should help doctors identify patients who are given medicines they are allergic to, patients who have missed their follow-up appointments and patients who are visiting multiple doctors for the same health problem.

**Stakeholders:** Patients, doctors, patient-safety team, care team.

**Classification:** Operational / Real-time.

## P5. Clinic Partnerships

The clinic partnerships team needs to find clinics that do not have any doctor schedules. This will help them identify clinics where doctor availability needs to be improved.

**Stakeholders:** Clinic partnerships team.

**Classification:** Reporting / Analytics.

## P6. Quality Reports

The management team needs reports about missed appointments, patient waiting times, doctor ratings and double bookings. These reports will help them understand and improve the quality of services.

**Stakeholders:** Quality team, clinic management, doctors.

**Classification:** Reporting / Analytics.

## P7. Finance, Pharmacy and Population Health

The system needs to generate reports about revenue, commonly prescribed medicines and patient health trends. It should also handle a large increase in appointment data, with an expected growth of 20 times.

**Stakeholders:** Finance team, pharmacy partners, analytics/insights team.

**Classification:** Reporting / Analytics.

## Assumptions

1. Every doctor and patient has a unique ID.
2. A doctor can have multiple specializations and weekly schedules.
3. Video consultations may not be linked to a physical clinic.
4. Check-in and consultation times depend on the appointment status.
5. A prescription can contain multiple medicines.
6. Past appointment and prescription records should be maintained.
7. The database should be able to handle future data growth while keeping information accurate and consistent.
