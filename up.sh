#!/bin/bash
set -e

# 1. Load Settings & Root Check
if [ ! -f ./app.settings ]; then echo "Error: app.settings not found"; exit 1; fi
source ./app.settings

if [ "$EUID" -ne 0 ]; then echo "Error: Run with sudo"; exit 1; fi

echo "--- Installing $APP_NAME ---"

# 2. Dependency Checks
if ! command -v python3 &> /dev/null; then echo "Error: python3 missing"; exit 1; fi

# 3. Setup Virtual Env
if [ ! -d "venv" ]; then
    echo "Creating virtual environment..."
    python3 -m venv venv
    ./venv/bin/pip install --upgrade pip
fi

if [ -f "requirements.txt" ]; then
    echo "Installing requirements..."
    ./venv/bin/pip install -r requirements.txt
fi

# 4. Prepare Dynamic Variables
WORKING_DIR=$(pwd)
REAL_USER=${SUDO_USER:-$(id -un)}
VENV_PATH="$WORKING_DIR/venv/bin"

# Extract Port from .env based on the key defined in settings
if [ -f .env ]; then
    APP_PORT=$(grep -E "^${ENV_PORT_KEY}=[0-9]+" .env | cut -d '=' -f2)
    if [ -z "$APP_PORT" ]; then echo "Error: $ENV_PORT_KEY not found in .env"; exit 1; fi
else
    echo "Error: .env file missing"; exit 1;
fi

# 5. Build the Start Command
# We inject the specific paths and ports into your custom command string
EXEC_START_FINAL=$(echo "$EXEC_CMD" | \
    sed "s|{{VENV}}|$VENV_PATH|g" | \
    sed "s|{{PORT}}|$APP_PORT|g")

echo "Command configured: $EXEC_START_FINAL"

# 6. Generate Service File
TEMPLATE="app.service.template"
SERVICE_FILE="${APP_NAME}.service"

sed -e "s|{{WORKING_DIR}}|$WORKING_DIR|g" \
    -e "s|{{USER}}|$REAL_USER|g" \
    -e "s|{{APP_DESCRIPTION}}|$APP_DESCRIPTION|g" \
    -e "s|{{EXEC_START_FINAL}}|$EXEC_START_FINAL|g" \
    "$TEMPLATE" > "$SERVICE_FILE"

# 7. Register and Start
mv "$SERVICE_FILE" "/etc/systemd/system/$SERVICE_FILE"
systemctl daemon-reload
systemctl enable "$SERVICE_FILE"
systemctl restart "$SERVICE_FILE"

echo "------------------------------------------------"
echo "Success: $APP_NAME is running on port $APP_PORT"
echo "------------------------------------------------"