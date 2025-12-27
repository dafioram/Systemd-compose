#!/bin/bash
set -e
source ./lib.sh

echo "--- Streaming logs for $APP_NAME ---"

# Check local log files
LOG_FILES=("$WORKING_DIR/app.log" "$WORKING_DIR/error.log")
EXISTING_LOGS=()
for f in "${LOG_FILES[@]}"; do
    [ -f "$f" ] && EXISTING_LOGS+=("$f")
done

if [ "${#EXISTING_LOGS[@]}" -eq 0 ]; then
    echo "No local log files found. Falling back to systemd journal..."
    echo "Press Ctrl+C to exit."
    journalctl --user -u "$SERVICE_NAME" -f --no-pager || true
    exit 0
fi

# Tail local log files
tail -F -n 20 "${EXISTING_LOGS[@]}"