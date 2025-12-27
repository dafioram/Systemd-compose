#!/bin/bash

# Dependencies:
# python3-venv:      Critical for creating isolated environments
# python3-pip:       Required for package management
# git:               Version control
# lsof:              Used to check for blocking ports
# dbus-user-session: REQUIRED for 'systemctl --user' on minimal distros (DietPi)
DEPS=("python3" "python3-venv" "python3-pip" "git" "lsof" "dbus-user-session")
TARGET_LINK="/usr/local/bin/app-ctl"
SOURCE_SCRIPT="$(dirname "$(realpath "$0")")/app-ctl.sh"

echo "=== 🛠️  Host Dependency Check ==="

MISSING_DEPS=()
INSTALLED_NEW_DEPS=0

# 1. Check for Debian Packages
for dep in "${DEPS[@]}"; do
    if ! dpkg -s "$dep" >/dev/null 2>&1; then
        # Check if command exists (fallback for packages with different binary names)
        if ! command -v "$dep" &> /dev/null; then
             MISSING_DEPS+=("$dep")
        fi
    fi
done

# 2. Check Systemd Linger
LINGER_STATE=$(loginctl show-user "$USER" --property=Linger | cut -d= -f2)

# --- ACTION: INSTALL DEPS ---

if [ ${#MISSING_DEPS[@]} -ne 0 ]; then
    echo "❌ Missing system dependencies: ${MISSING_DEPS[*]}"
    echo "   (Note: 'dbus-user-session' is critical for minimal OS like DietPi)"
    read -p "❓ Install them now? (Requires sudo) [y/N] " -n 1 -r
    echo ""
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo "pw" | sudo -S apt update
        sudo apt install -y "${MISSING_DEPS[@]}"
        INSTALLED_NEW_DEPS=1
    else
        echo "⚠️  Skipping installation. Framework will likely fail."
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

# --- FINAL CHECK FOR DIETPI/MINIMAL USERS ---
if [ "$INSTALLED_NEW_DEPS" -eq 1 ]; then
    echo ""
    echo "⚠️  NOTE: New system packages were installed."
    echo "   If you are on DietPi or a minimal server, 'systemctl --user' might not work yet."
    echo "   Please REBOOT your server to initialize the User Bus."
    echo "   Command: sudo reboot"
fi