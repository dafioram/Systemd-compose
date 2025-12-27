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
    if [ "$EUID" -ne 0 ]; then
        echo "Error: system mode requires root"
        exit 1
    fi
    SYSTEMCTL="systemctl"
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

require_python_deps() {
    require_cmd python3

    # Verify python3-venv is installed (Debian-specific reality)
    python3 - <<'EOF' >/dev/null 2>&1 || {
import venv
EOF
        echo "Error: python3-venv not installed"
        echo "Install with: sudo apt install python3-venv"
        exit 1
    }
}

ensure_service_dir() {
    mkdir -p "$SERVICE_DIR"
}

check_linger() {
    if [ "$SYSTEMD_MODE" = "user" ]; then
        if ! loginctl show-user "$USER" -p Linger 2>/dev/null | grep -q yes; then
            echo "Warning: systemd linger is NOT enabled for $USER"
            echo "Services will stop on logout"
            echo "Enable with: sudo loginctl enable-linger $USER"
        fi
    fi
}

ensure_venv() {
    if [ ! -d "$VENV_DIR" ]; then
        echo "Creating virtual environment..."
        python3 -m venv "$VENV_DIR"
    fi

    if ! "$VENV_DIR/bin/python" -m pip --version >/dev/null 2>&1; then
        echo "Bootstrapping pip inside venv (Debian)..."
        "$VENV_DIR/bin/python" -m ensurepip --upgrade
    fi
}

get_env_port() {
    if [ ! -f .env ]; then
        echo "Error: .env file missing"
        exit 1
    fi

    local port
    port=$(grep -E "^${ENV_PORT_KEY}=" .env | cut -d= -f2)

    if [ -z "$port" ]; then
        echo "Error: $ENV_PORT_KEY not found in .env"
        exit 1
    fi

    echo "$port"
}

build_exec_start() {
    local port
    port="$(get_env_port)"

    echo "$EXEC_CMD" \
        | sed "s|{{VENV}}|$WORKING_DIR/$VENV_DIR/bin|g" \
        | sed "s|{{PORT}}|$port|g"
}