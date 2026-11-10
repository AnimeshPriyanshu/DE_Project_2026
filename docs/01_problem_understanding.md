# Problem Understanding — Team T0095

## P1. Doctor Search and Slot Picker

Patients need to find doctors by specialization, city and language, view profiles and check available slots quickly.

**Stakeholders:** Patients, doctors.

**Classification:** Customer-facing / Real-time.

## P2. Patient Appointments and Booking

Patients need quick access to their appointments, sign-in and prescriptions. Booking should also be fast.

**Stakeholders:** Patients, support team.

**Classification:** Customer-facing / Real-time.

## P3. Clinic Queue and Check-in

Clinic staff need to view a doctor's daily queue and record patient check-ins quickly. Doctors also need access to their queues.

**Stakeholders:** Clinic reception, doctors.

**Classification:** Customer-facing / Real-time.

## P4. Patient Safety

Doctors and care teams need to find allergy conflicts, missed follow-ups and patients visiting multiple doctors for the same problem.

**Stakeholders:** Patients, doctors, care team, patient-safety team.

**Classification:** Customer-facing / Real-time.

## P5. Clinic Partnerships

The partnerships team needs to find clinics without doctor schedules to improve doctor availability.

**Stakeholders:** Clinic partnerships team.

**Classification:** Reporting / Analytics.

## P6. Quality Reports

The quality team needs reports on missed appointments, waiting times, doctor ratings and double bookings.

**Stakeholders:** Quality team, doctors, clinic reception, support team.

**Classification:** Reporting / Analytics.

## P7. Finance, Pharmacy and Population Health

The system should provide revenue, medicine and patient health reports. It must also handle a 20x increase in appointments.

**Stakeholders:** Finance team, pharmacy partners, care team.

**Classification:** Reporting / Analytics.

## Assumptions

1. Every doctor, patient, clinic and appointment has a unique ID.
2. Doctors can have multiple weekly schedules.
3. Appointments can be in-clinic or through video consultation.
4. A prescription can contain multiple medicines.
5. Patient allergies must be checked before prescribing medicines.
6. Appointment, check-in, prescription and review history must be stored.
7. The database must support future growth and maintain accurate data.
