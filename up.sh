#!/bin/bash
set -e

source ./lib.sh

echo "--- Bringing up $APP_NAME ---"

require_python_deps
check_linger
ensure_service_dir

# -----------------------------
# Virtualenv
# -----------------------------

ensure_venv

if [ -f requirements.txt ]; then
    echo "Installing dependencies..."
    "$VENV_DIR/bin/python" -m pip install -r requirements.txt
fi

# -----------------------------
# Generate service file
# -----------------------------

EXEC_START_FINAL="$(build_exec_start)"
SERVICE_FILE="$SERVICE_DIR/$SERVICE_NAME"

sed \
    -e "s|{{APP_DESCRIPTION}}|$APP_DESCRIPTION|g" \
    -e "s|{{WORKING_DIR}}|$WORKING_DIR|g" \
    -e "s|{{EXEC_START_FINAL}}|$EXEC_START_FINAL|g" \
    -e "s|WantedBy=.*|WantedBy=$SYSTEMD_TARGET|g" \
    app.service.template > "$SERVICE_FILE"

# -----------------------------
# Start service
# -----------------------------

$SYSTEMCTL daemon-reload
$SYSTEMCTL enable "$SERVICE_NAME"
$SYSTEMCTL restart "$SERVICE_NAME"

echo "Success: $APP_NAME started"