# R13 variants — do not conflate these results

The original R13 query is:

```sql
SELECT c.clinic_id, c.clinic_name, c.city_id
FROM clinics c
WHERE c.clinic_id NOT IN (SELECT sc.clinic_id FROM doctor_schedules sc);
```

The large database's `doctor_schedules` contains **117,747 rows with NULL
`clinic_id`**; the seed database has 5,899. Because `NOT IN` uses three-valued
logic, the original query is defined to return **0 rows**: every non-matching
clinic evaluates to UNKNOWN. At seed scale the query completed and returned 0
rows; at large scale it timed out at 60 s and again at 240 s before producing
a result.

## 1. Original behavior (0 rows)

The original query is **not** the corrected business answer. Its zero-row
result is a NULL-semantics/data-quality bug. It has no measured large-scale
execution time because it timed out.

## 2. Corrected business logic (292 seed / 10,668 large)

```sql
SELECT c.clinic_id, c.clinic_name, c.city_id
FROM clinics c
WHERE NOT EXISTS (SELECT 1 FROM doctor_schedules sc
                  WHERE sc.clinic_id = c.clinic_id);
```

This ignores NULL schedule rows and returns the intended clinics with no
doctor schedule referencing them: **292 rows on seed `Practo`** (1,500
clinics, 30,499 schedules, 5,899 NULL schedules) and **10,668 rows on large**
(30,000 clinics, 609,747 schedules, 117,747 NULL schedules), measured in
**40.7–58.5 ms** on large across three runs. The 292 → 10,668 difference is the
correct business count on two differently sized datasets, not a contradiction.
It is **not result-equivalent to the original** (0 vs 292 seed / 10,668 large);
it answers the intended business question instead of reproducing the NULL bug.

Evidence: `corrected_business_logic.txt` (large) and
`corrected_business_logic_seed.txt` (seed).

## 3. NULL-guarded diagnostic (0 rows, fast)

```sql
SELECT c.clinic_id, c.clinic_name, c.city_id
FROM clinics c
WHERE NOT EXISTS (SELECT 1 FROM doctor_schedules sc
                  WHERE sc.clinic_id = c.clinic_id)
  AND NOT EXISTS (SELECT 1 FROM doctor_schedules sc
                  WHERE sc.clinic_id IS NULL);
```

This returns **0 rows**, matching the original's result set on current data,
and runs in **0.033–0.064 ms** because the NULL guard short-circuits. It is a
**result-equivalent diagnostic on current data**, not the corrected business
logic, and it preserves the data-quality bug. Do not use it as the business
fix.

Evidence: `equivalence_seed.txt`, `rewrite_runs.txt`.

## Recommendation

Fix the data model/source: forbid NULL `clinic_id` for clinic schedules, or
document NULL as video/no-clinic and write the report against the corrected
`NOT EXISTS` business query.
