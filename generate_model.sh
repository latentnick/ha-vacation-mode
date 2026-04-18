#!/bin/bash
# After running:
#   1. Review out/schedule_events.json
#   2. Start the vacation daemon:
#        ./start_vacation_daemon.sh
#   3. To monitor progress:
#        tail -f out/vacation_daemon.log
set -e

if [ "$#" -ne 2 ]; then
    echo "Usage: $0 <vacation_start> <vacation_end>"
    echo "Example: $0 2026-04-01 2026-04-08"
    exit 1
fi

uv run fetch_ha_data.py
uv run generate_resample.py "$1" "$2"
