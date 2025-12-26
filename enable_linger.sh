#!/bin/bash
set -e

if [ "$EUID" -ne 0 ]; then
    echo "Error: This script must be run with sudo"
    exit 1
fi

TARGET_USER="${SUDO_USER:-}"

if [ -z "$TARGET_USER" ]; then
    echo "Error: Could not determine invoking user"
    exit 1
fi

CURRENT_STATE=$(loginctl show-user "$TARGET_USER" -p Linger | cut -d= -f2)

if [ "$CURRENT_STATE" = "yes" ]; then
    echo "Lingering already enabled for user: $TARGET_USER"
    exit 0
fi

echo "Enabling systemd user lingering for $TARGET_USER..."
loginctl enable-linger "$TARGET_USER"

echo "Success: Lingering enabled for $TARGET_USER"
echo "User services will now start at boot and survive logout."
