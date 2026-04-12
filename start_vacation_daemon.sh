#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

nohup uv run vacation_daemon.py out/schedule_events.json > out/vacation_daemon.log 2>&1 &
echo "Vacation daemon started (PID $!). Logs: out/vacation_daemon.log"
