#!/bin/bash
set -euo pipefail

############################################
# Load Settings
############################################

if [ ! -f ./app.settings ]; then
    echo "Error: app.settings not found"
    exit 1
fi

source ./app.settings

SERVICE_FILE="${APP_NAME}.service"
SERVICE_DIR="$HOME/.config/systemd/user"
SYSTEMCTL="systemctl --user"

echo "--- Stopping and Removing $APP_NAME ---"

############################################
# Stop and Disable Service
############################################

if $SYSTEMCTL is-active --quiet "$SERVICE_FILE"; then
    $SYSTEMCTL stop "$SERVICE_FILE"
    echo "Service stopped."
fi

if $SYSTEMCTL is-enabled --quiet "$SERVICE_FILE"; then
    $SYSTEMCTL disable "$SERVICE_FILE"
    echo "Service disabled."
fi

############################################
# Remove Service File
############################################

if [ -f "$SERVICE_DIR/$SERVICE_FILE" ]; then
    rm "$SERVICE_DIR/$SERVICE_FILE"
    $SYSTEMCTL daemon-reload
    echo "User systemd service removed."
else
    echo "Service file not found (already removed?)"
fi

############################################
# Optional Cleanup
############################################

echo "Cleaning up environment..."
rm -rf venv

echo "Success: $APP_NAME is DOWN and UNINSTALLED."