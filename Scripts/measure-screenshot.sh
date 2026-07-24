#!/bin/zsh
set -euo pipefail

mode="${1:-fixture}"
if [[ "$mode" != "fixture" && "$mode" != "real" && "$mode" != "both" ]]; then
  print -u2 "usage: $0 [fixture|real|both]"
  exit 2
fi

app_path="${TOUCH_APP_PATH:-}"
if [[ -z "$app_path" ]]; then
  app_path=$(find "$HOME/Library/Developer/Xcode/DerivedData" -path '*/Build/Products/Release/一念.app' -print -quit)
fi
if [[ -z "$app_path" || ! -d "$app_path" ]]; then
  print -u2 "Release app not found; set TOUCH_APP_PATH"
  exit 1
fi
app_executable="$app_path/Contents/MacOS/一念"
if [[ ! -x "$app_executable" ]]; then
  print -u2 "Touch executable not found in $app_path"
  exit 1
fi
sample_timeout_seconds="${TOUCH_SCREENSHOT_SAMPLE_TIMEOUT_SECONDS:-20}"
if ! [[ "$sample_timeout_seconds" =~ '^[1-9][0-9]*$' ]]; then
  print -u2 "TOUCH_SCREENSHOT_SAMPLE_TIMEOUT_SECONDS must be a positive integer"
  exit 2
fi

run_app_with_timeout() {
  "$app_executable" "$@" &
  local app_pid=$!
  local deadline=$((SECONDS + sample_timeout_seconds))
  while kill -0 "$app_pid" 2>/dev/null; do
    if (( SECONDS >= deadline )); then
      kill -TERM "$app_pid" 2>/dev/null || true
      sleep 0.2
      kill -KILL "$app_pid" 2>/dev/null || true
      wait "$app_pid" 2>/dev/null || true
      return 124
    fi
    sleep 0.1
  done
  wait "$app_pid"
}

measure_mode() {
  local current_mode="$1"
  local results sorted fixture_root count p50 p95
  results=$(mktemp -t "touch-screenshot-${current_mode}-performance")
  sorted=$(mktemp -t "touch-screenshot-${current_mode}-sorted")
  fixture_root=$(mktemp -d -t "touch-screenshot-${current_mode}-fixture")
  : > "$results"

  for sample in {1..30}; do
    if [[ "$current_mode" == "fixture" ]]; then
      local sample_root="$fixture_root/$sample"
      mkdir -p "$sample_root"
      if ! run_app_with_timeout \
        --screenshot-thumbnail-fixture \
        "--screenshot-thumbnail-root=$sample_root" \
        "--measure-screenshot=$results"; then
        print -u2 "$current_mode screenshot sample $sample failed or exceeded ${sample_timeout_seconds}s"
        exit 1
      fi
    else
      if ! run_app_with_timeout "--measure-screenshot=$results"; then
        print -u2 "$current_mode screenshot sample $sample failed or exceeded ${sample_timeout_seconds}s"
        exit 1
      fi
    fi

    count=$(grep -Ec '^[0-9]+([.][0-9]+)?$' "$results" || true)
    if [[ "$count" -ne "$sample" ]]; then
      print -u2 "$current_mode screenshot sample $sample produced no measurement; stopping early"
      exit 1
    fi
  done

  sort -n "$results" > "$sorted"
  p50=$(sed -n '15p' "$sorted")
  p95=$(sed -n '29p' "$sorted")
  printf 'ScreenshotArtifactToThumbnailFrame (%s) P50 %s ms\n' "$current_mode" "$p50"
  printf 'ScreenshotArtifactToThumbnailFrame (%s) P95 %s ms\n' "$current_mode" "$p95"

  awk -v p95="$p95" 'BEGIN { exit !(p95 <= 300.0) }' || {
    print -u2 "$current_mode screenshot thumbnail P95 exceeds 300 ms"
    exit 1
  }
  rm -f "$results" "$sorted"
  rm -rf "$fixture_root"
}

if [[ "$mode" == "both" ]]; then
  measure_mode fixture
  measure_mode real
else
  measure_mode "$mode"
fi
