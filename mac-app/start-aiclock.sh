#!/bin/zsh
set -e

SCRIPT_DIR="${0:A:h}"
APP="${AICLOCK_APP_PATH:-${SCRIPT_DIR:h}/dist/AIClockBridge.app}"

if [[ ! -d "$APP" ]]; then
  print -u2 "AIClockBridge.app not found: $APP"
  print -u2 "Run $SCRIPT_DIR/package-macos.sh first."
  exit 1
fi

if pgrep -f "$APP/Contents/MacOS/AIClockBridge" >/dev/null 2>&1; then
  exit 0
fi

/usr/bin/open -n "$APP"
