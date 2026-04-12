#!/bin/bash
# After running:
#   1. View the output notebook:
#        uv run jupyter lab out/lights_executed.ipynb
#   2. Start the vacation daemon:
#        HA_URL=http://homeassistant.local:8123 HA_TOKEN=<token> nohup uv run vacation_daemon.py out/schedule_events.json > out/vacation_daemon.log 2>&1 &
#   3. To monitor progress:
#        tail -f out/vacation_daemon.log
set -e

if [ "$#" -ne 2 ]; then
    echo "Usage: $0 <vacation_start> <vacation_end>"
    echo "Example: $0 2026-04-01 2026-04-08"
    exit 1
fi

uv run fetch_ha_data.py

uv run papermill lights.ipynb out/lights_executed.ipynb \
    --kernel lights \
    -p VACATION_START "$1" \
    -p VACATION_END "$2"
