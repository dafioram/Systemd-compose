#!/bin/bash

# --- OS COMPATIBILITY CHECK ---
if ! command -v apt-get &> /dev/null; then
    echo "❌ Error: This script supports Debian/Ubuntu based systems only."
    echo "   (Raspbian, DietPi, Ubuntu, Mint, etc.)"
    echo "   Reason: It relies on 'apt' for package management."
    exit 1
fi

# Dependencies:
# python3-venv:      Critical for creating isolated environments
# python3-pip:       Required for package management
# git:               Version control
# lsof:              Used to check for blocking ports
# dbus-user-session: REQUIRED for 'systemctl --user' on minimal distros (DietPi)
# libpam-systemd:    Triggers systemd startup on login
DEPS=("python3" "python3-venv" "python3-pip" "git" "lsof" "dbus-user-session" "libpam-systemd")
TARGET_LINK="/usr/local/bin/app-ctl"
SCRIPT_DIR="$(dirname "$(realpath "$0")")"
SOURCE_SCRIPT="$SCRIPT_DIR/app-ctl.sh"

echo "=== 🛠️  Host Dependency Check ==="

MISSING_DEPS=()
INSTALLED_NEW_DEPS=0
GROUPS_CHANGED=0

# 1. Check for Debian Packages
for dep in "${DEPS[@]}"; do
    if ! dpkg -s "$dep" >/dev/null 2>&1; then
        if ! command -v "$dep" &> /dev/null; then
             MISSING_DEPS+=("$dep")
        fi
    fi
done

# --- ACTION: INSTALL DEPS ---

if [ ${#MISSING_DEPS[@]} -ne 0 ]; then
    echo "❌ Missing system dependencies: ${MISSING_DEPS[*]}"
    echo "   (Note: 'dbus-user-session' is critical for minimal OS like DietPi)"
    read -p "❓ Install them now? (Requires sudo) [y/N] " -n 1 -r
    echo ""
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        if [ "$EUID" -ne 0 ]; then
            echo "pw" | sudo -S apt update
            sudo apt install -y "${MISSING_DEPS[@]}"
        else
            apt update && apt install -y "${MISSING_DEPS[@]}"
        fi
        INSTALLED_NEW_DEPS=1
    else
        echo "⚠️  Skipping installation. Framework will likely fail."
    fi
else
    echo "✅ All system packages installed."
fi

# --- CHECK: PYTHON FUNCTIONALITY ---
# Packages might be installed but broken. Verify we can actually invoke python.
if ! python3 -c "import venv" 2>/dev/null; then
    echo "❌ Error: Python 3 is installed, but the 'venv' module is broken."
    echo "   Run: sudo apt install --reinstall python3-venv"
    # Don't exit, let the user decide if they want to continue
fi

# --- HELPER: FIX DIETPI / MINIMAL LOGIND ---

ensure_logind_service() {
    IS_MASKED=$(systemctl is-enabled systemd-logind 2>/dev/null)
    
    if [ "$IS_MASKED" == "masked" ]; then
        echo "⚠️  Detected masked systemd-logind (Common on DietPi)."
        echo "   Unmasking and starting login manager..."
        sudo systemctl unmask systemd-logind
        sudo systemctl daemon-reload
        sudo systemctl start systemd-logind
        echo "✅ systemd-logind unmasked and started."
    fi

    if [ -L "/etc/systemd/system/dbus-org.freedesktop.login1.service" ]; then
        if ! loginctl show-user "$USER" &>/dev/null; then
             echo "⚠️  Detected conflicting D-Bus symlink. Removing..."
             sudo rm /etc/systemd/system/dbus-org.freedesktop.login1.service
             sudo systemctl daemon-reload
             echo "✅ Conflict removed."
        fi
    fi
}

# --- HELPER: FIX SHELL ENVIRONMENT ---

fix_shell_environment() {
    if pgrep -u "$USER" -f "systemd --user" >/dev/null; then
        if [ -z "$XDG_RUNTIME_DIR" ] || [ ! -d "$XDG_RUNTIME_DIR" ]; then
            EXPECTED_DIR="/run/user/$(id -u)"
            if [ -d "$EXPECTED_DIR" ]; then
                echo "⚠️  Systemd is running, but shell environment variables are missing."
                echo "   Patching ~/.bashrc to fix this..."
                if ! grep -q "XDG_RUNTIME_DIR" "$HOME/.bashrc"; then
                    echo "" >> "$HOME/.bashrc"
                    echo "# App-Ctl Fix: Define XDG vars for systemd user session" >> "$HOME/.bashrc"
                    echo "export XDG_RUNTIME_DIR=\"$EXPECTED_DIR\"" >> "$HOME/.bashrc"
                    echo "export DBUS_SESSION_BUS_ADDRESS=\"unix:path=\${XDG_RUNTIME_DIR}/bus\"" >> "$HOME/.bashrc"
                    echo "✅ Fix added to ~/.bashrc"
                fi
                export XDG_RUNTIME_DIR="$EXPECTED_DIR"
                export DBUS_SESSION_BUS_ADDRESS="unix:path=${XDG_RUNTIME_DIR}/bus"
            fi
        fi
    fi
}

# --- ACTION: APPLY FIXES ---

ensure_logind_service
fix_shell_environment

# --- ACTION: LOG PERMISSIONS ---

if groups "$USER" | grep -q "systemd-journal"; then
    echo "✅ User is in 'systemd-journal' group (Logs visible)."
else
    echo "⚠️  User '$USER' is NOT in 'systemd-journal' group."
    echo "   You won't be able to see app logs without this."
    read -p "❓ Add user to group now? (Requires sudo) [y/N] " -n 1 -r
    echo ""
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        sudo usermod -aG systemd-journal "$USER"
        echo "✅ User added to group."
        GROUPS_CHANGED=1
    fi
fi

# --- ACTION: ENABLE LINGER ---

LINGER_STATE=$(loginctl show-user "$USER" --property=Linger 2>/dev/null | cut -d= -f2)

if [ "$LINGER_STATE" != "yes" ]; then
    echo "⚠️  Systemd Linger is DISABLED for user $USER."
    echo "   Without this, apps will die when you logout."
    read -p "❓ Enable Linger now? [y/N] " -n 1 -r
    echo ""
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        if sudo loginctl enable-linger "$USER"; then
            echo "✅ Linger enabled."
        else
            echo "❌ Failed to enable linger."
            echo "   Please REBOOT your server and run this script again."
        fi
    fi
else
    echo "✅ Systemd Linger is enabled."
fi

# --- ACTION: SYMLINK & PERMISSIONS ---

echo "--- 🔗 Symlink Setup ---"

# Ensure the main script is executable
if [ ! -x "$SOURCE_SCRIPT" ]; then
    echo "🔧 Making app-ctl.sh executable..."
    chmod +x "$SOURCE_SCRIPT"
fi

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
if [ "$GROUPS_CHANGED" -eq 1 ]; then
    echo ""
    echo "⚠️  IMPORTANT: You must LOG OUT and LOG BACK IN for group changes to take effect."
    echo "   (Or reboot if you installed system packages)"
fi