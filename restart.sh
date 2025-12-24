#!/bin/bash
set -e

# 1. Load Settings & Root Check
if [ ! -f ./app.settings ]; then echo "Error: app.settings not found"; exit 1; fi
source ./app.settings

if [ "$EUID" -ne 0 ]; then echo "Error: Run with sudo"; exit 1; fi

echo "--- Updating $APP_NAME ---"

# 2. Git Pull (Update Code)
if [ -d ".git" ]; then
    echo "Pulling latest changes..."
    # We run git as the actual user, not root, to avoid permission issues
    REAL_USER=${SUDO_USER:-$(id -un)}
    sudo -u "$REAL_USER" git pull
else
    echo "Not a git repo. Skipping pull."
fi

# 3. Re-Evaluate Configuration
# We must re-calculate variables in case .env or app.settings changed
WORKING_DIR=$(pwd)
REAL_USER=${SUDO_USER:-$(id -un)}
VENV_PATH="$WORKING_DIR/venv/bin"

if [ -f .env ]; then
    APP_PORT=$(grep -E "^${ENV_PORT_KEY}=[0-9]+" .env | cut -d '=' -f2)
else
    echo "Error: .env missing."
    exit 1
fi

# Re-build the generic command string
EXEC_START_FINAL=$(echo "$EXEC_CMD" | \
    sed "s|{{VENV}}|$VENV_PATH|g" | \
    sed "s|{{PORT}}|$APP_PORT|g")

# 4. Regenerate Service File
# We do this every time to ensure the service file matches current config
TEMPLATE="app.service.template"
SERVICE_FILE="${APP_NAME}.service"

sed -e "s|{{WORKING_DIR}}|$WORKING_DIR|g" \
    -e "s|{{USER}}|$REAL_USER|g" \
    -e "s|{{APP_DESCRIPTION}}|$APP_DESCRIPTION|g" \
    -e "s|{{EXEC_START_FINAL}}|$EXEC_START_FINAL|g" \
    "$TEMPLATE" > "$SERVICE_FILE"

# 5. Reload and Restart
mv "$SERVICE_FILE" "/etc/systemd/system/$SERVICE_FILE"
systemctl daemon-reload
systemctl restart "$SERVICE_FILE"

echo "Success: $APP_NAME restarted on port $APP_PORT"