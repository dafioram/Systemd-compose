#!/bin/bash

# 1. Load Settings & Root Check
if [ ! -f ./app.settings ]; then echo "Error: app.settings not found"; exit 1; fi
source ./app.settings

if [ "$EUID" -ne 0 ]; then echo "Error: Run with sudo"; exit 1; fi

SERVICE_FILE="${APP_NAME}.service"

# 2. Check Service State
if ! systemctl is-active --quiet "$SERVICE_FILE"; then
    echo "--- $APP_NAME Status ---"
    echo "Status: DOWN (Inactive)"
    exit 0
fi

echo "--- $APP_NAME Status ---"
echo "Status: ACTIVE"

# 3. Uptime
UPTIME=$(systemctl status "$SERVICE_FILE" | grep "Active:" | sed 's/.*since //')
echo "Uptime: Started $UPTIME"

# 4. Get PID and Stats
PID=$(systemctl show -p MainPID --value "$SERVICE_FILE")

if [ "$PID" != "0" ] && [ ! -z "$PID" ]; then
    # RAM Usage
    RAM=$(ps -p $PID -o rss= | awk '{printf "%.2f MB\n", $1/1024}')
    echo "Memory: $RAM"
    echo "PID:    $PID"

    # 5. Generic Port Detection via PID
    # We ask ss to show listening ports strictly for this PID
    PORT_CHECK=$(ss -lntp | grep ",pid=$PID," | grep -oP '(?<=:)\d+(?=\s)' | head -n 1)
    echo "Port:   ${PORT_CHECK:-Unknown}"
    
    # 6. Configuration Audit
    if [ -f .env ]; then
        ENV_PORT=$(grep -E "^${ENV_PORT_KEY}=[0-9]+" .env | cut -d '=' -f2)
        if [ "$ENV_PORT" != "$PORT_CHECK" ] && [ ! -z "$PORT_CHECK" ]; then
            echo "WARNING: .env says $ENV_PORT, but app is bound to $PORT_CHECK"
        fi
    fi
fi