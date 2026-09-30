#!/usr/bin/env bash
# CPU per thread and [perf] probe lines for the running app over a window.
# Usage: tool/perf_run.sh [seconds=60] [label]
# Needs a build with --dart-define=ERMCHAT_PERF=true for the probe lines.
set -euo pipefail
PKG=io.github.bananguh.ErmChat
SECS=${1:-60}
LABEL=${2:-run}
PID=$(adb shell pidof "$PKG" | tr -d '\r')
[ -z "$PID" ] && { echo "app not running" >&2; exit 1; }

# tid comm utime+stime (ticks), one line per thread.
snap() {
  adb shell "for t in /proc/$PID/task/*; do
    s=\$(cat \$t/stat 2>/dev/null) || continue
    c=\$(cat \$t/comm 2>/dev/null)
    set -- \${s##*) }
    echo \"\${t##*/} \$c \$((\${12} + \${13}))\"
  done" | tr -d '\r'
}

A=$(mktemp); B=$(mktemp)
snap >"$A"
adb logcat -c
sleep "$SECS"
snap >"$B"
PERF=$(adb logcat -d -s flutter | grep '\[perf\]' || true)

echo "== $LABEL: ${SECS}s, pid $PID =="
# Ticks are 10ms. Group threads by name so worker pools sum together.
join <(sort "$A") <(sort "$B") | awk '{d=$5-$3; if (d>0) {n=$2; gsub(/[0-9]+$/,"",n); t[n]+=d; tot+=d}}
  END {for (k in t) printf "%-18s %7.2fs\n", k, t[k]/100; printf "%-18s %7.2fs  (%.1f%% of one core)\n", "TOTAL", tot/100, tot/'"$SECS"'}' \
  | sort -k2 -rn
echo "$PERF" | sed 's/^.*\[perf\]/[perf]/'
rm -f "$A" "$B"
