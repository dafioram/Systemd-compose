#!/bin/bash
set -e

source ./lib.sh

echo "--- $APP_NAME Status ---"

if ! $SYSTEMCTL is-active --quiet "$SERVICE_NAME"; then
    echo "Status: DOWN"
    exit 0
fi

echo "Status: ACTIVE"

PID="$($SYSTEMCTL show -p MainPID --value "$SERVICE_NAME")"
echo "PID:    $PID"

if [ -z "$PID" ] || [ "$PID" = "0" ]; then
    echo "Process not fully started yet"
    exit 0
fi

# -----------------------------
# Memory usage
# -----------------------------

if ps -p "$PID" >/dev/null 2>&1; then
    RAM=$(ps -p "$PID" -o rss= | awk '{printf "%.2f MB", $1/1024}')
    echo "Memory: $RAM"
fi

# -----------------------------
# Port detection
# -----------------------------

PORT=$(ss -lntp 2>/dev/null \
    | grep "pid=$PID" \
    | grep -oP '(?<=:)\d+' \
    | head -n1)

echo "Port:   ${PORT:-Unknown}"

# -----------------------------
# Configuration audit
# -----------------------------

if [ -f .env ]; then
    ENV_PORT=$(grep -E "^${ENV_PORT_KEY}=" .env | cut -d= -f2)
    if [ -n "$ENV_PORT" ] && [ -n "$PORT" ] && [ "$ENV_PORT" != "$PORT" ]; then
        echo "Warning: .env ${ENV_PORT_KEY}=$ENV_PORT but process bound to $PORT"
    fi
fi
