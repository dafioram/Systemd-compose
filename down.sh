#!/bin/bash
set -e

if [ ! -f ./app.settings ]; then
    echo "Error: app.settings not found"
    exit 1
fi
source ./app.settings

SERVICE_NAME="${APP_NAME}.service"

if [ "$SYSTEMD_MODE" = "user" ]; then
    SYSTEMCTL="systemctl --user"
    SERVICE_DIR="$HOME/.config/systemd/user"
else
    SYSTEMCTL="sudo systemctl"
    SERVICE_DIR="/etc/systemd/system"
fi

echo "--- Shutting down $APP_NAME ---"

$SYSTEMCTL stop "$SERVICE_NAME" 2>/dev/null || true
$SYSTEMCTL disable "$SERVICE_NAME" 2>/dev/null || true

rm -f "$SERVICE_DIR/$SERVICE_NAME"
$SYSTEMCTL daemon-reload

echo "Removing local artifacts..."
rm -rf .venv app.log error.log

echo "Success: $APP_NAME removed"
