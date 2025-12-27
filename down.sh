#!/bin/bash
set -e

source ./lib.sh

echo "--- Bringing down $APP_NAME ---"

if $SYSTEMCTL is-active --quiet "$SERVICE_NAME"; then
    $SYSTEMCTL stop "$SERVICE_NAME"
    echo "Service stopped"
else
    echo "Service not running"
fi

if $SYSTEMCTL is-enabled --quiet "$SERVICE_NAME"; then
    $SYSTEMCTL disable "$SERVICE_NAME"
    echo "Service disabled"
fi

SERVICE_FILE="$SERVICE_DIR/$SERVICE_NAME"

if [ -f "$SERVICE_FILE" ]; then
    rm "$SERVICE_FILE"
    $SYSTEMCTL daemon-reload
    echo "Service file removed"
else
    echo "Service file not found"
fi

echo "Success: $APP_NAME is down"
