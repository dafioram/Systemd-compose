#!/bin/bash
set -euo pipefail

if [ ! -f ./app.settings ]; then
    echo "Error: app.settings not found"
    exit 1
fi

source ./app.settings

SERVICE_FILE="${APP_NAME}.service"

echo "--- Streaming logs for $APP_NAME (Ctrl+C to exit) ---"

journalctl --user -u "$SERVICE_FILE" -f
