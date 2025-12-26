#!/bin/bash
set -euo pipefail

if [ ! -f ./app.settings ]; then
    echo "Error: app.settings not found"
    exit 1
fi

source ./app.settings

SERVICE_FILE="${APP_NAME}.service"
SYSTEMCTL="systemctl --user"

echo "--- $APP_NAME Status ---"

if ! $SYSTEMCTL is-active --quiet "$SERVICE_FILE"; then
    echo "Status: DOWN (Inactive)"
    exit 0
fi

echo "Status: ACTIVE"

############################################
# Uptime
############################################

START_TIME=$($SYSTEMCTL show -p ActiveEnterTimestamp --value "$SERVICE_FILE")
echo "Uptime: Started $START_TIME"

############################################
# PID and Stats
############################################

PID=$($SYSTEMCTL show -p MainPID --value "$SERVICE_FILE")

if [ "$PID" != "0" ] && [ -n "$PID" ]; then
    RAM=$(ps -p "$PID" -o rss= | awk '{printf "%.2f MB\n", $1/1024}')
    echo "PID:    $PID"
    echo "Memory: $RAM"

    PORT_CHECK=$(ss -lntp 2>/dev/null | grep ",pid=$PID," | grep -oE ':[0-9]+' | cut -d: -f2 | head -n1)
    echo "Port:   ${PORT_CHECK:-Unknown}"

    if [ -f .env ]; then
        ENV_PORT=$(grep -E "^${ENV_PORT_KEY}=[0-9]+" .env | cut -d '=' -f2 || true)
        if [ -n "$PORT_CHECK" ] && [ "$ENV_PORT" != "$PORT_CHECK" ]; then
            echo "WARNING: .env says $ENV_PORT, but app is bound to $PORT_CHECK"
        fi
    fi
fi