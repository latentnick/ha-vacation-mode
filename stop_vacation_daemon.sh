#!/usr/bin/env bash
set -euo pipefail

pid=$(pgrep -f 'vacation_daemon\.py' || true)

if [ -z "$pid" ]; then
    echo "Vacation daemon is not running."
    exit 0
fi

kill "$pid"
echo "Vacation daemon stopped (PID $pid)."
