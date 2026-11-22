# CP4 Large-Scale Investigation — R19 Bottleneck, R17 Reconciliation, Full Workload Status

**Team:** T0095 Dwelling · **Section:** C
**Database:** `practo_t0095_large` (PostgreSQL 18.6)
**Date:** 2026-11-22
**Workload:** `queries/workload_30.sql` (unchanged)

---

## 1. Status correction

`docs/05_scalability_report.md` now contains the current scalability report.
The earlier blocked-state version has been replaced, and the dataset is no
longer missing:

- `DE_Project_2026/large_data/` contains the 11 CSV files.
- `practo_t0095_large` contains **3,000,000 appointments**, 800,000 patients,
  60,000 doctors, and 609,747 schedules (1,473 MB).

This document is the detailed investigation record. Measured workload queries
were run **three times**; R13 and R19 timed out on the first attempt and retain
their `TIMED_OUT` classification. It records what was actually measured, what
timed out, and what remains unmeasured. The original
workload SQL and the existing `baseline/`, `optimized/`, and `before/` results
were not modified.

The large database has **only the primary-key index** on `appointments`
(`appointments_pkey`). No CP3 optimization index exists there. The results in
this report are therefore **baseline-schema** measurements at 3M rows, not
optimized-schema measurements.

Environment: `shared_buffers=128MB`, `work_mem=4MB`,
`effective_cache_size=4GB`, `random_page_cost=4`,
`max_parallel_workers_per_gather=2`. Full capture:
`benchmarks/results/large/environment.txt`.

---

## 2. R19 — original query, plan, and bottleneck

### 2.1 Exact original SQL

Extracted verbatim from `queries/workload_30.sql` (lines beginning `-- @R19`):

```sql
SELECT d.doctor_id, d.full_name,
       (SELECT count(*) FROM appointments a WHERE a.doctor_id = d.doctor_id AND a.status = 'COMPLETED'
          AND a.slot_start >= '2026-06-01' AND a.slot_start < '2026-07-01') AS june_consults,
       (SELECT max(a.consult_ended_at) FROM appointments a WHERE a.doctor_id = d.doctor_id) AS last_consult_at
FROM doctors d
WHERE EXISTS (SELECT 1 FROM doctor_schedules sc JOIN clinics c ON c.clinic_id = sc.clinic_id
              WHERE sc.doctor_id = d.doctor_id AND c.city_id = 1)
ORDER BY june_consults DESC;
```

### 2.2 Non-executing estimated plan

`EXPLAIN (VERBOSE, COSTS)` was run first; it does not execute the query.
Full output: `benchmarks/results/large/experiments/r19_original_explain_costs.txt`.

```text
Sort  (cost=11432399591.16..11432399730.60 rows=55776 width=36)
  Sort Key: ((SubPlan 1)) DESC
  ->  Hash Right Semi Join  (cost=3273.00..11432395193.96 rows=55776 width=36)
        Hash Cond: (sc.doctor_id = d.doctor_id)
        ->  Hash Join  (cost=851.00..13093.23 rows=97560 width=4)
              Hash Cond: (sc.clinic_id = c.clinic_id)
              ->  Seq Scan on doctor_schedules sc  (cost=0.00..10641.47 rows=609747)
              ->  Hash  (cost=791.00..791.00 rows=4800 width=4)
                    ->  Seq Scan on clinics c  (cost=0.00..791.00 rows=4800)
                          Filter: (c.city_id = 1)
        ->  Hash  (cost=1672.00..1672.00 rows=60000 width=20)
              ->  Seq Scan on doctors d  (cost=0.00..1672.00 rows=60000)
        SubPlan 1
          ->  Aggregate  (cost=113736.21..113736.22 rows=1 width=8)
                ->  Seq Scan on appointments a  (cost=0.00..113736.20 rows=3)
                      Filter: (slot_start >= ... AND slot_start < ...
                               AND doctor_id = d.doctor_id AND status = 'COMPLETED')
        SubPlan 2
          ->  Aggregate  (cost=91233.26..91233.27 rows=1 width=8)
                ->  Seq Scan on appointments a_1  (cost=0.00..91233.12 rows=56)
                      Filter: (a_1.doctor_id = d.doctor_id)
```

Estimated total cost is **11,432,399,591.16**. The plan is a
`Hash Right Semi Join` for the `EXISTS`, plus two correlated `SubPlan`
aggregates over `appointments`. Both subplans are **sequential scans of the
full 3M-row heap**; the plan uses no index for `appointments.doctor_id`.

### 2.3 Why it becomes expensive at 3M appointments

Measured facts:

| Fact | Value |
|---|---:|
| Doctors with a Bengaluru clinic (outer rows) | **9,600** |
| `appointments` rows | **3,000,000** |
| Indexes on `appointments` | only `appointments_pkey (appointment_id)` |
| Estimated SubPlan 1 cost per loop | 113,736.21 |
| Estimated SubPlan 2 cost per loop | 91,233.26 |
| Correlated subplan executions for full query | 2 × 9,600 = **19,200** |
| Row visits implied by full scans | 19,200 × 3,000,000 ≈ **57.6 billion** |

There is no `appointments(doctor_id)` index. The primary key cannot help
because the subqueries filter on `doctor_id`, not `appointment_id`. Every outer
doctor therefore causes two complete heap scans.

This also explains the apparent superlinear scaling from the seed benchmark.
At seed scale R19 took about 4.9 s with 480 outer doctors and 150,000
appointments (480 × 2 × 150,000 = 144M row visits). At large scale there are
20× more appointments **and** 20× more outer doctors, so the correlated work
grows by roughly **400×** (≈57.6B row visits), not 20×.

The cost-based row estimate (`rows=55776`) is also about 5.8× the actual
9,600 outer rows, but that estimate error is not the primary cause; the missing
index and the per-doctor repeated scans are.

### 2.4 Execution evidence and timeout

The original R19 was executed with a controlled
`statement_timeout = 60000 ms`:

```text
ERROR:  canceling statement due to statement timeout
real 60.02
```

This is a **timeout, not an execution-time measurement**. The full query never
completed. Evidence:
`benchmarks/results/large/experiments/r19_original_timeout_60s.txt`.

To measure the per-doctor cost without waiting ~38 minutes, the same correlated
query was restricted to **40 sampled Bengaluru doctors** (a modified query,
used only for diagnosis):

| Metric | Value |
|---|---:|
| Outer loops | 40 |
| SubPlan 1 per loop | 133.067 ms |
| SubPlan 2 per loop | 107.674 ms |
| Total execution | **9,630.451 ms** |
| SubPlan 1 buffers | shared hit 409,266; read 1,740,254 pages |
| SubPlan 2 buffers | shared hit 409,360; read 1,740,160 pages |

Evidence:
`benchmarks/results/large/experiments/r19_original_sample_explain.txt`.

Extrapolating 40 loops to 9,600 loops gives
`9,630 ms × 240 ≈ 2,311 s ≈ 38.5 minutes`. This is an **extrapolation**, not a
measurement, but it is consistent with the seed-scale 400× work argument.

### 2.5 Set-based rewrite (equivalence scope in §2.6)

The rewrite aggregates `appointments` once by `doctor_id`, then left-joins to
the doctors that satisfy the Bengaluru `EXISTS`:

```sql
SELECT d.doctor_id, d.full_name,
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
```

Saved as `sql/07_r19_rewrite.sql`.

Semantics preserved:

- For a doctor with no appointments, the left join yields no `g` row;
  `coalesce(..., 0)` gives `0`, and `last_consult_at` is NULL — matching
  `count(*) = 0` and `max(...) = NULL` in the original.
- For a doctor with appointments but no completed June consultation,
  `count(*) FILTER` returns `0`, matching the original `count(*)`.
- `max(consult_ended_at)` is over **all** appointments, with no status filter,
  exactly as in the original.
- The outer `EXISTS` and `ORDER BY june_consults DESC` are unchanged.

### 2.6 Equivalence evidence — scope and limitation

Both checks compare complete result rows, including `full_name` and
`last_consult_at`, using `EXCEPT ALL` in both directions inside a rolled-back
transaction.

| Scope | Original rows | Rewrite rows | Original-only | Rewrite-only | June sum |
|---|---:|---:|---:|---:|---:|
| Seed `Practo` (150K appointments, **full result**) | 480 | 480 | **0** | **0** | 1083 / 1083 |
| Large DB, **40 sampled** Bengaluru doctors | 40 | 40 | **0** | **0** | 432 / 432 |

Evidence:
`benchmarks/results/large/experiments/r19_equivalence_seed.txt` and
`r19_equivalence_large_sample.txt`.

**Evidence limitation (important):** full-result equivalence is established
only at **seed scale (150K appointments)**. At large scale, only **40 of the
9,600 qualifying doctors** were compared. A full large-scale comparison would
require completing the original correlated query, which is estimated at
**~38.5 minutes** by extrapolation and was not run. Therefore **full
large-dataset equivalence is not established**; the rewrite is supported by
(1) the complete seed-scale result comparison and (2) a 40-doctor large-scale
sample comparison, not by a full 9,600-doctor large-scale comparison. This
limitation must be carried into any final claim about R19.

### 2.7 Rewrite performance

Full rewrite on all 3M appointments, all 9,600 doctors, 60,000 doctors grouped:

| Run | Planning | Execution | Rows |
|---|---:|---:|---:|
| First (cold-ish) | 1.303 ms | **349.504 ms** | 9,600 |
| Warm 1 | 1.430 ms | 262.202 ms | 9,600 |
| Warm 2 | 0.510 ms | 248.240 ms | 9,600 |
| Warm 3 | 0.567 ms | 242.277 ms | 9,600 |

Warm median: **248.240 ms**. The plan is one scan/aggregate of
`appointments` (HashAggregate, ~293 ms in the first plan), one hash join to the
9,600 qualifying doctors, and a sort of 9,600 rows. It avoids the 19,200
correlated executions entirely.

**Timing method:** all numbers above are server-reported `Execution Time` from
`EXPLAIN (ANALYZE, BUFFERS)`; planning time is reported separately and client
wall time is not used. One first/cold-ish run and three warm runs were
recorded. The ~38.5-minute original figure remains an extrapolation from the
40-doctor sample, not a measured execution.

Against the original's controlled 60 s timeout, the measured rewrite is at
least **~170× faster** than the failure bound (`60,000 / 349.5`). It is not a
measured 170× speedup against a completed original execution, because the
original never completed.

### 2.8 Proposed optimization

1. **Use the set-based rewrite for R19 reporting.** It is measured, validated
   to the scope in §2.6, and removes the correlated scans without schema
   changes.
2. **Add an index for the correlated form and the rest of the workload**, e.g.
   `appointments (doctor_id, slot_start) INCLUDE (status, consult_ended_at)`.
   This is the same family as the CP3 `idx_appt_doctor_slot` that took seed R19
   from 4,317 ms to 14.0 ms in the existing optimized results. It was **not**
   created or measured on the 3M-row database in this investigation, so no
   large-scale index speedup is claimed here.
3. If the city report runs frequently, a maintained per-doctor summary
   (`june_consults`, `last_consult_at`) would make it O(doctors), but that is a
   design change and was not evaluated.

---

## 3. R17 — reconciling ~489 ms with the reported 40 s timeout

### 3.1 What was measured now

R17 on the 3M-row database, default settings, with
`statement_timeout = 40s`:

| Run | Execution Time |
|---|---:|
| 1 | 473.594 ms |
| 2 | 446.679 ms |
| 3 | 449.709 ms |
| Median | **449.709 ms** |
| Parallelism disabled (`max_parallel_workers_per_gather=0`) | 996.392 ms |

The three-run harness average in `summary.csv` is **464.826 ms** (median
464.343 ms; three completed runs). Buffers were about 52,000 read pages plus
~7,800 temp pages per run; the first run was colder than the later ones. Evidence:
`benchmarks/results/large/experiments/r17/default_runs.txt` and
`parallel_disabled.txt`.

The earlier **~489 ms** claim is therefore corroborated: it is within roughly
5–10% of the measured 446–474 ms dedicated range and uses the same plan
(`GroupAggregate` over `Parallel Hash Join` of `appointments` and `patients`,
with sequential scans on both). That difference is ordinary cache/run
variation, not a different plan.

### 3.2 The 40 s claim

No plan, log, or result file from a 40 s R17 execution exists in the
repository. The saved R17 artifacts are the seed-scale baseline (49.5 ms) and
the current large-scale runs above. Under the current environment:

- R17 completes in **< 1 s** in every attempt, including with parallelism
  disabled.
- The plan is the same parallel hash join each time; no nested-loop or
  per-row plan appears.
- A 40 s result would require roughly **86×** the measured 464 ms harness
  average, which this plan and data do not produce.

What can be established: the 40 s figure is **not reproducible** as an R17
execution-time measurement on this database, plan, and machine. What cannot be
established from the available evidence is the exact condition of the earlier
40 s attempt. Plausible but unproven explanations are a different execution
(e.g. lock/contention or a concurrent benchmark), a different query or database,
or a harness-level timeout misattributed to R17. Since no artifact exists, the
40 s figure should be classified as **unresolved**, not reported as R17's
execution time. The measured value to use is **~464 ms** (3-run harness
average; median 464.343 ms; dedicated R17 median 449.7 ms).

---

## 4. Full workload status on 3M appointments

Each of the 30 statements was run **three times** with
`statement_timeout = 60000 ms`, matching the official three-run methodology.
A query that timed out stopped after that attempt. Writes ran inside
`BEGIN … ROLLBACK`. `MEASURED` means all three runs completed and produced
execution times; `TIMED_OUT` means 0/3 runs completed and no execution time
exists. The table reports the **official average of the three completed runs**;
median/min/max are in `summary.csv`. Source:
`benchmarks/results/large/summary.csv`.

| Query | Type | Status | Runs | Average (ms) | Note |
|---|---|---|---:|---:|---|
| R01 | READ | MEASURED | 3/3 | 48.312 | |
| R02 | READ | MEASURED | 3/3 | 0.039 | |
| R03 | READ | MEASURED | 3/3 | 58.826 | |
| R04 | READ | MEASURED | 3/3 | 51.631 | |
| R05 | READ | MEASURED | 3/3 | 45.657 | |
| R06 | READ | MEASURED | 3/3 | 0.134 | |
| R07 | READ | MEASURED | 3/3 | 0.153 | |
| R08 | READ | MEASURED | 3/3 | 298.415 | |
| R09 | READ | MEASURED | 3/3 | 77.842 | |
| R10 | READ | MEASURED | 3/3 | 279.876 | median 240.617; max 363.401 |
| R11 | READ | MEASURED | 3/3 | 128.874 | |
| R12 | READ | MEASURED | 3/3 | 275.599 | |
| R13 | READ | **TIMED_OUT** | 0/3 | — | 60 s; also 240 s; see §5 |
| R14 | READ | MEASURED | 3/3 | 323.844 | |
| R15 | READ | MEASURED | 3/3 | 239.899 | |
| R16 | READ | MEASURED | 3/3 | 88.391 | |
| R17 | READ | MEASURED | 3/3 | 464.826 | dedicated median 449.709; see §3 |
| R18 | READ | MEASURED | 3/3 | 45.998 | |
| R19 | READ | **TIMED_OUT** | 0/3 | — | 60 s; rewrite measured at 349.5 ms; see §2 |
| R20 | READ | MEASURED | 3/3 | 92.314 | |
| R21 | READ | MEASURED | 3/3 | 91.340 | |
| R22 | READ | MEASURED | 3/3 | 270.176 | |
| R23 | READ | MEASURED | 3/3 | 0.858 | median 0.028; one 2.519 ms cold run |
| R24 | READ | MEASURED | 3/3 | 1507.107 | |
| R25 | READ | MEASURED | 3/3 | 255.551 | |
| W01 | WRITE | MEASURED | 3/3 | 0.708 | rolled back |
| W02 | WRITE | MEASURED | 3/3 | 133.871 | rolled back |
| W03 | WRITE | MEASURED | 3/3 | 0.058 | rolled back |
| W04 | WRITE | MEASURED | 3/3 | 251.803 | rolled back; median 187.511; max 381.055 |
| W05 | WRITE | MEASURED | 3/3 | 145.051 | rolled back |

Totals: **28 measured (3/3 runs), 2 timed out (0/3 completed), 0 errored,
0 not executed.** The timeout attempts are retained as timeout
classifications, not as execution times. No slow query was silently omitted.

---

## 5. Additional timeout found: R13 and the `NOT IN` + NULL trap

R13 was not the original target, but it is the only other timeout and must be
classified honestly.

```sql
SELECT c.clinic_id, c.clinic_name, c.city_id
FROM clinics c
WHERE c.clinic_id NOT IN (SELECT sc.clinic_id FROM doctor_schedules sc);
```

Facts:

- In the large database, `doctor_schedules` has **117,747 rows with NULL
  `clinic_id`**; the seed dataset has 5,899 NULL schedules.
- The estimated plan is a `Seq Scan on clinics` with a `SubPlan 1` that
  `Materialize`s 609,747 schedule rows; estimated cost
  **263,949,378.50**.
- Because the subquery contains NULLs, `NOT IN` evaluates to UNKNOWN for every
  clinic that does not match a non-NULL schedule value. The query is **defined
to return zero rows** (seed measured 0), but PostgreSQL still performs the
  repeated membership test; at large scale it timed out before producing them.
- It timed out at **60 s** and again at **240 s**
  (`benchmarks/results/large/experiments/r13/timeout_240s.txt`).

At seed scale this query took 2.8 ms with **1,500 clinics and 30,499
schedules** (about 46 million comparisons). At 30,000 clinics × 609,747
materialized values, the per-clinic `NOT IN` test becomes ~18 billion
comparisons.

**Original behavior and corrected business logic are different here.** The
corrected business question — “clinics where no doctor has any schedule” — is
implemented with `NOT EXISTS`:

```sql
SELECT c.clinic_id, c.clinic_name, c.city_id
FROM clinics c
WHERE NOT EXISTS (SELECT 1 FROM doctor_schedules sc
                  WHERE sc.clinic_id = c.clinic_id);
```

This corrected query returns **292 rows on the seed database `Practo`**
(1,500 clinics, 30,499 schedules, 5,899 NULL schedules) and **10,668 rows on
the large database** (30,000 clinics, 609,747 schedules, 117,747 NULL
schedules). The large query runs in **40.7–58.5 ms** across three runs
(`experiments/r13/corrected_business_logic.txt`; seed check:
`experiments/r13/corrected_business_logic_seed.txt`). The 292 → 10,668
difference is the corrected business count on two differently sized datasets,
not a contradiction: the large database has 20× more clinics and a larger
share with no non-NULL schedule.

Business meaning: “clinics with no doctor schedule that references that
clinic.” NULL `clinic_id` schedule rows represent video/no-clinic schedules
and do not associate a doctor with a clinic. The corrected query is **not
equivalent to the original**: the original returns **0 rows** because of NULL
semantics (and timed out before producing them at large scale), while the
corrected query returns the actual no-schedule clinics (292 seed / 10,668
large). The original's zero-row result is a data-quality bug, not the business
answer.

A separate diagnostic variant makes the NULL case explicit:

```sql
SELECT c.clinic_id, c.clinic_name, c.city_id
FROM clinics c
WHERE NOT EXISTS (SELECT 1 FROM doctor_schedules sc
                  WHERE sc.clinic_id = c.clinic_id)
  AND NOT EXISTS (SELECT 1 FROM doctor_schedules sc
                  WHERE sc.clinic_id IS NULL);
```

This variant returns 0 rows and is **result-equivalent to the original on the
current data** (seed check: 0/0; large: 0 rows), and runs in 0.033–0.064 ms.
It is **not** the corrected business logic and is not recommended as the
business fix; it merely reproduces the original's NULL-induced emptiness
quickly. Do not describe the corrected `NOT EXISTS` query and the original as
semantically equivalent — their actual result sets differ (0 vs 292 seed /
10,668 large).

The underlying data issue should also be fixed at the source: either forbid
NULL `clinic_id` for schedule rows that are supposed to represent clinics, or
document that NULL means video/no clinic and rewrite the report accordingly.

---

## 6. Limitations and what remains

1. **Three runs per measured workload query.** The summary reports
   avg/median/min/max over 3 completed runs. R13 and R19 timed out on the first
   attempt and stopped (0/3 completed); their timeout classifications are
   retained, and no execution time is reported.
2. **Cache state is uncontrolled.** The first R19 rewrite run was 349.5 ms;
   warm runs were 242–262 ms. R17 and R10/W04 show the same cold/warm spread.
3. **No optimized indexes exist in `practo_t0095_large`.** The large-scale
   measurements describe the baseline schema (primary key only). The CP3
   index effects are seed-scale results and are not extrapolated here.
4. **Original R19 never completed.** Its ~38.5-minute figure is an
   extrapolation from a measured 40-doctor sample, clearly labeled as such,
   not an observed execution time.
5. **R19 full large-scale equivalence is not established.** Full-result
   equality is complete only at seed scale; large-scale evidence is a
   40-doctor sample, not all 9,600 doctors. See §2.6.
6. **The 40 s R17 claim is unresolved.** No artifact exists; it is not
   reproducible and is not reported as an execution time.
7. **Timeouts are not measurements.** R13 and R19 are recorded as
   `TIMED_OUT`, with their plans and timeout bounds documented.
8. **R13 original and corrected business logic differ.** The original returns
   0 rows by NULL semantics; the corrected `NOT EXISTS` query returns 292 rows
   on seed and 10,668 on large. They are not equivalent. See §5.
9. `n_live_tup` for `appointments` is a stale planner estimate (3,000,410);
   the exact count is 3,000,000 and is the figure used here.
10. No partitioned table, index build, replica, or sharded deployment was run.

## 7. Reproduction

```bash
# Full workload: 3 runs, 60 s per statement, status-classified output
./benchmarks/run_large_benchmark.sh practo_t0095_large 3 60000

# R19 original: estimated plan only (does not execute)
psql -d practo_t0095_large -f benchmarks/results/large/experiments/r19_original_explain_costs.txt

# R19 rewrite
psql -d practo_t0095_large -f sql/07_r19_rewrite.sql
```

The new runner writes only under `benchmarks/results/large/`; it does not
overwrite the existing baseline, optimized, or before result sets.
