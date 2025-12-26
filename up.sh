#!/bin/bash
set -euo pipefail

############################################
# 1. Load Settings
############################################

if [ ! -f ./app.settings ]; then
    echo "Error: app.settings not found"
    exit 1
fi

source ./app.settings

REQUIRED_VARS=(APP_NAME APP_DESCRIPTION EXEC_CMD ENV_PORT_KEY)
for var in "${REQUIRED_VARS[@]}"; do
    if [ -z "${!var:-}" ]; then
        echo "Error: $var is not set in app.settings"
        exit 1
    fi
done

############################################
# 2. Rootless Preconditions
############################################

if ! command -v systemctl >/dev/null; then
    echo "Error: systemctl not available"
    exit 1
fi

if ! command -v python3 >/dev/null; then
    echo "Error: python3 not installed"
    exit 1
fi

# Lingering check (rootless)
if ! loginctl show-user "$USER" -p Linger | grep -q yes; then
    echo "Error: systemd user lingering is disabled for $USER"
    echo
    echo "Run once (requires admin):"
    echo "  sudo ./enable-linger.sh"
    exit 1
fi

############################################
# 3. Load Environment / Port
############################################

if [ ! -f .env ]; then
    echo "Error: .env file missing"
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
# 4. Virtual Environment
############################################

if [ ! -d venv ]; then
    echo "Creating virtual environment..."
    python3 -m venv venv
    ./venv/bin/pip install --upgrade pip
fi

if [ -f requirements.txt ]; then
    echo "Installing requirements..."
    ./venv/bin/pip install -r requirements.txt
fi

############################################
# 5. Build ExecStart
############################################

WORKING_DIR=$(pwd)
VENV_PATH="$WORKING_DIR/venv/bin"

EXEC_START_FINAL=$(echo "$EXEC_CMD" | \
    sed "s|{{VENV}}|$VENV_PATH|g" | \
    sed "s|{{PORT}}|$APP_PORT|g")

############################################
# 6. Generate User Service
############################################

SERVICE_DIR="$HOME/.config/systemd/user"
SERVICE_FILE="${APP_NAME}.service"
TEMPLATE="app.service.template"

mkdir -p "$SERVICE_DIR"

sed -e "s|{{WORKING_DIR}}|$WORKING_DIR|g" \
    -e "s|{{APP_DESCRIPTION}}|$APP_DESCRIPTION|g" \
    -e "s|{{EXEC_START_FINAL}}|$EXEC_START_FINAL|g" \
    "$TEMPLATE" > "$SERVICE_DIR/$SERVICE_FILE"

############################################
# 7. Enable & Start (Rootless)
############################################

SYSTEMCTL="systemctl --user"

$SYSTEMCTL daemon-reload
$SYSTEMCTL enable "$SERVICE_FILE"
$SYSTEMCTL restart "$SERVICE_FILE"

echo "------------------------------------------------"
echo "Success: $APP_NAME running on port $APP_PORT"
echo "Logs: journalctl --user -u $SERVICE_FILE -f"
echo "------------------------------------------------"
