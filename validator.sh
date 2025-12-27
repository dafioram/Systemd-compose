#!/bin/bash
set -e

echo "--- Validating system for app deployment ---"

fail=0

check() {
    "$@" >/dev/null 2>&1 || fail=1
}

command -v python3 >/dev/null || {
    echo "Missing: python3"
    echo "Install: sudo apt install python3"
    fail=1
}

python3 - <<'EOF' >/dev/null 2>&1 || {
import venv
EOF
    echo "Missing: python3-venv"
    echo "Install: sudo apt install python3-venv"
    fail=1
}

command -v systemctl >/dev/null || {
    echo "Missing: systemd"
    fail=1
}

if [ "$fail" -eq 1 ]; then
    echo "Validation failed"
    exit 1
fi

echo "System validation OK"
