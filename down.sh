#!/bin/bash

# 1. Load Settings & Root Check
if [ ! -f ./app.settings ]; then echo "Error: app.settings not found"; exit 1; fi
source ./app.settings

if [ "$EUID" -ne 0 ]; then echo "Error: Run with sudo"; exit 1; fi

SERVICE_FILE="${APP_NAME}.service"

echo "--- Stopping and Removing $APP_NAME ---"

# 2. Stop and Disable Service
if systemctl is-active --quiet "$SERVICE_FILE"; then
    systemctl stop "$SERVICE_FILE"
    echo "Service stopped."
fi

if systemctl is-enabled --quiet "$SERVICE_FILE"; then
    systemctl disable "$SERVICE_FILE"
    echo "Service disabled."
fi

# 3. Remove Service File
if [ -f "/etc/systemd/system/$SERVICE_FILE" ]; then
    rm "/etc/systemd/system/$SERVICE_FILE"
    systemctl daemon-reload
    echo "Systemd registration removed."
else
    echo "Service file not found (already removed?)"
fi

# 4. Cleanup (Optional: Comment out if you want to keep venv/logs)
echo "Cleaning up environment..."
rm -rf venv
rm -f app.log error.log

echo "Success: $APP_NAME is currently DOWN and UNINSTALLED."