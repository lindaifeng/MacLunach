#!/bin/zsh
set -euo pipefail

repo_root=${0:A:h:h}
output=$(mktemp -t touch-search-performance)
trap 'rm -f "$output"' EXIT

swift run \
  --package-path "$repo_root/Packages/TouchKit" \
  -c release \
  SearchBenchmark | tee "$output"

record_count=$(awk '/^SearchBenchmark records / { print $3 }' "$output")
if [[ "$record_count" != "1000000" ]]; then
  print -u2 "expected 1000000 benchmark records, got ${record_count:-none}"
  exit 1
fi

for query in design fd; do
  line=$(grep "^SearchBenchmark query=$query " "$output" || true)
  samples=$(awk '{ for (i = 1; i <= NF; i++) if ($i ~ /^samples=/) { split($i, value, "="); print value[2] } }' <<< "$line")
  p50=$(awk '{ for (i = 1; i <= NF; i++) if ($i ~ /^p50_ms=/) { split($i, value, "="); print value[2] } }' <<< "$line")
  p95=$(awk '{ for (i = 1; i <= NF; i++) if ($i ~ /^p95_ms=/) { split($i, value, "="); print value[2] } }' <<< "$line")

  if [[ "$samples" != "100" || -z "$p50" || -z "$p95" ]]; then
    print -u2 "invalid benchmark output for $query"
    exit 1
  fi

  printf '%s search P50 %s ms\n' "$query" "$p50"
  printf '%s search P95 %s ms\n' "$query" "$p95"
  awk -v p95="$p95" 'BEGIN { exit !(p95 <= 50.0) }' || {
    print -u2 "$query search P95 exceeds 50 ms: $p95 ms"
    exit 1
  }
done
