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

echo "--- Restarting $APP_NAME ---"

############################################
# Git Pull (User-Owned Repo)
############################################

if [ -d ".git" ]; then
    echo "Pulling latest changes..."
    git pull
else
    echo "Not a git repo. Skipping pull."
fi

############################################
# Reload Environment
############################################

if [ ! -f .env ]; then
    echo "Error: .env missing"
    exit 1
fi

APP_PORT=$(grep -E "^${ENV_PORT_KEY}=[0-9]+" .env | cut -d '=' -f2 || true)

if [ -z "$APP_PORT" ]; then
    echo "Error: $ENV_PORT_KEY not found in .env"
    exit 1
fi

if [ "$APP_PORT" -lt 1024 ]; then
    echo "Error: Rootless services cannot bind ports below 1024"
    exit 1
fi

############################################
# Rebuild ExecStart
############################################

WORKING_DIR=$(pwd)
VENV_PATH="$WORKING_DIR/venv/bin"

EXEC_START_FINAL=$(echo "$EXEC_CMD" | \
    sed "s|{{VENV}}|$VENV_PATH|g" | \
    sed "s|{{PORT}}|$APP_PORT|g")

############################################
# Regenerate Service File
############################################

TEMPLATE="app.service.template"
mkdir -p "$SERVICE_DIR"

sed -e "s|{{WORKING_DIR}}|$WORKING_DIR|g" \
    -e "s|{{APP_DESCRIPTION}}|$APP_DESCRIPTION|g" \
    -e "s|{{EXEC_START_FINAL}}|$EXEC_START_FINAL|g" \
    "$TEMPLATE" > "$SERVICE_DIR/$SERVICE_FILE"

############################################
# Reload and Restart
############################################

$SYSTEMCTL daemon-reload
$SYSTEMCTL restart "$SERVICE_FILE"

echo "Success: $APP_NAME restarted on port $APP_PORT"