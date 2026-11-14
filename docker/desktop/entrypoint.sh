#!/bin/sh
# Starts the display and window manager, then waits until the container is stopped.
set -e
Xvfb "$DISPLAY" -screen 0 "$SCREEN" -nolisten tcp &
for _ in $(seq 1 50); do
  xdpyinfo >/dev/null 2>&1 && break
  sleep 0.1
done
fluxbox >/dev/null 2>&1 &
trap 'exit 0' TERM INT
while :; do sleep 3600 & wait $!; done
