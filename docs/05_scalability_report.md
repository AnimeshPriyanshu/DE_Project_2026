# Scalability Report (CP4) — Practo Doctor Appointments Database

**Team:** T0095 Dwelling · **Section:** C
**Project tree:** `DE_Project_2026/`
**Database:** `practo_t0095_large` (PostgreSQL 18.6)
**Date:** 2026-11-22
**Status:** Measured on the official large dataset; partitioning, sharding, and
replicas evaluated as designs, not implemented.

This is the official CP4 scalability report. The detailed R19/R17/R13
investigation and raw evidence are in `docs/06_cp4_large_scale_report.md` and
`benchmarks/results/large/`.

---

## 1. Executive summary

- The official large dataset is loaded: **3,000,000 appointments**, 800,000
  patients, 60,000 doctors, 609,747 schedules, 1,473 MB.
- The large database has **only `appointments_pkey`** on `appointments`; these
  results are **baseline-schema** measurements, not CP3 optimized-schema
  measurements.
- **28 of 30 workload statements measured 3/3 runs; 2 timed out (R13, R19);
  0 errored; 0 not executed.** Timeouts are never reported as execution times.
- The dominant scale problem is **R19**: no `doctor_id` index plus two
  correlated subqueries, producing ~57.6 billion row visits; it timed out at
  60 s. A set-based rewrite finishes in **349.5 ms cold / 248.2 ms warm
  median**; its full-result equivalence is established at seed scale only,
  with a 40-doctor large-scale sample (see §4.1).
- **R13** is a second scale-triggered failure caused by `NOT IN` with 117,747
  NULL `clinic_id` values. The original returns 0 rows by NULL semantics; the
  corrected business query returns **292 rows on seed** and **10,668 rows on
  large** in 40.7–58.5 ms. These are **not equivalent results**.
- Decision: **retain the heap schema for now**, add targeted indexes/query
  rewrites first, and defer partitioning, sharding, and replicas until measured
  prototypes justify them.

---

## 2. Dataset and measurement method

| Item | Value |
|---|---:|
| Database size | 1,473 MB |
| `appointments` | **3,000,000 rows** (exact count) |
| `patients` | 800,000 |
| `doctors` | 60,000 |
| `doctor_schedules` | 609,747 |
| `prescriptions` | 1,944,432 |
| `prescription_items` | 4,860,623 |
| `shared_buffers` | 128 MB |
| `work_mem` | 4 MB |
| `effective_cache_size` | 4 GB |
| `random_page_cost` | 4 |
| `max_parallel_workers_per_gather` | 2 |
| Indexes on `appointments` | only `appointments_pkey (appointment_id)` |

Method: each statement was run **three times** with
`EXPLAIN (ANALYZE, BUFFERS, VERBOSE, COSTS)` and
`statement_timeout = 60000 ms`. `summary.csv` reports
avg/median/min/max over the completed runs. A query that timed out stopped
after that attempt; R13 and R19 have `runs_completed = 0` and no execution
time. Writes (`W01`–`W05`) ran inside `BEGIN … ROLLBACK` every time.
Full environment capture: `benchmarks/results/large/environment.txt`.

The seed-scale comparison uses the existing CP3 baseline medians
(`benchmarks/results/baseline/summary.csv`), which were measured on 150,000
appointments.

---

## 3. Growth analysis: seed 150K → large 3M

The dataset grows by **20×** in appointments, patients, doctors, clinics, and
schedules. Latency growth is not uniform:

| Query | Seed baseline median (ms) | Large 3M average (ms) | Growth | Interpretation |
|---|---:|---:|---:|---|
| R10 | 22.322 | 279.876 | ~12.5× | roughly linear scan/join growth; cold/warm spread |
| R11 | 17.455 | 128.874 | ~7.4× | anti-join grows sublinearly |
| R12 | 24.454 | 275.599 | ~11.3× | month aggregation over 3M rows |
| R17 | 49.377 | 464.826 | ~9.4× | parallel hash join; no failure |
| R20 | 9.194 | 92.314 | ~10.0× | daily aggregation over larger range |
| R24 | 28.095 | 1507.107 | ~53.6× | self-join with no supporting index |
| R19 | 4,928.749 | **timeout >60,000** | not computable | superlinear correlated work |
| R13 | 2.828 | **timeout >240,000** | not computable | NULL `NOT IN` trap |

R19 is the clearest **superlinear** case: seed had 480 qualifying doctors ×
150,000 appointments (144M row visits); large has 9,600 qualifying doctors ×
3,000,000 appointments (57.6B row visits). That is about **400×** the
correlated work for a 20× data increase, because both the outer row count and
the inner table grew by 20×.

R13 is a **scale-triggered semantic trap**, not ordinary growth: at seed scale
it took 2.8 ms with **1,500 clinics and 30,499 schedules**; at large scale it
performs roughly 30,000 × 609,747 ≈ 18 billion membership comparisons because
`NOT IN` contains NULLs.
It timed out at 60 s and again at 240 s.

R24 grows faster than linear because the self-join on
`(doctor_id, slot_start)` has no matching index at 3M rows; it still completed
in 1.51 s on average.

---

## 4. Scale-only problems and fixes

### 4.1 R19 — missing `doctor_id` index and correlated subqueries

**Original plan (non-executing `EXPLAIN`):** estimated cost
**11,432,399,591.16**; `Hash Right Semi Join` for the Bengaluru `EXISTS`, plus
two `SubPlan` aggregates that each sequentially scan all 3M appointment rows.
The plan uses no index for `appointments.doctor_id`.

**Why scale hurts:** 9,600 outer doctors × 2 subplans × 3,000,000 rows ≈ 57.6B
row visits. A 40-doctor diagnostic sample took **9,630 ms** (40 loops;
133.067 ms + 107.674 ms per loop), indicating **~38.5 minutes** for the full
query by extrapolation. This is an extrapolation, not an observed execution:
the full original timed out at 60 s.

**Fix:** set-based rewrite (`sql/07_r19_rewrite.sql`) aggregates
`appointments` once by `doctor_id`, then left-joins to the qualifying doctors.
Measured full rewrite: **349.5 ms first run**, warm runs **262.2 / 248.2 /
242.3 ms** (median 248.2 ms), returning all 9,600 doctors.

**Equivalence scope:** full-result equality is established only at seed scale
(480/480 rows, 0 differences). Large-scale comparison covers **40 of 9,600
doctors**, not the full result. Full large-dataset equivalence is therefore
**not established**; see `docs/06` §2.6.

**Proposed index:** `appointments (doctor_id, slot_start) INCLUDE (status,
consult_ended_at)`. The CP3 seed result reduced R19 from 4,317 ms to 14.0 ms
with the `idx_appt_doctor_slot` family. It was **not** created or measured on
the 3M-row database here, so no large-scale index speedup is claimed.

### 4.2 R13 — `NOT IN` with NULLs

The original query is **defined to return 0 rows** because schedule rows have
NULL `clinic_id` (**117,747 on large; 5,899 on seed**); `NOT IN` yields UNKNOWN
for non-matching clinics (seed measured 0). It still performs the repeated
membership test and timed out at 60 s and 240 s at large scale.

The corrected business question is implemented with `NOT EXISTS`, which
ignores NULLs and returns clinics with no doctor schedule referencing them:
**292 rows on seed `Practo`** (1,500 clinics, 30,499 schedules, 5,899 NULL
schedules) and **10,668 rows on large** (30,000 clinics, 609,747 schedules,
117,747 NULL schedules), measured in **40.7–58.5 ms** on large across three
runs. The 292 → 10,668 difference is the correct business count on two
datasets with different clinic counts and NULL-schedule distributions; it is
not a measurement inconsistency. This is **not result-equivalent to the
original** (0 vs 292 seed / 10,668 large); it is the intended business
behavior. A NULL-guarded diagnostic variant returns 0 rows and is
result-equivalent to the original on current data (0.033–0.064 ms), but
preserves the data-quality bug and is not the business fix.

The underlying data issue should be fixed at the source (forbid NULL
`clinic_id` for clinic schedules, or document NULL as video/no-clinic and
rewrite the report).

### 4.3 Remaining high-latency measured queries

| Query | 3-run average (ms) | Observation | Candidate fix |
|---|---:|---|---|
| R24 | 1507.107 | self-join without `(doctor_id, slot_start)` index | add index, then re-measure |
| R17 | 464.826 | parallel hash join; not a failure | retain; investigate unresolved 40 s claim |
| R14 | 323.844 | 608K reviews joined to 3M appointments | consider covering/index strategy |
| R08 | 298.415 | 3M-row scan + specialization join | `slot_start`/status index candidate |
| R12 | 275.599 | month aggregation over 3M rows | `slot_start` covering index candidate |
| R10 | 279.876 | 3M appointments × prescriptions/items | index/join-order work |
| W04 | 251.803 (median 187.511; max 381.055) | status update scan | partial status index candidate |

These are baseline-schema numbers. The CP3 seed indexes were not applied to
`practo_t0095_large`; their large-scale effect remains unmeasured.

---

## 5. Partitioning design with evidence

The design record is `sql/08_partitioning.sql`; it is **not executed**.

### 5.1 PostgreSQL constraints

A RANGE-partitioned `appointments` table requires the primary key to include
the partition key. Partitioning by `slot_start` forces
`PRIMARY KEY (appointment_id, slot_start)`, which removes global uniqueness on
`appointment_id` alone. `prescriptions` and `doctor_reviews` foreign keys must
be recreated as composite keys; application writes must supply `slot_start`.
This is a schema-breaking migration, not an index change.

### 5.2 What the measured plans imply

- **R19 is not fixed by partitioning.** Its cost is the missing `doctor_id`
  index and 9,600 correlated subplan executions. Monthly pruning could reduce
  the June subplan's scan for some doctors, but `max(consult_ended_at)` spans
  all time and cannot be pruned by a June partition. The correlated loop count
  remains.
- **R17 and R25** have direct `slot_start` range predicates and are plausible
  pruning candidates. **R05, R08, R12, R20** use `DATE()`, `::date`, or
  `EXTRACT(YEAR ...)` and may not derive partition bounds directly; this must
  be tested, not assumed.
- **R13** concerns `clinics`/`doctor_schedules`, not the appointment partition
  key; partitioning `appointments` cannot fix it.
- **No partitioned prototype, pruning measurement, or per-partition ANALYZE
  was run.** No pruning speedup is claimed.

### 5.3 Options

| Option | Migration cost | Evidence status | Decision |
|---|---|---|---|
| Heap + indexes/rewrites | Low to medium | R19 rewrite measured; index not measured at 3M | **Preferred next step** |
| Monthly RANGE on `slot_start` | High: composite PK/FKs, app changes, registry for global uniqueness | No prototype; pruning unverified | Defer |
| Quarterly/yearly RANGE | High; same key issues | No prototype | Defer |
| Hash partition on `doctor_id` | High; no pruning benefit for date reports | No prototype | Reject for now |

---

## 6. Sharding and replica design

These are design analyses, not measured deployments.

### 6.1 Sharding

The workload is read-heavy (25 reads / 5 writes). Sharding by city or doctor
would distribute bookings, but the analytical queries cross those boundaries:
R19 spans cities/doctors, R24 self-joins appointments, R17/R25 aggregate
patients and doctors, and R12/R20 aggregate all appointments. Cross-shard
joins or scatter-gather would add network cost and consistency complexity. At
3M rows and 1.5 GB, no measured evidence shows a single-node limit; sharding is
**not justified** now.

### 6.2 Read replicas

A physical streaming replica could route read-only analytics (R08, R12, R14,
R17, R19, R20, R24, R25) while the primary handles writes. The application must
use a read-only connection/transaction, and dashboards must tolerate
replication lag. The R19 rewrite already makes the city report sub-second, and
the largest measured 3-run average is R24 at 1.51 s, so the current evidence
does not demonstrate a replica requirement. No replica was built or measured; no
failover or lag numbers are claimed.

### 6.3 Decision

Keep the single heap primary for CP4. First measure targeted indexes and the
R19/R13 fixes. Revisit partitioning only with a partitioned prototype and
pruning/buffer evidence; revisit sharding/replicas only with measured
read-concurrency or availability requirements.

### 6.4 Implementation and evidence classification

| Area | Implemented? | Measured / experimentally validated? | Classification |
|---|---|---|---|
| Heap schema + R19 query rewrite | Heap is live; rewrite is a query-level change, not a schema change | R19 rewrite measured (349.5 ms cold / 248.2 ms warm median); equivalence only seed-full + 40-doctor large sample | **Implemented and measured**, with equivalence limitation |
| New indexes for large DB | No index was created; `appointments` still has only its PK | No; CP3 index gains are seed-scale only | **Designed/proposed, not implemented, not measured at 3M** |
| RANGE partitioning | No; `sql/08_partitioning.sql` is a commented design record | No partitioned table, no pruning test, no per-partition ANALYZE | **Designed, not implemented, not experimentally validated** |
| Sharding | No | No; based on workload and size analysis | **Design analysis only, not measured** |
| Read replica | No | No; no replica, lag, or failover test | **Design analysis only, not measured** |
| R13 corrected business query | Yes, as a query | Yes: 292 seed rows / 10,668 large rows; large timing 40.7–58.5 ms | **Implemented and measured**; not equivalent to original |

---

## 7. Required CP4 deliverables

| Deliverable | Path | Status |
|---|---|---|
| Scalability report | `docs/05_scalability_report.md` | This file |
| Detailed large-scale investigation | `docs/06_cp4_large_scale_report.md` | Complete |
| Partitioning design (not executed) | `sql/08_partitioning.sql` | Design record updated to current dataset |
| Large-scale workload results | `benchmarks/results/large/summary.csv` | 30 rows; 28 measured 3/3; 2 timeouts |
| R19 rewrite | `sql/07_r19_rewrite.sql` | Equivalence scope documented |
| Reproducible runner | `benchmarks/run_large_benchmark.sh` | 3-run, timeout-aware |

---

## 8. Limitations

1. Three runs per measured query; R13/R19 timed out on the first attempt and
   were not repeated (0/3 completed). Timeout classifications are retained.
2. Cache state is uncontrolled; R10/W04 show cold/warm spread.
3. No optimized index was created on the large database. CP3 index effects are
   seed-scale and are not extrapolated.
4. R19's ~38.5-minute full-query estimate is an extrapolation from a 40-doctor
   sample, not an observed execution.
5. R19 full large-scale equivalence is not established; only 40 of 9,600
   doctors were compared at large scale.
6. R13 original (0 rows by NULL semantics) and corrected business query
   (292 seed / 10,668 large) are not equivalent; the 292 → 10,668 difference is
   the corrected business count on two different dataset sizes.
7. The 40 s R17 claim is unresolved; no artifact exists and it is not
   reproducible.
8. No partitioned prototype, sharded deployment, replica, or concurrent
   workload test was run.
9. `n_live_tup` for `appointments` is a stale estimate (3,000,410); the exact
   count is 3,000,000.
