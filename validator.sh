#!/bin/bash

echo "--- Validating project ---"

fail=false

[ -f app.settings ] || { echo "Missing app.settings"; fail=true; }
[ -f app.service.template ] || { echo "Missing service template"; fail=true; }

if grep -q '{{PORT}}' app.settings; then
    echo "ERROR: EXEC_CMD still contains {{PORT}}"
    fail=true
fi

if [ -f .env ]; then
    if grep -q '^PORT=' .env && ! grep '^PORT=[0-9]\+$' .env; then
        echo "ERROR: PORT is not numeric"
        fail=true
    fi
fi

if systemctl --user >/dev/null 2>&1; then
    echo "systemd user mode available"
else
    echo "WARNING: systemd user mode unavailable"
fi

$fail && exit 1 || echo "Validation OK"
