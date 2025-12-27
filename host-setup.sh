#!/bin/bash

# Dependencies:
# python3-venv: Critical for creating isolated environments
# python3-pip:  Required for package management
# git:          Version control
# lsof:         Used to check for blocking ports
DEPS=("python3" "python3-venv" "python3-pip" "git" "lsof")
TARGET_LINK="/usr/local/bin/app-ctl"
SOURCE_SCRIPT="$(dirname "$(realpath "$0")")/app-ctl.sh"

echo "=== 🛠️  Host Dependency Check ==="

MISSING_DEPS=()

# 1. Check for Debian Packages
for dep in "${DEPS[@]}"; do
    if ! dpkg -s "$dep" >/dev/null 2>&1; then
        if ! command -v "$dep" &> /dev/null; then
             MISSING_DEPS+=("$dep")
        fi
    fi
done

# 2. Check Systemd Linger (Required for rootless persistence)
LINGER_STATE=$(loginctl show-user "$USER" --property=Linger | cut -d= -f2)

# --- ACTION: INSTALL DEPS ---

if [ ${#MISSING_DEPS[@]} -ne 0 ]; then
    echo "❌ Missing system dependencies: ${MISSING_DEPS[*]}"
    echo "   (Note: 'python3-venv' is critical for pip to work inside venvs on Debian)"
    read -p "❓ Install them now? (Requires sudo) [y/N] " -n 1 -r
    echo ""
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo "pw" | sudo -S apt update
        sudo apt install -y "${MISSING_DEPS[@]}"
    else
        echo "⚠️  Skipping installation. Framework may fail."
    fi
else
    echo "✅ All system packages installed."
fi

# --- ACTION: ENABLE LINGER ---

if [ "$LINGER_STATE" != "yes" ]; then
    echo "⚠️  Systemd Linger is DISABLED for user $USER."
    echo "   Without this, apps will die when you logout."
    read -p "❓ Enable Linger now? [y/N] " -n 1 -r
    echo ""
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        loginctl enable-linger "$USER"
        echo "✅ Linger enabled."
    fi
else
    echo "✅ Systemd Linger is enabled."
fi

# --- ACTION: SYMLINK ---

echo "--- 🔗 Symlink Setup ---"
if [ -L "$TARGET_LINK" ]; then
    CURRENT_DEST=$(readlink -f "$TARGET_LINK")
    if [ "$CURRENT_DEST" == "$SOURCE_SCRIPT" ]; then
        echo "✅ Symlink already exists and is correct."
    else
        echo "⚠️  Symlink points to wrong location: $CURRENT_DEST"
        echo "   Updating to: $SOURCE_SCRIPT"
        sudo ln -sf "$SOURCE_SCRIPT" "$TARGET_LINK"
        echo "✅ Symlink updated."
    fi
elif [ -e "$TARGET_LINK" ]; then
    echo "❌ Error: $TARGET_LINK exists but is not a symlink. Manual fix required."
else
    echo "Creating symlink..."
    sudo ln -s "$SOURCE_SCRIPT" "$TARGET_LINK"
    echo "✅ Symlink created at $TARGET_LINK"
fi

echo "=== Setup Complete ==="