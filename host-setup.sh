#!/bin/bash

# Dependencies:
# python3-venv:      Critical for creating isolated environments
# python3-pip:       Required for package management
# git:               Version control
# lsof:              Used to check for blocking ports
# iproute2:          Provides "ss", used to check which ports are listening
# dbus-user-session: REQUIRED for 'systemctl --user' on minimal distros (DietPi)
# libpam-systemd:    Triggers systemd startup on login
DEPS=("python3" "python3-venv" "python3-pip" "git" "lsof" "iproute2" "dbus-user-session" "libpam-systemd")
TARGET_LINK="/usr/local/bin/systemd-compose"
SCRIPT_DIR="$(dirname "$(realpath "$0")")"
SOURCE_SCRIPT="$SCRIPT_DIR/systemd-compose.sh"

JOURNAL_DIR="${JOURNAL_DIR:-/var/log/journal}"
JOURNALD_DROPIN_DIR="${JOURNALD_DROPIN_DIR:-/etc/systemd/journald.conf.d}"
JOURNALD_DROPIN="$JOURNALD_DROPIN_DIR/99-systemd-compose.conf"

# --- HELPERS: LOG ACCESS ---

# Prints journald's effective Storage= setting: auto, persistent, volatile or none
journal_storage_setting() {
    local storage
    storage=$(systemd-analyze cat-config systemd/journald.conf 2>/dev/null \
        | sed -n 's/^[[:space:]]*Storage=[[:space:]]*//p' | tail -n 1)
    echo "${storage:-auto}"
}

# journald only writes a separate journal per user (which that user may read
# without extra groups) when logs are stored on disk.
journal_is_persistent() {
    case "$(journal_storage_setting)" in
        persistent) return 0 ;;
        auto) [ -d "$JOURNAL_DIR" ] ;;
        *) return 1 ;;
    esac
}

enable_persistent_journal() {
    sudo mkdir -p "$JOURNALD_DROPIN_DIR" &&
        printf '# Added by systemd-compose host-setup.sh\n[Journal]\nStorage=persistent\n' \
            | sudo tee "$JOURNALD_DROPIN" >/dev/null &&
        sudo systemctl restart systemd-journald &&
        sudo journalctl --flush
}

# Makes sure `systemd-compose logs` can show the user's app logs. Prefers
# storing the journal on disk (each user reads only their own logs) over the
# systemd-journal group (which can read every log on the system).
ensure_log_access() {
    if id -nG "$USER" | grep -qw "systemd-journal"; then
        echo "✅ User is in the 'systemd-journal' group (logs visible)."
        return 0
    fi
    if journal_is_persistent; then
        echo "✅ The journal is stored on disk, so you can read your apps' logs."
        return 0
    fi

    echo "⚠️  The system journal is only kept in memory (Storage=$(journal_storage_setting))."
    echo "   In that mode you can't read your own apps' logs without extra permissions."
    echo "   Recommended: store the journal on disk. Each user can then read their own logs."
    echo "   (journald limits it to 10% of the disk, 4 GB at most.)"
    read -p "❓ Store the journal on disk? (Requires sudo) [y/N] " -n 1 -r
    echo ""
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        if enable_persistent_journal && journal_is_persistent; then
            echo "✅ The journal is now stored on disk ($JOURNALD_DROPIN)."
            return 0
        fi
        echo "❌ Couldn't switch the journal to disk. Another setting may override it:"
        echo "   systemd-analyze cat-config systemd/journald.conf"
    fi

    echo "   Alternative: join the 'systemd-journal' group. Note: it can read ALL system logs."
    read -p "❓ Add user '$USER' to the group? (Requires sudo) [y/N] " -n 1 -r
    echo ""
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        sudo usermod -aG systemd-journal "$USER"
        echo "✅ User added to group."
        GROUPS_CHANGED=1
    else
        echo "⚠️  Skipped. 'systemd-compose logs' may show nothing."
    fi
}

# The tests source this file to check the helpers above; stop here for them.
if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
    return 0
fi

# --- OS COMPATIBILITY CHECK ---
if ! command -v apt-get &> /dev/null; then
    echo "❌ Error: This script supports Debian/Ubuntu based systems only."
    echo "   (Raspbian, DietPi, Ubuntu, Mint, etc.)"
    echo "   Reason: It relies on 'apt' for package management."
    exit 1
fi

echo "=== 🛠️  Host Dependency Check ==="

MISSING_DEPS=()
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
            sudo apt update && sudo apt install -y "${MISSING_DEPS[@]}"
        else
            apt update && apt install -y "${MISSING_DEPS[@]}"
        fi
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

# --- CHECK: SYSTEMD VERSION ---
# Generated services use Type=exec, which needs systemd 240+ (Debian 10+, Ubuntu 20.04+).
SYSTEMD_VERSION=$(systemctl --version 2>/dev/null | awk 'NR==1 {print $2}')
if [[ "$SYSTEMD_VERSION" =~ ^[0-9]+$ ]] && [ "$SYSTEMD_VERSION" -lt 240 ]; then
    echo "❌ Error: systemd $SYSTEMD_VERSION is too old. systemd-compose needs systemd 240 or newer."
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
             echo "⚠️  Detected conflicting D-Bus symlink:"
             echo "   /etc/systemd/system/dbus-org.freedesktop.login1.service"
             read -p "❓ Remove it so systemd-logind can take over? (Requires sudo) [y/N] " -n 1 -r
             echo ""
             if [[ $REPLY =~ ^[Yy]$ ]]; then
                 sudo rm /etc/systemd/system/dbus-org.freedesktop.login1.service
                 sudo systemctl daemon-reload
                 echo "✅ Conflict removed."
             fi
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
                    {
                        echo ""
                        echo "# systemd-compose fix: Define XDG vars for systemd user session"
                        echo "export XDG_RUNTIME_DIR=\"$EXPECTED_DIR\""
                        echo "export DBUS_SESSION_BUS_ADDRESS=\"unix:path=\${XDG_RUNTIME_DIR}/bus\""
                    } >> "$HOME/.bashrc"
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

# --- ACTION: LOG ACCESS ---

ensure_log_access

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
    echo "🔧 Making systemd-compose.sh executable..."
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