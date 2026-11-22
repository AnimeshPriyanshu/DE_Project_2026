#!/usr/bin/env bash
# Runs every query in queries/workload_30.sql on the large dataset with a
# per-statement timeout and records an explicit status for every query:
#   MEASURED   - EXPLAIN ANALYZE completed; aggregate timings recorded
#   TIMED_OUT  - cancelled by statement_timeout; no execution time exists
#   ERROR      - query failed for another reason (message recorded)
#   INCOMPLETE - psql succeeded but no Execution Time was produced
#
# Default methodology: 3 runs per query, report avg/median/min/max.
# A query that times out or errors stops after that attempt; it is never
# reported as a measured execution time.
#
# Existing benchmark scripts and results are not touched. Output goes to
# benchmarks/results/large/ by default.
#
# Usage: ./benchmarks/run_large_benchmark.sh <database> [runs] [timeout_ms] [out_dir]
set -uo pipefail

DB="${1:?database name required}"
RUNS="${2:-3}"
TIMEOUT_MS="${3:-60000}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORKLOAD="$ROOT/queries/workload_30.sql"
OUT="${4:-$ROOT/benchmarks/results/large}"
SUMMARY="$OUT/summary.csv"
PLANS="$OUT/plans"
mkdir -p "$OUT" "$PLANS"
echo "query_id,type,status,runs_completed,runs_requested,avg_ms,median_ms,min_ms,max_ms,timeout_ms,scan_nodes,note" > "$SUMMARY"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

awk -v dir="$TMP" '
  /^-- @/ { id = ""; if ($2 ~ /^@[RW][0-9]+$/) { id = substr($2, 2); file = dir "/" id ".sql"; printf "" > file }; next }
  id != "" && !/^--/ { print >> file }
' "$WORKLOAD"

for f in $(ls "$TMP"/*.sql | sort -V); do
  id="$(basename "$f" .sql)"
  type="READ"; [[ "$id" == W* ]] && type="WRITE"
  query="$(cat "$f")"
  plan_file="$PLANS/$id.txt"
  : > "$plan_file"
  times=()
  completed=0
  status=""
  note=""

  for ((i = 1; i <= RUNS; i++)); do
    err_file="$TMP/$id.$i.err"
    in_file="$TMP/$id.$i.in"
    {
      printf "SET statement_timeout='%sms';\n" "$TIMEOUT_MS"
      printf 'SET search_path TO practo;\n'
      if [[ "$type" == "WRITE" ]]; then printf 'BEGIN;\n'; fi
      printf 'EXPLAIN (ANALYZE, BUFFERS, VERBOSE, COSTS)\n%s\n' "$query"
      if [[ "$type" == "WRITE" ]]; then printf 'ROLLBACK;\n'; fi
    } > "$in_file"

    echo "=== $id run $i ===" >> "$plan_file"
    psql -d "$DB" -X -q -A -t -v ON_ERROR_STOP=1 -f "$in_file" >> "$plan_file" 2> "$err_file"
    rc=$?

    if grep -q "statement timeout" "$err_file"; then
      status="TIMED_OUT"
      note="cancelled by statement_timeout=${TIMEOUT_MS}ms after run $i; no execution time exists"
      break
    elif [[ $rc -ne 0 ]]; then
      status="ERROR"
      note="$(tr '\n' ' ' < "$err_file" | sed 's/,/;/g' | cut -c1-300)"
      break
    fi

    t="$(grep -oE 'Execution Time: [0-9.]+' "$plan_file" | awk '{print $3}' | tail -1)"
    if [[ -z "$t" ]]; then
      status="INCOMPLETE"
      note="psql exited 0 but run $i contains no Execution Time"
      break
    fi
    times+=("$t")
    completed=$((completed + 1))
  done

  if [[ -z "$status" ]]; then
    status="MEASURED"
    note=""
  fi

  if [[ ${#times[@]} -gt 0 ]]; then
    sorted=($(printf '%s\n' "${times[@]}" | sort -g))
    avg="$(printf '%s\n' "${times[@]}" | awk '{ s += $1 } END { printf "%.3f", s / NR }')"
    median="${sorted[$((${#sorted[@]} / 2))]}"
    min="${sorted[0]}"
    max="${sorted[$((${#sorted[@]} - 1))]}"
  else
    avg=""; median=""; min=""; max=""
  fi

  node="$(grep -oE '(Parallel )?(Seq Scan|Index Scan|Index Only Scan|Bitmap Heap Scan|Bitmap Index Scan)( Backward)?( using [a-z0-9_]+)? on [a-z0-9_.]+' "$plan_file" | sed -E 's/Parallel //; s/ Backward//' | awk '!seen[$0]++' | paste -sd'|' - | sed 's/|/ | /g')"
  [[ -z "$node" ]] && node="-"

  echo "$id,$type,$status,$completed,$RUNS,$avg,$median,$min,$max,$TIMEOUT_MS,$node,$note" >> "$SUMMARY"
  printf '%-4s %-5s %-10s %s/%s runs  median %8s ms  %s\n' "$id" "$type" "$status" "$completed" "$RUNS" "${median:--}" "$node"
done

echo "Saved status-classified results to $OUT"
