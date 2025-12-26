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

echo "--- Restarting $APP_NAME ---"

# Optional git update
if [ -d .git ]; then
    echo "Pulling latest changes..."
    git pull || true
fi

# Re-run up logic (idempotent)
./up.sh

echo "Success: $APP_NAME restarted"
