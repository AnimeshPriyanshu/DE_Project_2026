# Large-dataset benchmark results (CP4)

Captured **2026-11-22** against `practo_t0095_large` on PostgreSQL 18.6.

This directory is new. It does **not** replace or modify
`benchmarks/results/baseline/`, `benchmarks/results/optimized/`, or
`benchmarks/results/before/`. The workload file `queries/workload_30.sql` was
not edited.

## Dataset and environment

| Item | Value |
|---|---|
| Database | `practo_t0095_large`, 1,473 MB |
| `appointments` | **3,000,000 rows** (exact count; `n_live_tup` is a stale estimate of 3,000,410) |
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
| Indexes on `appointments` | **only `appointments_pkey (appointment_id)`** |

Full capture: `environment.txt`.

Because the large database has only the primary-key index on `appointments`,
these are **baseline-schema** measurements, not optimized-schema measurements.

## How to read `summary.csv`

Each of the 30 workload statements was executed **three times** with
`statement_timeout = 60000 ms`, matching the official three-run methodology.
A query that timed out stopped after that attempt.

| Status | Meaning |
|---|---|
| `MEASURED` | 3/3 `EXPLAIN (ANALYZE, BUFFERS, VERBOSE, COSTS)` runs completed; `avg_ms`, `median_ms`, `min_ms`, `max_ms` are over those runs |
| `TIMED_OUT` | Cancelled by `statement_timeout`; **no execution time exists**; `runs_completed=0` |
| `ERROR` | Failed for a non-timeout reason; note contains the message |
| `INCOMPLETE` | psql exited 0 but no Execution Time was emitted |

Writes (`W01`–`W05`) ran inside `BEGIN … ROLLBACK` on every run; no rows were
committed. `planning_time` and client wall time are not included in the
`*_ms` execution columns.

## Headline results

- **28 of 30 measured 3/3 runs**, **2 timed out** (`R13`, `R19`),
  **0 errored**, **0 not executed**. Timeout classifications are retained;
  timeout attempts are not execution times.
- `R19` timed out at 60 s. A 40-doctor sample of the same correlated query
  took **9,630 ms** (40 loops); the full query is estimated at ~38.5 minutes
  by extrapolation, not observed. The rewritten set-based query completes in
  **349.5 ms cold / 242–262 ms warm**.
- **R19 equivalence is limited:** the full-result comparison is at seed scale
  (480/480 rows); the large-scale comparison covers only 40 of 9,600 doctors.
  Full large-dataset equivalence is not established.
- `R13` timed out at 60 s and again at 240 s. The original `NOT IN` is defined
  to return **0 rows** because 117,747 `clinic_id` values are NULL (seed
  measured 0; large timed out). The **corrected business query** (`NOT EXISTS`)
  returns **292 rows on seed** and **10,668 rows on large** in 40.7–58.5 ms and
  is **not equivalent** to the original. A NULL-guarded diagnostic variant
  reproduces the original 0-row result in 0.033–0.064 ms but preserves the bug.
- `R17` measured **446–474 ms** in three dedicated runs and **464.826 ms** as
  the three-run harness average (median 464.343 ms; 997 ms with parallelism
  disabled), consistent with the earlier ~489 ms claim. A 40 s R17 run is not
  reproducible and is treated as unresolved, not as an R17 execution time.

## Evidence files

| Path | Contents |
|---|---|
| `plans/R01.txt` … `plans/W05.txt` | Raw plans for all three runs (timeout files contain the cancellation) |
| `experiments/r19_original_explain_costs.txt` | Non-executing `EXPLAIN (VERBOSE, COSTS)` of original R19 |
| `experiments/r19_original_timeout_60s.txt` | Explicit 60 s cancellation of original R19 |
| `experiments/r19_original_sample_explain.txt` | 40-doctor sample, `ANALYZE`; 9,630 ms, 40 loops |
| `experiments/r19_equivalence_seed.txt` | Full seed-scale result-set equivalence: 480/480, 0 differences |
| `experiments/r19_equivalence_large_sample.txt` | 40-doctor large-scale equivalence: 40/40, 0 differences |
| `experiments/r19_rewrite_full.txt` | Full rewrite plan (first run, 349.5 ms) |
| `experiments/r19_rewrite_runs.txt` | Three warm rewrite runs (262.2, 248.2, 242.3 ms) |
| `experiments/r17/default_runs.txt` | Three R17 runs at 40 s timeout (473.6, 446.7, 449.7 ms) |
| `experiments/r17/parallel_disabled.txt` | R17 with `max_parallel_workers_per_gather=0` (996.4 ms) |
| `experiments/r13/timeout_240s.txt` | R13 cancellation after 240 s |
| `experiments/r13/equivalence_seed.txt` | NULL-guarded diagnostic vs original: 0 rows both sides |
| `experiments/r13/rewrite_runs.txt` | NULL-guarded diagnostic timings (0.033–0.064 ms) |
| `experiments/r13/corrected_business_logic.txt` | Corrected `NOT EXISTS` business query on large: 10,668 rows, 40.7–58.5 ms |
| `experiments/r13/corrected_business_logic_seed.txt` | Corrected `NOT EXISTS` business query on seed `Practo`: 292 rows |
| `experiments/r13/README.md` | Explains original 0-row behavior, corrected 292/10,668-row results, and guarded diagnostic |

## Limitations

1. Three runs per measured query; R13/R19 timed out on the first attempt and
   were not repeated (0/3 completed). Their timeout classes are retained.
2. OS/shared-buffer cache state was not reset between queries.
3. No index was created on `appointments`; index effects at 3M rows are not
   measured here.
4. The original R19 full execution was never completed. Its ~38-minute figure
   is an **extrapolation** from the measured 40-doctor sample, not a
   measurement.
5. **R19 large-scale equivalence is not complete:** seed full-result comparison
   is 480/480, but the large comparison covers 40 of 9,600 doctors.
6. R13 original (0 rows by NULL semantics) and corrected business query
   (292 seed / 10,668 large) are **not equivalent**; they answer different
   questions, and the corrected count grows with clinic volume.
7. Timeouts are reported as timeouts, never as execution times.
8. The provenance of the previously reported 40 s R17 timeout could not be
   established because no plan or log from that run exists in the repository.
