#!/usr/bin/env bash
set -euo pipefail

APP_PATH_DEFAULT="/Applications/TilePilot.app/Contents/MacOS/TilePilot"
PID=""
INTERVAL_SECONDS="2"
SAMPLE_COUNT="30"
CPU_THRESHOLD="25"
RSS_THRESHOLD_MB="350"
FOOTPRINT_THRESHOLD_MB="450"
FOOTPRINT_GROWTH_THRESHOLD_MB="120"
CONSECUTIVE_CPU_LIMIT="3"

usage() {
  cat <<'EOF'
Usage: scripts/watch_tilepilot_usage.sh [options]

Short-run watchdog for TilePilot CPU and memory regression checks.

Defaults:
  interval:                 2s
  samples:                  30
  sustained CPU threshold:  25%
  RSS threshold:            350 MB
  physical footprint:       450 MB
  allowed footprint growth: 120 MB

Options:
  --pid PID                     Watch a specific process id.
  --interval SECONDS            Seconds between samples.
  --samples COUNT               Number of samples to collect.
  --cpu-threshold PERCENT       Fail if CPU stays above this threshold.
  --rss-threshold-mb MB         Fail if RSS exceeds this threshold.
  --footprint-threshold-mb MB   Fail if physical footprint exceeds this threshold.
  --growth-threshold-mb MB      Fail if footprint grows by more than this amount.
  --cpu-consecutive COUNT       Consecutive high-CPU samples needed to fail.
  --help                        Show this help.

Examples:
  scripts/watch_tilepilot_usage.sh
  scripts/watch_tilepilot_usage.sh --interval 1 --samples 20
  scripts/watch_tilepilot_usage.sh --pid 12345 --footprint-threshold-mb 300
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --pid)
      shift
      PID="${1:-}"
      ;;
    --interval)
      shift
      INTERVAL_SECONDS="${1:-}"
      ;;
    --samples)
      shift
      SAMPLE_COUNT="${1:-}"
      ;;
    --cpu-threshold)
      shift
      CPU_THRESHOLD="${1:-}"
      ;;
    --rss-threshold-mb)
      shift
      RSS_THRESHOLD_MB="${1:-}"
      ;;
    --footprint-threshold-mb)
      shift
      FOOTPRINT_THRESHOLD_MB="${1:-}"
      ;;
    --growth-threshold-mb)
      shift
      FOOTPRINT_GROWTH_THRESHOLD_MB="${1:-}"
      ;;
    --cpu-consecutive)
      shift
      CONSECUTIVE_CPU_LIMIT="${1:-}"
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
  shift
done

if [[ -z "$PID" ]]; then
  PID="$(pgrep -f "$APP_PATH_DEFAULT" | head -n 1 || true)"
fi

if [[ -z "$PID" ]]; then
  echo "TilePilot is not running." >&2
  exit 2
fi

if ! [[ "$INTERVAL_SECONDS" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
  echo "--interval must be numeric" >&2
  exit 1
fi

for value_name in SAMPLE_COUNT RSS_THRESHOLD_MB FOOTPRINT_THRESHOLD_MB FOOTPRINT_GROWTH_THRESHOLD_MB CONSECUTIVE_CPU_LIMIT; do
  value="${!value_name}"
  if ! [[ "$value" =~ ^[0-9]+$ ]]; then
    echo "--${value_name,,} must be an integer" >&2
    exit 1
  fi
done

if ! [[ "$CPU_THRESHOLD" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
  echo "--cpu-threshold must be numeric" >&2
  exit 1
fi

to_mb() {
  local raw="$1"
  raw="${raw// /}"
  python3 - "$raw" <<'PY'
import sys
raw = sys.argv[1].strip().upper()
if not raw:
    print("0")
    raise SystemExit(0)
mult = 1.0
if raw.endswith("K"):
    mult = 1 / 1024
    raw = raw[:-1]
elif raw.endswith("M"):
    mult = 1.0
    raw = raw[:-1]
elif raw.endswith("G"):
    mult = 1024.0
    raw = raw[:-1]
elif raw.endswith("T"):
    mult = 1024.0 * 1024.0
    raw = raw[:-1]
print(int(round(float(raw) * mult)))
PY
}

read_sample() {
  local ps_output cpu rss_kb footprint_raw footprint_mb
  ps_output="$(ps -p "$PID" -o %cpu= -o rss= | tr -s ' ' | sed 's/^ //')"
  cpu="$(awk '{print $1}' <<<"$ps_output")"
  rss_kb="$(awk '{print $2}' <<<"$ps_output")"
  footprint_raw="$(
    vmmap -summary "$PID" 2>/dev/null \
      | awk -F':' '/Physical footprint:/ {gsub(/^[[:space:]]+/, "", $2); print $2; exit}'
  )"
  footprint_mb="$(to_mb "${footprint_raw:-0}")"
  printf '%s\t%s\t%s\t%s\n' "$cpu" "$rss_kb" "$footprint_raw" "$footprint_mb"
}

rss_mb_from_kb() {
  local kb="$1"
  awk -v kb="$kb" 'BEGIN { printf("%d", (kb / 1024) + 0.5) }'
}

echo "Watching TilePilot PID $PID"
printf "sample\tcpu%%\trss_mb\tfootprint_mb\tresult\n"

first_footprint_mb=""
peak_cpu="0"
peak_rss_mb="0"
peak_footprint_mb="0"
consecutive_high_cpu="0"
failure_reason=""

for ((i = 1; i <= SAMPLE_COUNT; i++)); do
  if ! kill -0 "$PID" 2>/dev/null; then
    echo "$i\t-\t-\t-\tprocess-exited"
    exit 3
  fi

  IFS=$'\t' read -r cpu rss_kb footprint_raw footprint_mb < <(read_sample)
  rss_mb="$(rss_mb_from_kb "$rss_kb")"

  if [[ -z "$first_footprint_mb" ]]; then
    first_footprint_mb="$footprint_mb"
  fi

  peak_cpu="$(awk -v a="$peak_cpu" -v b="$cpu" 'BEGIN { print (a > b ? a : b) }')"
  peak_rss_mb=$(( rss_mb > peak_rss_mb ? rss_mb : peak_rss_mb ))
  peak_footprint_mb=$(( footprint_mb > peak_footprint_mb ? footprint_mb : peak_footprint_mb ))

  result="ok"

  if awk -v cpu="$cpu" -v threshold="$CPU_THRESHOLD" 'BEGIN { exit !(cpu > threshold) }'; then
    consecutive_high_cpu=$((consecutive_high_cpu + 1))
  else
    consecutive_high_cpu=0
  fi

  if (( consecutive_high_cpu >= CONSECUTIVE_CPU_LIMIT )); then
    failure_reason="CPU stayed above ${CPU_THRESHOLD}% for ${consecutive_high_cpu} consecutive samples"
    result="high-cpu"
  fi

  if (( rss_mb > RSS_THRESHOLD_MB )) && [[ -z "$failure_reason" ]]; then
    failure_reason="RSS exceeded ${RSS_THRESHOLD_MB} MB"
    result="high-rss"
  fi

  if (( footprint_mb > FOOTPRINT_THRESHOLD_MB )) && [[ -z "$failure_reason" ]]; then
    failure_reason="Physical footprint exceeded ${FOOTPRINT_THRESHOLD_MB} MB"
    result="high-footprint"
  fi

  if (( footprint_mb - first_footprint_mb > FOOTPRINT_GROWTH_THRESHOLD_MB )) && [[ -z "$failure_reason" ]]; then
    failure_reason="Physical footprint grew by more than ${FOOTPRINT_GROWTH_THRESHOLD_MB} MB"
    result="growing-footprint"
  fi

  printf "%d\t%s\t%s\t%s\t%s\n" "$i" "$cpu" "$rss_mb" "$footprint_mb" "$result"

  if [[ -n "$failure_reason" ]]; then
    break
  fi

  if (( i < SAMPLE_COUNT )); then
    sleep "$INTERVAL_SECONDS"
  fi
done

echo
echo "Peak CPU: ${peak_cpu}%"
echo "Peak RSS: ${peak_rss_mb} MB"
echo "Peak physical footprint: ${peak_footprint_mb} MB"
echo "Footprint growth: $((peak_footprint_mb - first_footprint_mb)) MB"

if [[ -n "$failure_reason" ]]; then
  echo "FAIL: $failure_reason" >&2
  exit 1
fi

echo "PASS: no runaway threshold crossed."
