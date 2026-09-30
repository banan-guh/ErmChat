#!/usr/bin/env bash
# Builds the probe APK, installs it, relaunches, settles, then samples.
# Usage: [FAKE=msgs/sec] tool/perf_ab.sh <label> [seconds=30] [settle=20]
set -euo pipefail
cd "$(dirname "$0")/.."
LABEL=$1; SECS=${2:-30}; SETTLE=${3:-20}
flutter build apk --profile --dart-define=ERMCHAT_PERF=true \
  --dart-define=ERMCHAT_FAKE_CHAT=${FAKE:-0} \
  --target-platform android-arm64 >/dev/null
adb install -r build/app/outputs/flutter-apk/app-profile.apk >/dev/null
adb shell am force-stop io.github.bananguh.ErmChat
adb shell monkey -p io.github.bananguh.ErmChat \
  -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1
sleep "$SETTLE"
tool/perf_run.sh "$SECS" "$LABEL"
