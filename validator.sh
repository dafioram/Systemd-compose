#!/bin/bash
set -euo pipefail

FAIL=0

check() {
    if ! eval "$1"; then
        echo "[FAIL] $2"
        FAIL=1
    else
        echo "[ OK ] $2"
    fi
}

echo "Running validator..."

check "command -v python3 >/dev/null" "python3 installed"
check "command -v systemctl >/dev/null" "systemctl available"
check "[ -f app.settings ]" "app.settings exists"
check "[ -f .env ]" ".env exists"

if loginctl show-user "$USER" -p Linger | grep -q yes; then
    echo "[ OK ] systemd user lingering enabled"
else
    echo "[FAIL] systemd user lingering disabled"
    echo "       Fix: sudo ./enable-linger.sh"
    FAIL=1
fi

if [ -f .env ] && [ -f app.settings ]; then
    source app.settings
    PORT=$(grep -E "^${ENV_PORT_KEY}=[0-9]+" .env | cut -d= -f2 || true)

    if [ -n "$PORT" ] && [ "$PORT" -ge 1024 ]; then
        echo "[ OK ] application port ($PORT) valid for rootless"
    else
        echo "[FAIL] application port invalid or privileged"
        FAIL=1
    fi
fi

if [ "$FAIL" -eq 1 ]; then
    echo
    echo "Validator FAILED"
    exit 1
else
    echo
    echo "Validator PASSED"
fi
