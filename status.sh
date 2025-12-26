#!/bin/bash

if [ ! -f ./app.settings ]; then
    echo "Error: app.settings not found"
    exit 1
fi
source ./app.settings

SERVICE_NAME="${APP_NAME}.service"

if [ "$SYSTEMD_MODE" = "user" ]; then
    SYSTEMCTL="systemctl --user"
else
    SYSTEMCTL="systemctl"
fi

echo "--- $APP_NAME Status ---"

if ! $SYSTEMCTL is-active --quiet "$SERVICE_NAME"; then
    echo "Status: DOWN"
    exit 0
fi

echo "Status: ACTIVE"

PID=$($SYSTEMCTL show -p MainPID --value "$SERVICE_NAME")
echo "PID: $PID"

if [ "$PID" != "0" ]; then
    RAM=$(ps -p "$PID" -o rss= | awk '{printf "%.2f MB\n", $1/1024}')
    echo "Memory: $RAM"

    PORT=$(ss -lntp 2>/dev/null | grep "pid=$PID" | grep -oP '(?<=:)\d+' | head -n1)
    echo "Port: ${PORT:-Unknown}"

    if [ -f .env ]; then
        ENV_PORT=$(grep '^PORT=' .env | cut -d= -f2)
        if [ -n "$ENV_PORT" ] && [ "$PORT" != "$ENV_PORT" ]; then
            echo "Warning: .env PORT=$ENV_PORT but process bound to $PORT"
        fi
    fi
fi
