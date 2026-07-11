#!/bin/zsh
set -euo pipefail

app_path="${TOUCH_APP_PATH:-}"
if [[ -z "$app_path" ]]; then
  app_path=$(find "$HOME/Library/Developer/Xcode/DerivedData" -path '*/Build/Products/Release/触达.app' -print -quit)
fi

if [[ -z "$app_path" || ! -d "$app_path" ]]; then
  print -u2 "Release app not found; set TOUCH_APP_PATH"
  exit 1
fi

results=$(mktemp -t touch-launcher-performance)
sorted=$(mktemp -t touch-launcher-sorted)
trap 'rm -f "$results" "$sorted"' EXIT

open -W -n "$app_path" --args "--measure-launcher=$results"

count=$(wc -l < "$results" | tr -d ' ')
if [[ "$count" -ne 30 ]]; then
  print -u2 "expected 30 samples, got $count"
  exit 1
fi

sort -n "$results" > "$sorted"
p50=$(sed -n '15p' "$sorted")
p95=$(sed -n '29p' "$sorted")
printf 'LauncherToggleToVisible P50 %s ms\n' "$p50"
printf 'LauncherToggleToVisible P95 %s ms\n' "$p95"

awk -v p95="$p95" 'BEGIN { exit !(p95 <= 120.0) }' || {
  print -u2 "LauncherToggleToVisible P95 exceeds 120 ms"
  exit 1
}
