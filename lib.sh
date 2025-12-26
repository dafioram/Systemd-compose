#!/bin/bash
set -e

# -----------------------------
# Load app settings
# -----------------------------

if [ ! -f ./app.settings ]; then
    echo "Error: app.settings not found"
    exit 1
fi

source ./app.settings

# -----------------------------
# Defaults
# -----------------------------

SYSTEMD_MODE="${SYSTEMD_MODE:-user}"
VENV_DIR="${VENV_DIR:-.venv}"
SERVICE_NAME="${APP_NAME}.service"
WORKING_DIR="$(pwd)"

# -----------------------------
# systemd mode resolution
# -----------------------------

if [ "$SYSTEMD_MODE" = "user" ]; then
    SYSTEMCTL="systemctl --user"
    SERVICE_DIR="$HOME/.config/systemd/user"
    SYSTEMD_TARGET="default.target"
else
    SYSTEMCTL="sudo systemctl"
    SERVICE_DIR="/etc/systemd/system"
    SYSTEMD_TARGET="multi-user.target"
fi

# -----------------------------
# Helpers
# -----------------------------

require_cmd() {
    command -v "$1" >/dev/null || {
        echo "Error: required command '$1' not found"
        exit 1
    }
}

service_exists() {
    [ -f "$SERVICE_DIR/$SERVICE_NAME" ]
}

ensure_service_dir() {
    mkdir -p "$SERVICE_DIR"
}

build_exec_start() {
    echo "$EXEC_CMD" | sed "s|{{VENV}}|$WORKING_DIR/$VENV_DIR/bin|g"
}
