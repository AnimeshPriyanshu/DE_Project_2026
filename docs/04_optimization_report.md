# CP3 — Query Optimization and Indexing Report

**Project:** Practo Doctor Appointments Database
**Team:** T0095 Dwelling
**Phase:** CP3 (Query Optimization and Indexing)
**Deliverables:** `sql/05_indexes.sql`, `sql/06_optimized_queries.sql`, `benchmarks/results/optimized/summary.csv`, this report

All timings quoted in this report are measured values taken from
`benchmarks/results/baseline/summary.csv` (CP2) and
`benchmarks/results/optimized/summary.csv` (CP3), measured on the same database
with the same harness. Where a number is an estimate or comes from a different
source, the text says so explicitly.

---

## 1. Introduction and objectives

CP2 established the schema, loaded the seed data and measured the untuned
workload: **4,636.9 ms** in total, of which a single query (R19) accounted for
**4,317.3 ms (93.1%)**. The schema carried only the 19 implicit primary-key and
unique indexes created by CP1's constraints.

The objectives of CP3 were:

1. Identify the real bottlenecks in the 30-query workload with
   `EXPLAIN (ANALYZE, BUFFERS)`, rather than guessing.
2. Design a small set of indexes that are each traceable to specific workload
   queries, without duplicating existing constraint indexes.
3. Rewrite only the queries whose SQL actively prevents index use, preserving
   result sets and result columns.
4. Re-measure all 30 queries under identical conditions, three runs each, and
   report before/after figures with the formula
   `improvement = ((baseline − optimized) / baseline) × 100`.
5. Explain the trade-offs: write amplification on the hottest table, storage
   cost, rejected index candidates and rejected rewrites.

---

## 2. Measurement environment and protocol

| Item | Value |
|---|---|
| Operating system | macOS (darwin), local development machine |
| PostgreSQL | 18.6 (Postgres.app), port 5432 |
| Database / schema | `Practo` / `practo` |
| Session time zone | `Asia/Kolkata` (unchanged from CP2) |
| `work_mem` | 4 MB (server default, unchanged) |
| Harness | `benchmarks/run_benchmark.sh` (unmodified since CP2) |
| Statement | `EXPLAIN (ANALYZE, BUFFERS)` per run |
| Repetitions | 3 per query; average, median, minimum, maximum recorded |
| Cache state | warm (the workload had been executed repeatedly before recording) |
| Writes | executed inside `BEGIN … ROLLBACK`; no data was persisted |
| CSV columns | `query_id,type,avg_ms,median_ms,min_ms,max_ms,scan_nodes` |

Before the recorded pass the touched tables were put into a defined steady
state:

```sql
VACUUM (ANALYZE) practo.appointments;      -- and 4 other hot tables
CHECKPOINT;
```

This is standard maintenance after bulk index creation: it refreshes planner
statistics, sets the visibility map (which is what makes the new index-only
scans actually avoid heap fetches) and removes the risk of a checkpoint firing
in the middle of a timing run.

### 2.1 The machine is not quiet, and the report says so

The working machine was shared with a desktop browser and other tooling, so
the load average during CP3 recording was roughly 2.3–3.0, against a much
quieter machine during CP2. This matters because several queries are CPU-bound,
and it produces two effects that are visible in the results:

* **Every query that was not changed by CP3 also appears slower.** For example
  R01 moved from a CP2 median of 1.551 ms to 4.156 ms with byte-identical SQL
  and an identical plan.
* **The first run of a session can absorb a one-off first-run cost.** W04's
  three runs were 3.947 / 4.006 / 53.137 ms; the 53 ms run is the first run of
  the pass and pays to dirty the 329 affected heap pages (1,071 buffers) that
  the later runs find already dirty. Ten isolated executions reproduced the
  same shape — 29.764 ms first, then 2.2–6.0 ms — so it is a real first-run
  effect rather than a random stall, and the median is the fair statistic
  (section 8).

To keep the comparison honest, a **same-session control** was run: the
*original* CP2 workload against the *CP2 schema* (all CP3 indexes dropped),
immediately around the recorded optimized pass, on the same machine and
database. Its results are included as a separate column in section 7. Where a
query's SQL and plan are unchanged, the control is the fair reference; where
CP3 genuinely changed the plan, both columns point the same way.

The control run is diagnostic evidence and deliberately lives outside the
repository (`/tmp/cp3_control/`), so that no file outside the four CP3
deliverables is added to the project.

---

## 3. Baseline analysis (CP2)

| Metric | CP2 baseline |
|---|---|
| Total workload time | 4,636.887 ms |
| Read total (25 queries) | 4,612.851 ms |
| Write total (5 queries) | 24.036 ms |
| Largest single query | R19 — 4,317.298 ms (93.1%) |
| Indexes present | 19 (constraint-driven only) |
| Table size | 83 MB |

The baseline was not uniformly slow. Eleven queries were already at or below
1 ms (R02, R06, R07, R23 and the write statements among them), because
constraint indexes already answered them exactly. The interesting work was in
three groups:

1. **One catastrophic query (R19).** Two correlated subqueries executed 480
   times each, every execution a sequential scan of `appointments`:
   **1,305,600 buffer hits per subquery**, about 2.6 million in total.
2. **Queries that could not use an index at all.** `DATE(slot_start) = …`,
   `EXTRACT(YEAR FROM slot_start) = …`, `slot_start::date BETWEEN …` and
   `NOT IN (SELECT nullable_column)`.
3. **Range reports over `appointments`** that scanned all 2,720 heap pages and
   then sorted or aggregated: R08, R09, R12, R16, R17, R20, R22, R25.

---

## 4. Identified bottlenecks

| # | Symptom in the baseline plan | Queries affected | Root cause |
|---|---|---|---|
| B1 | Correlated subquery × 480 full scans, ~2.6 M buffer hits | R19 | No index on `appointments(doctor_id, …)` |
| B2 | Function applied to the indexed column (`DATE()`, `EXTRACT()`, `::date`) | R05, R08, R12, R20 | Non-sargable predicate; B-tree cannot be used |
| B3 | `NOT IN` over a nullable column, always empty | R13 | NULL semantics, not performance only |
| B4 | Seq scan of all 150,000 rows + sort/aggregate for a date range | R08, R09, R12, R16, R17, R20, R25 | No index on `slot_start`; no covering columns |
| B5 | Seq scan + external merge sort (6,176 kB on disk) for one page | R22 | `ORDER BY slot_start DESC OFFSET 100000` needs ordered access |
| B6 | Full scan of the pending subset, then sort, for `LIMIT 100` | R21 | No partial index matching the filter and the order |
| B7 | Anti-join re-checks appointments per row | R03, R11 | No equality+range index for the anti-join |
| B8 | Batch job scans all appointments to find unclosed slots | W02, W04, W05 | No partial index for the open/pending subsets |
| B9 | Array containment `allergies @> ARRAY[...]` | R10 | No access path for array containment (needs GIN) |
| B10 | June prescription range scanned from `prescription_items` | R15 | No index on `prescriptions.issued_at` |

---

## 5. Indexing strategy and implementation

Eleven indexes were added in `sql/05_indexes.sql`. Each statement uses
`CREATE INDEX IF NOT EXISTS`, so the file is idempotent and can be re-run. No
table, column, constraint or existing index was modified, and all 30 index
definitions in the schema are distinct (no duplicate indexes).

| # | Index | Columns / predicate | Serves | Size |
|---|---|---|---|---:|
| 1 | `idx_appt_patient_status_slot` | `(patient_id, status, slot_start)` | R04 | 5,960 kB |
| 2 | `idx_appt_doctor_slot` | `(doctor_id, slot_start)` | R03, R05, R19, W05 | 4,632 kB |
| 3 | `idx_appt_patient_doctor_slot` | `(patient_id, doctor_id, slot_start)` | R11 | 4,640 kB |
| 4 | `idx_appt_slot_start_appt` | `(slot_start, appointment_id) INCLUDE (status, consult_type, patient_id, doctor_id, clinic_id)` | R08, R09, R12, R16, R17, R20, R22, R25 | 10,000 kB |
| 5 | `idx_appt_completed_pending` | `(slot_start DESC) INCLUDE (patient_id, clinic_id, fee) WHERE status='COMPLETED' AND payment_status='PENDING'` | R21 | 992 kB |
| 6 | `idx_appt_booked_inclinic_slot` | `(slot_start) WHERE status='BOOKED' AND consult_type='IN_CLINIC'` | W02 | 40 kB |
| 7 | `idx_appt_pending_noshow_slot` | `(slot_end) WHERE status IN ('BOOKED','CHECKED_IN') AND consult_ended_at IS NULL` | W04 | 40 kB |
| 8 | `idx_sched_clinic` | `(clinic_id) WHERE clinic_id IS NOT NULL` | R13 | 208 kB |
| 9 | `idx_rx_followup` | `(follow_up_date) WHERE follow_up_date IS NOT NULL` | R11 | 224 kB |
| 10 | `idx_rx_issued` | `(issued_at) INCLUDE (appointment_id)` | R15 | 3,016 kB |
| 11 | `idx_patients_allergies` | GIN `(allergies)` | R10 | 80 kB |

**Total: 29,832 kB (≈ 29.1 MB).** Database size grew from 83 MB to 113 MB
(+36%), which is the storage price of the read improvements.

### 5.1 Why these shapes

* **Equality before range, range before sort.** `(patient_id, status,
  slot_start)` serves R04 completely: equality on the first two columns,
  index-ordered output for `ORDER BY slot_start`.
* **One covering index instead of several overlapping ones.** The first draft
  had two `slot_start` indexes; they were merged into
  `idx_appt_slot_start_appt`. `appointment_id` in the key is both a
  tie-breaker and the column that makes keyset pagination possible later;
  `status`, `consult_type`, `patient_id`, `doctor_id` and `clinic_id` are read
  by the reports, so the reports become index-only scans.
* **Partial indexes only for genuinely small subsets.** The data distribution
  decided this: `COMPLETED` is 121,409 of 150,000 rows (81%), so a partial
  index on it would not be more selective than the plain index — rejected.
  `BOOKED` is 1,823 rows and the unclosed `BOOKED/CHECKED_IN` set is 1,823
  rows, so those partial indexes are 40 kB each and behave like a small table
  with the right order built in.
* **GIN only where it changes the plan.** R10's `allergies @> ARRAY['Penicillin']`
  selects 1,737 of 40,000 patients and the planner uses
  `idx_patients_allergies` in the recorded plan. A GIN index on
  `doctors.languages` was created, measured and then **dropped**: `'Tamil' = ANY(languages)`
  matches 360 of only 3,000 doctors, and the planner kept choosing the
  sequential scan, so the index would have been pure write cost. A trigram
  index for `medicine_name ILIKE '%amoxicillin%'` (16,206 of 243,085 items,
  6.7%) was rejected for the same reason.

### 5.2 Rejected index candidates

| Candidate | Why it was rejected |
|---|---|
| GIN on `doctors.languages` | 360/3,000 matches; planner never used it; measured and removed |
| Trigram on `prescription_items.medicine_name` | 6.7% selectivity does not justify 243k-entry GIN maintenance |
| Partial `(doctor_id, slot_start) WHERE status <> 'CANCELLED'` | Planner ignored it; the plain `(doctor_id, slot_start)` already covers R03/R05/R19/W05 |
| Partial index on `COMPLETED` alone | 81% of the table — no selectivity gain |
| Two separate slot-range indexes | Merged into the single covering `idx_appt_slot_start_appt` |
| `(status, slot_start)` wide variant | Larger and slower than the `slot_start`-first covering index for every query in the workload |

---

## 6. Query rewriting and optimization techniques

Only four queries were rewritten for sargability. The rewrites are exact
equivalences under the unchanged session time zone, and the result-equivalence
audit (Appendix A) confirms this.

| Query | Change | Effect |
|---|---|---|
| R05 | `DATE(a.slot_start) = DATE '2026-06-30'` → `slot_start >= DATE '2026-06-30' AND slot_start < DATE '2026-07-01'` | Enables `idx_appt_doctor_slot` instead of a full scan |
| R08 | `EXTRACT(YEAR FROM slot_start) = 2026` → `[2026-01-01, 2027-01-01)` | Enables the covering slot index |
| R12 | same `EXTRACT(YEAR …)` → half-open range | Enables an index-only scan |
| R20 | `slot_start::date BETWEEN '2026-06-01' AND '2026-06-30'` → `[2026-06-01, 2026-07-01)`; the `::date` cast stays only in the `SELECT` list | Enables the covering index |

### 6.1 R13 — a semantic correction, not just an optimization

The original predicate is `c.clinic_id NOT IN (SELECT clinic_id FROM doctor_schedules)`.
`doctor_schedules.clinic_id` is nullable: video schedule blocks have
`clinic_id IS NULL`. When a subquery row is NULL, `NOT IN` evaluates to
UNKNOWN for every candidate row, so the query returned **0 rows** regardless of
the data — it was a correctness bug that hid behind a fast execution time.

`NOT EXISTS` expresses the stated business rule ("clinics where no doctor has
any schedule") and returns **292 clinics**. This means R13's before/after
timing compares two different result sets and must not be read as a pure
speed-up; it is reported here for completeness and marked accordingly in the
table below.

### 6.2 Rewrites that were tried and rejected

* **R19 as a set-based query.** Grouping `appointments` once and joining was
  measured at **≈ 30 ms**, versus **≈ 15–17 ms** for the original correlated
  form once `idx_appt_doctor_slot` exists (each of the 480 loops becomes a
  bitmap index probe: 2,611,500 → 28,159 buffer hits). The rewrite was
  rejected and R19's SQL is unchanged.
* **R24 as a "duplicate slots first" group-by.** The group-by form has to
  aggregate 134,546 groups and spills at `work_mem` 4 MB (5 batches, 9,273 kB
  of hash memory, 1,656 kB on disk); it measured **68.3 ms** in this audit
  (30–54 ms in the earlier trials, depending on the exact variant) against
  23–38 ms for the hash self-join below. The partial `(doctor_id, slot_start)`
  index that was meant to support it was ignored by the planner. R24 is a
  full-table data-quality scan over a 150,000-row table where the `CANCELLED`
  filter removes only 14,900 rows; no index is selective enough. Left
  unchanged.
* **Keyset pagination for R22.** It would have replaced the 100,000-row skip
  with a seek, but it changes the query interface (the caller must pass the
  last `(slot_start, appointment_id)` pair) and page 4,001 must return exactly
  the CP2 rows. It was rejected to preserve the contract; the index is
  designed so that a keyset variant is a drop-in later. See section 9.

No other query text changed. R01, R02, R06, R07, R09, R10, R14, R15, R16,
R17, R18, R21, R23, R24, R25, W01–W05 keep their CP2 SQL verbatim.

---

## 7. Before/after results — all 30 queries

Improvement is `((baseline − optimized) / baseline) × 100`; a negative number
means the optimized measurement was slower. Values are the averages of three
runs from `benchmarks/results/optimized/summary.csv` and
`benchmarks/results/baseline/summary.csv`. The control column is the same CP2
workload re-run on the CP2 schema in the same session (section 2.1).

| Query | Type | CP2 baseline (ms) | CP3 optimized (ms) | Change (ms) | Improvement | Same-session control (ms) | vs control |
|---|---|---:|---:|---:|---:|---:|---:|
| R01 | READ | 2.251 | 4.386 | +2.135 | -94.8% | 4.973 | +11.8% |
| R02 | READ | 0.259 | 0.715 | +0.456 | -176.1% | 0.627 | -14.0% |
| R03 | READ | 11.598 | 0.741 | -10.857 | +93.6% | 16.797 | +95.6% |
| R04 | READ | 6.406 | 0.143 | -6.263 | +97.8% | 11.628 | +98.8% |
| R05 | READ | 5.016 | 0.132 | -4.884 | +97.4% | 8.203 | +98.4% |
| R06 | READ | 0.091 | 0.065 | -0.026 | +28.6% | 0.049 | -32.7% |
| R07 | READ | 0.136 | 0.140 | +0.004 | -2.9% | 0.149 | +6.0% |
| R08 | READ | 20.798 | 21.314 | +0.516 | -2.5% | 34.679 | +38.5% |
| R09 | READ | 7.619 | 3.564 | -4.055 | +53.2% | 9.171 | +61.1% |
| R10 | READ | 17.031 | 20.417 | +3.386 | -19.9% | 16.872 | -21.0% |
| R11 | READ | 16.160 | 1.305 | -14.855 | +91.9% | 15.985 | +91.8% |
| R12 | READ | 23.710 | 11.372 | -12.338 | +52.0% | 22.722 | +50.0% |
| R13 | READ | 2.494 | 0.880 | -1.614 | +64.7% | 3.075 | +71.4% |
| R14 | READ | 18.353 | 23.743 | +5.390 | -29.4% | 21.214 | -11.9% |
| R15 | READ | 19.729 | 17.185 | -2.544 | +12.9% | 19.954 | +13.9% |
| R16 | READ | 9.039 | 2.384 | -6.655 | +73.6% | 10.563 | +77.4% |
| R17 | READ | 41.351 | 38.053 | -3.298 | +8.0% | 41.663 | +8.7% |
| R18 | READ | 3.684 | 4.272 | +0.588 | -16.0% | 4.817 | +11.3% |
| R19 | READ | 4317.298 | 14.026 | -4303.272 | +99.7% | 4343.242 | +99.7% |
| R20 | READ | 7.771 | 1.195 | -6.576 | +84.6% | 9.373 | +87.3% |
| R21 | READ | 7.946 | 0.074 | -7.872 | +99.1% | 10.529 | +99.3% |
| R22 | READ | 32.704 | 10.421 | -22.283 | +68.1% | 33.765 | +69.1% |
| R23 | READ | 0.122 | 0.031 | -0.091 | +74.6% | 0.030 | -3.3% |
| R24 | READ | 22.209 | 29.532 | +7.323 | -33.0% | 24.472 | -20.7% |
| R25 | READ | 19.076 | 14.313 | -4.763 | +25.0% | 18.913 | +24.3% |
| W01 | WRITE | 0.948 | 0.725 | -0.223 | +23.5% | 0.612 | -18.5% |
| W02 | WRITE | 6.818 | 0.308 | -6.510 | +95.5% | 9.998 | +96.9% |
| W03 | WRITE | 0.210 | 0.181 | -0.029 | +13.8% | 0.166 | -9.0% |
| W04 | WRITE | 9.335 | 20.363 | +11.028 | -118.1% | 15.525 | -31.2% |
| W05 | WRITE | 6.725 | 0.280 | -6.445 | +95.8% | 10.484 | +97.3% |
| **Total** | | **4636.9** | **242.3** | **-4394.6** | **+94.8%** | **4720.2** | **+94.9%** |

Aggregate view: reads **4,612.9 → 220.4 ms (+95.2%)**, writes **24.0 →
21.9 ms**, total **4,636.9 → 242.3 ms (+94.8%)**. Excluding R19, which
dominated the baseline, the remaining 29 queries improve from **319.6 ms to
228.2 ms (+28.6%)**.

---

## 8. Reading the results honestly

The table contains 21 improvements and 9 regressions. The regressions are
grouped and explained below rather than hidden, because the environment drift
described in section 2.1 is large enough to flip small queries.

**Real, plan-level wins (robust):**

* **R19: 4,317 ms → 14.0 ms (+99.7%).** Two 480-loop sequential scans became
  bitmap index probes; buffer hits fell from ~2.61 M to ~28.2 k. This alone
  accounts for 98% of the total absolute saving.
* **R21 +99.1%, R04 +97.8%, R05 +97.4%, W02 +95.5%, W05 +95.8%, R03 +93.6%,
  R11 +91.9%, R20 +84.6%, R16 +73.6%, R22 +68.1%, R09 +53.2%, R12 +52.0%.**
  These all changed execution node type (seq scan → index scan, bitmap scan or
  index-only scan) and are far outside the noise band; the control column
  agrees in every case. (R13 and R08 have their own caveats below.)
* **R06, R07, R23, W01, W03** were already at or below ~1 ms and stay there
  (largest optimized average: W01 at 0.725 ms); their percentages are noise,
  not engineering wins.
  R07 is nominally a regression (−2.9%) but the whole difference is 0.004 ms
  (0.136 → 0.140 ms) and the 3-run ranges overlap.

**Regressions on unchanged SQL and plans:**

* **R01 (−94.8%), R02 (−176.1%), R18 (−16.0%)** run byte-identical SQL on
  plans that do not touch any new index (small dimension tables). Against the
  same-session control, R01 is 11.8% faster and R18 is 11.3% faster; R02 is
  still slightly slower but its whole range is 0.65–0.82 ms. The CP2 numbers
  were measured on a quieter machine — R01's baseline median was 1.551 ms
  versus 4.156 ms now, with the same plan.
* **R14 (−29.4%)** is a hash join over `doctor_reviews` + `appointments` with
  byte-identical SQL and a node-for-node identical plan (two sequential scans;
  no CP3 index is touched). Its spread here was 19.6–28.8 ms. This one is not
  fully explained by drift: the same-session control measured 21.2 ms, so the
  optimized average (23.7 ms) is 11.9% slower than the control as well. With
  identical SQL, plan and schema-independent access path, the difference can
  only be execution variance on the loaded host, but it is reported as an
  unexplained slowdown rather than blamed on the indexes.
* **R24 (−33.0%)** is a parallel hash self-join on unchanged SQL; the plan is
  the same `Seq Scan on appointments` with parallel workers in CP2, control and
  CP3 (checked against the scan-node field of both CSVs), so no index is
  involved. Runs ranged 23.1–38.3 ms here versus 21.7–23.2 ms in CP2; the
  control measured 24.5 ms, so the optimized average is 20.7% slower than the
  control too. The ranges overlap (the 23.1 ms run is inside the control's
  range), which points at parallel-worker start-up on a busy host rather than
  at the indexes — but as with R14 this is variance, not a proven cause.

**Regressions that need a caveat:**

* **R08 (−2.5% vs CP2, +38.5% vs control).** R08 *was* rewritten and its plan
  improved (seq scan + hash aggregate → index-only scan), but the CP2 run
  happened to be fast that day. Against the same-session control it is 38.5%
  faster, which is the meaningful comparison.
* **R10 (−19.9%) — index used, end-to-end benefit not demonstrated.** The
  recorded plan does use the index (`Bitmap Index Scan on
  idx_patients_allergies`, 1,737 rows), and it does help the predicate itself:
  `SELECT count(*) FROM patients WHERE allergies @> ARRAY['Penicillin']`
  measured 2.099 / 1.442 / 1.715 ms with the index (161 heap buffers) versus
  4.624 / 4.309 / 3.867 ms as a sequential scan of the 1,055-page `patients`
  table with the index dropped inside a rolled-back transaction. In the full
  query, however, four rounds of interleaved A/B executions in one session
  (index present → dropped → present …, two runs per “dropped” round) gave
  43.4, 34.7, 17.0, 14.7, 15.3 ms with the index and 37.7, 23.6, 22.3, 21.6,
  17.9, 17.7, 16.9, 16.8, 15.9, 15.3 ms without it — indistinguishable, and in
  some pairs slower with the index.
  The reason is visible in the plan: at 4.3% selectivity the bitmap heap scan
  scatters over ~533 of 1,055 pages, which is no cheaper than reading the
  table sequentially, while the 726-row join fan-out dominates the total. The
  recorded pass measured 17.1–24.6 ms against 15.2–20.2 ms in CP2 and
  15.7–18.3 ms in the control. The index is kept (80 kB) because `@>` has no
  other access path and it would pay off for a rarer allergy tag, but no
  speedup is claimed for R10.
* **W04 (−118.1%) — a reproducible first-run effect, not a random stall.** The
  three recorded runs were 3.947 / 4.006 / 53.137 ms, so the mean (20.363) is
  not a useful summary. The first run of the pass also dirtied 1,071 buffers
  while runs 2 and 3 dirtied 8 and 5: the transaction that first writes the
  329 affected rows pays to mark their heap pages dirty, later runs find those
  pages already dirty and roll back cheaply. Ten isolated executions of the
  identical statement in one session reproduced exactly that shape:
  **29.764, 3.761, 2.955, 2.235, 6.044, 3.083, 3.200, 3.800, 2.544, 3.049 ms**
  — first execution slow, the rest 2.2–6.0 ms. The 53 ms value is therefore a
  real measurement of a real first-run cost, but it is unrepresentative of the
  steady-state cost of the statement. The plan moved from a full scan to
  `idx_appt_pending_noshow_slot` with 300 buffer hits, and the median
  (4.006 ms) and minimum (3.947 ms) are both better than the CP2 median
  (9.303 ms). The CSV keeps the measured three runs; the median is the fair
  statistic here, and the mean is reported as-is rather than trimmed.

**R13's caveat.** As explained in section 6.1, the optimized R13 returns 292
rows where the baseline returned 0. The 64.7% figure compares a correct query
with a broken one and is included only for completeness.

---

## 9. Execution plan observations

`benchmarks/results/optimized/*.txt` holds the plan of the last recorded run
for each query. The node changes that matter:

| Query | Baseline node(s) | Optimized node(s) | Evidence |
|---|---|---|---|
| R19 | Nested Loop + 2 × `Seq Scan on appointments` (480 loops each) | Nested Loop + `Bitmap Index Scan on idx_appt_doctor_slot` (480 loops) | 1,305,600 → ~1,524 buffer hits for the index probes; 4,335 ms → 13.1 ms for the identical statement |
| R21 | `Parallel Seq Scan` + `Sort (top-N heapsort)` | `Index Scan using idx_appt_completed_pending`, no sort | 8.0 ms → 0.066 ms; only 100 rows touched for `LIMIT 100` |
| R22 | `Seq Scan` (all 150,000 rows) + `Sort (external merge, 6,176 kB on disk)` | `Index Only Scan Backward using idx_appt_slot_start_appt`, `Heap Fetches: 0` | 33.977 ms → 9.306 ms; 2,720 → 831 buffer hits |
| R03 | `Seq Scan on appointments` inside the anti-join, 7.6 ms of a 7.603 ms run | `Bitmap Index Scan on idx_appt_doctor_slot` | 7.603 ms → 0.738 ms |
| R11 | Anti-join re-checked appointments in a hash/nested-loop over the full table | `Index Scan using idx_rx_followup` driving 430 loops of `Index Scan using idx_appt_patient_doctor_slot` (rows=0 per probe) | 16.482 ms → 1.379 ms |
| R16 | `Seq Scan on appointments` + hash aggregate | `Bitmap Heap Scan on appointments` through `idx_appt_slot_start_appt` + hash aggregate | 8.918 ms → 2.601 ms |
| R08, R12, R17, R20, R25 | Seq scan of all 2,720 pages, some with hash aggregate | `Index Only Scan using idx_appt_slot_start_appt` (heap fetches avoided after VACUUM) | R12 23.7 → 11.4 ms; R20 7.8 → 1.2 ms; R25 19.1 → 14.3 ms |
| R13 | Hash anti-join with `NOT IN`, returned 0 rows | `Index Only Scan using idx_sched_clinic` on 24,600 in-clinic schedule rows | 292 rows, 2.494 → 0.880 ms |
| W02 | `Seq Scan` + `Sort (top-N heapsort)` to find the earliest open booking | `Index Scan using idx_appt_booked_inclinic_slot` (40 kB index) | 6.648 ms → ~0.31 ms |
| W04 | `Seq Scan on appointments` (7.8 ms of the 8.6 ms run) | `Index Scan using idx_appt_pending_noshow_slot`, 300 buffer hits | 8.644 ms → 3.947 ms (run 3 of each) |
| W05 | `Seq Scan on appointments` (6.5 ms) and a filter | `Index Scan using idx_appt_doctor_slot` | 6.683 → 0.234 ms (run 3 of each) |

Queries that keep a sequential scan (R01, R02, R09, R10, R14, R15, R17, R18,
R24) do so for a good reason: the filter is not selective enough (R24, R10's
`ILIKE`), the driving relation is tiny (R01, R02, R18), or the aggregate must
read almost every row (R14, R15, R17). R17 and R15 improved only modestly
(+8.0%, +12.9%) because the work is a large aggregate, not a lookup.

**R22 and pagination.** The index-only backward scan still visits 100,025
index entries to skip to page 4,001 — that is inherent to `OFFSET`. It is now
bounded by 831 index buffer hits instead of a 6 MB external sort. If the
console ever pages deeper, the supported replacement is keyset pagination:

```sql
WHERE (slot_start, appointment_id) < (:last_slot, :last_id)
ORDER BY slot_start DESC, appointment_id DESC
LIMIT 25;
```

This is exactly the key order of `idx_appt_slot_start_appt`, so it needs no new
index, but it changes the query interface and was therefore not applied here.

---

## 10. Write performance and index-maintenance trade-offs

Every index on `appointments` is maintained on every `INSERT`, `UPDATE` of an
indexed column and `DELETE`. The workload's write statements are all
*index-located* updates, so locating the row became cheaper at the same time as
maintenance became more expensive:

| Query | CP2 (ms) | CP3 (ms) | Note |
|---|---:|---:|---|
| W01 (single insert) | 0.948 | 0.725 | insert into a table with 7 more B-trees; still sub-ms |
| W02 (check-in one row) | 6.818 | 0.308 | was a full scan + sort to find the row |
| W03 (one prescription update) | 0.210 | 0.181 | unchanged plan |
| W04 (batch, 329 rows) | 9.335 | 20.363 avg / 4.006 median | see below |
| W05 (3 rows) | 6.725 | 0.280 | was a scan of 150k rows |

W04 is the only write where the average regressed, and the average is an
artifact of run order: two of the three runs (3.947 and 4.006 ms) are faster
than any CP2 run (8.644–10.057 ms), and the first run (53.137 ms) carries the
once-per-session page-dirtying cost described in section 8. The index reduced
the scanned buffers from a full 2,720-page scan to 300 hits; it did not make
the 329-row update slower in steady state.

Costs accepted:

* **Storage:** 29.1 MB of new indexes, +35% database size. 25.7 MB of that
  sits on `appointments`, the hottest table.
* **Write amplification:** seven new B-trees on `appointments` (plus the
  partial indexes that only exist for their own rows). In a write-heavy
  deployment the first candidates to drop are `idx_appt_completed_pending`
  (992 kB, only helps R21), `idx_appt_patient_status_slot` (5,960 kB, only
  helps R04) and the GIN index if R10 does not prove its value.
* **Vacuum/analyze:** partial and covering indexes benefit from regular
  `VACUUM` (visibility map) to keep index-only scans heap-free. This is why
  the measured pass began with `VACUUM (ANALYZE)`.

Given the workload mix (25 reads, 5 writes; reads are 99.5% of baseline time),
the trade is clearly worth it here.

---

## 11. Limitations, lessons and conclusions

### Limitations of these measurements

1. **The machine was not quiet.** Load average was ~2.3–3.0 during recording,
   against a quieter machine for CP2. Queries whose SQL did not change but
   whose plans did not change either (R01, R02, R14, R18, R24) moved by up to
   3× between sessions. The same-session control quantifies this and is the
   reason those rows are not presented as index effects. R14 and R24 were also
   slower than the control, so for those two environment drift does not fully
   explain the number — see section 8. Absolute numbers should be re-measured
   on an idle machine before being quoted anywhere else.
2. **Three runs per query is a small sample on a noisy host, and run order
   matters for writes.** W04's average is dominated by the first run of the
   pass (53.137 ms), which contains the once-per-session page-dirtying cost;
   R24's spread is 23.1–38.3 ms. The CSV reports min/median/max precisely so
   the reader can see this.
3. **Warm cache, single client, no concurrency.** These are single-session
   timings; they do not model cache-cold or concurrent workloads.
4. **`EXPLAIN ANALYZE` includes executor time, not planning time.** Planning
   overhead is reported separately in the plan files (~0.4–2.4 ms) and is not
   in the CSV.
5. **R13's timing is not comparable** to its baseline because the result set
   changed from 0 to 292 rows by design.
6. **R10's GIN benefit is unproven** in this session (section 8).
7. **No data changed**, so these numbers describe a static dataset; index
   bloat and statistics drift over time are not captured.

### Lessons

* Measure first: R19 looked like a query problem and was an index problem;
  R13 looked like a performance problem and was a correctness problem.
* Data distribution, not intuition, decides partial indexes: `COMPLETED` at 81%
  of the table is worthless as a partial predicate, `BOOKED` at 1.2% is ideal.
* A covering index can beat a clever rewrite. The R19 set-based rewrite lost
  to the indexed correlated form by ~2×, and the R24 rewrite lost outright.
* A benchmark without a control is not evidence when the machine is shared.

### Conclusions

* 11 indexes, 29.1 MB, all traceable to workload queries, and each one appears
  in the recorded plan of at least one of its target queries.
* Total workload time **4,636.9 → 242.3 ms (+94.8%)**; reads **+95.2%**;
  excluding R19, **319.6 → 228.2 ms (+28.6%)**.
* 15 queries improved by more than 50%, 8 of them by more than 90% — 14 of the
  15 are like-for-like; the fifteenth is R13, whose figure compares different
  result sets (section 6.1).
* Of the nine regressions, six (R01, R02, R07, R14, R18, R24) run unchanged SQL
  on unchanged plans; R08's plan improved and is 38.5% faster than the
  same-session control; W04's mean is a first-run artifact whose median is 57%
  better than baseline; R10's GIN index helps its predicate but has no
  demonstrated end-to-end benefit and is the one open item.
* One correctness defect (R13) was found and fixed, with its semantic change
  documented in both SQL files and here.

---

## Appendix A — Verification performed

* **Result equivalence.** Every one of the 30 queries was executed in its CP2
  and CP3 form on the same snapshot, and the full result text was hashed twice:
  once in returned order and once sorted. **29/30 are identical** as multisets,
  and for 21 of the 25 reads the row order is identical too. R08, R10 and R24
  return the same rows in a different order, and the `ORDER BY` key sequence is
  identical in all three
  (the differences are only within tie groups: `no_show_pct`, `issued_at`,
  `slot_start`). R13 differs by design (0 → 292 rows, section 6.1).
* **Write equivalence.** Each write ran inside `BEGIN … ROLLBACK` in both
  versions; the command tag and an md5 of the affected table were compared.
  All five match (`INSERT 0 1`, `UPDATE 1`, `UPDATE 1`, `UPDATE 329`,
  `UPDATE 3`), and the table checksums are identical, so the optimized writes
  change exactly the same rows.
* **R13 semantics.** `doctor_schedules` contains 5,899 NULL `clinic_id` rows,
  which is why `NOT IN` returns 0 rows. `NOT EXISTS` and an independent
  `LEFT JOIN … IS NULL` formulation both return 292 of the 1,500 clinics.
* **Write safety.** All five writes were executed inside `BEGIN … ROLLBACK` by
  the harness. After all benchmark passes the database was checked:
  `appointments` still 150,000 rows, appointment `90000001` absent,
  prescription 18872 still had its original notes and a NULL follow-up date.
* **Index inventory.** `pg_indexes` reports 30 indexes with 30 distinct
  definitions — no duplicates, and the 19 CP2 constraint indexes are untouched.
  All 11 new indexes report `indisvalid` and `indisready` true, and every one
  has a non-zero `idx_scan` after the workload runs, so none is dead weight.
* **Index re-run.** `sql/05_indexes.sql` was executed a second time on the
  populated database: every statement reported “already exists, skipping”, the
  inventory still listed 11 valid indexes, and no data or constraint changed.
* **Scripts.** `sql/05_indexes.sql` runs cleanly (idempotent, and validated
  from scratch by dropping every `idx_%` index and re-running);
  `sql/06_optimized_queries.sql` executes all 30 statements with
  `ON_ERROR_STOP=1`.
* **Files.** CP1/CP2 deliverables (`sql/01_schema.sql`, `sql/02_load_data.sql`,
  `queries/workload_30.sql`, `docs/03_baseline_timings.md`,
  `benchmarks/results/baseline/*`) were not modified.

## Appendix B — Reproducing the measurements

```bash
createdb Practo
psql -d Practo -v ON_ERROR_STOP=1 -f sql/01_schema.sql
psql -d Practo -v ON_ERROR_STOP=1 -f sql/02_load_data.sql
psql -d Practo -v ON_ERROR_STOP=1 -f sql/05_indexes.sql      # CP3 indexes

# Baseline (CP2 schema, 19 constraint indexes only):
PGDATABASE=Practo ./benchmarks/run_benchmark.sh Practo baseline 3 queries/workload_30.sql

# Optimized (CP3 indexes + rewritten workload):
PGDATABASE=Practo ./benchmarks/run_benchmark.sh Practo optimized 3 sql/06_optimized_queries.sql
```

The harness writes `benchmarks/results/<label>/summary.csv` and one
`<query_id>.txt` plan per query. For a comparison you can trust, run the
control (baseline workload on the baseline schema) in the same session as the
optimized run, and record min/median/max rather than only the average.
