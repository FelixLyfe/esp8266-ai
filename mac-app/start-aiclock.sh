#!/bin/zsh
set -e

APP="/Users/jzb/Documents/esp8266-ai/mac-app/.build/AIClockBridge.app"

if pgrep -f "$APP/Contents/MacOS/AIClockBridge" >/dev/null 2>&1; then
  exit 0
fi

/usr/bin/open -n "$APP"
