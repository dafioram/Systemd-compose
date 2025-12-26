#!/bin/bash
set -e

# --- Load settings ---
if [ ! -f ./app.settings ]; then
    echo "Error: app.settings not found"
    exit 1
fi
source ./app.settings

echo "--- Bringing up $APP_NAME ---"

# --- Determine systemd mode ---
if [ "$SYSTEMD_MODE" = "user" ]; then
    SYSTEMCTL="systemctl --user"
    SERVICE_DIR="$HOME/.config/systemd/user"
    TARGET="default.target"
else
    SYSTEMCTL="sudo systemctl"
    SERVICE_DIR="/etc/systemd/system"
    TARGET="multi-user.target"
fi

mkdir -p "$SERVICE_DIR"

# --- Ensure Python ---
command -v python3 >/dev/null || {
    echo "Error: python3 not installed"
    exit 1
}

# --- Virtualenv ---
VENV_DIR="${VENV_DIR:-.venv}"
if [ ! -d "$VENV_DIR" ]; then
    echo "Creating virtualenv..."
    python3 -m venv "$VENV_DIR"
    "$VENV_DIR/bin/pip" install --upgrade pip
fi

if [ -f requirements.txt ]; then
    echo "Installing dependencies..."
    "$VENV_DIR/bin/pip" install -r requirements.txt
fi

# --- Build ExecStart ---
WORKING_DIR="$(pwd)"
EXEC_START_FINAL=$(echo "$EXEC_CMD" | sed "s|{{VENV}}|$WORKING_DIR/$VENV_DIR/bin|g")

# --- Generate service ---
SERVICE_FILE="$SERVICE_DIR/$APP_NAME.service"

sed \
    -e "s|{{APP_DESCRIPTION}}|$APP_DESCRIPTION|g" \
    -e "s|{{WORKING_DIR}}|$WORKING_DIR|g" \
    -e "s|{{EXEC_START_FINAL}}|$EXEC_START_FINAL|g" \
    -e "s|WantedBy=.*|WantedBy=$TARGET|g" \
    app.service.template > "$SERVICE_FILE"

# --- Reload and start ---
$SYSTEMCTL daemon-reload
$SYSTEMCTL enable "$SERVICE_NAME"
$SYSTEMCTL restart "$SERVICE_NAME"

echo "Success: $APP_NAME started"
