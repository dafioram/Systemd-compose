#!/bin/bash
set -e
source ./lib.sh

echo "--- Shutting down $APP_NAME ---"

$SYSTEMCTL stop "$SERVICE_NAME" 2>/dev/null || true
$SYSTEMCTL disable "$SERVICE_NAME" 2>/dev/null || true

rm -f "$SERVICE_DIR/$SERVICE_NAME"
$SYSTEMCTL daemon-reload

echo "Cleaning up local artifacts..."
rm -rf "$VENV_DIR" app.log error.log

echo "Success: $APP_NAME removed"