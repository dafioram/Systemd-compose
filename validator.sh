#!/bin/bash
source ./lib.sh

echo "--- Validating project ---"
fail=false

[ -f app.service.template ] || { echo "Missing app.service.template"; fail=true; }

if grep -q '{{PORT}}' app.settings; then
    echo "ERROR: EXEC_CMD contains {{PORT}}"
    fail=true
fi

if [ -f .env ]; then
    if grep -q '^PORT=' .env && ! grep -q '^PORT=[0-9]\+$' .env; then
        echo "ERROR: PORT must be numeric"
        fail=true
    fi
fi

if [ "$SYSTEMD_MODE" = "user" ]; then
    systemctl --user >/dev/null 2>&1 || echo "WARNING: systemd user mode unavailable"
fi

$fail && exit 1 || echo "Validation OK"
