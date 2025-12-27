#!/bin/bash

# Usage: app-ctl <project_folder> <command>
PROJECT_DIR_ARG=$1
COMMAND=$2

# Determine the directory where this script lives
SCRIPT_DIR="$(dirname "$(realpath "$0")")"
TEMPLATE_FILE="$SCRIPT_DIR/templates/service.unit"

# --- GLOBAL CONFIGURATION LOADING ---

# 1. Load Global .env (if exists) for APPS_ROOT
if [ -f "$SCRIPT_DIR/.env" ]; then
    set -a
    source "$SCRIPT_DIR/.env"
    set +a
fi

# 2. Set Default APPS_ROOT (Where 'ps' looks)
APPS_ROOT="${APPS_ROOT:-$SCRIPT_DIR/projects}"

# --- ARGUMENT VALIDATION ---

if [[ -z "$PROJECT_DIR_ARG" || -z "$COMMAND" ]]; then
    echo "Usage: app-ctl <project_folder> [up|down|build|run|stop|status|logs|ps]"
    exit 1
fi

# Handle 'ps' command (Does not require a valid project folder)
if [ "$COMMAND" == "ps" ]; then
    :
else
    # For all other commands, validate project directory
    if [ ! -d "$PROJECT_DIR_ARG" ]; then
        echo "❌ Error: Project directory '$PROJECT_DIR_ARG' not found."
        exit 1
    fi
    # Resolve absolute path
    PROJECT_DIR="$(realpath "$PROJECT_DIR_ARG")"
    INSTALL_DIR="$PROJECT_DIR"
    
    # 3. Load Project-Specific .env (Secrets & Port)
    if [ -f "$PROJECT_DIR/.env" ]; then
        export $(grep -v '^#' "$PROJECT_DIR/.env" | xargs)
    fi

    # 4. Load Project Config (Structure)
    if [ -f "$PROJECT_DIR/config.env" ]; then
        source "$PROJECT_DIR/config.env"
    else
        echo "❌ Error: config.env not found in $PROJECT_DIR"
        exit 1
    fi

    # Default APP_DIR to "." if not set
    if [ -z "$APP_DIR" ]; then
        APP_DIR="."
    fi

    SYSTEMD_DIR="$HOME/.config/systemd/user"
    SERVICE_FILE="$SYSTEMD_DIR/${APP_NAME}.service"
fi

# --- HELPER FUNCTIONS ---

check_port() {
    if [ -z "$PORT" ]; then
        return 0 
    fi
    if ss -tuln | grep -q ":$PORT "; then
        echo "❌ Error: Port $PORT is already in use."
        echo "Blocking process:"
        lsof -i :$PORT | grep LISTEN
        return 1
    fi
    echo "✅ Port $PORT is free."
    return 0
}

check_binary() {
    BINARY_PATH="$INSTALL_DIR/venv/bin/$ENTRYPOINT"
    if [ ! -f "$BINARY_PATH" ]; then
        echo "❌ Error: The entrypoint binary '$ENTRYPOINT' was not found in the venv."
        echo "   Checked path: $BINARY_PATH"
        echo ""
        echo "   Possible fixes:"
        echo "   1. Did you forget to add '$ENTRYPOINT' to requirements.txt?"
        echo "   2. Did you forget to run 'build'?"
        echo "   3. If using standard python, ensure ENTRYPOINT=\"python\""
        return 1
    fi
    return 0
}

# --- CORE COMMANDS ---

build() {
    echo "--- 🏗️ Building ${APP_NAME} ---"
    
    # Check for python3-venv capability
    $PYTHON_BIN -c "import venv" 2>/dev/null
    if [ $? -ne 0 ]; then
        echo "❌ Error: The 'venv' module is missing. Please run ./host-setup.sh"
        exit 1
    fi

    if [ ! -d "$INSTALL_DIR/venv" ]; then
        echo "Creating Python venv..."
        $PYTHON_BIN -m venv "$INSTALL_DIR/venv"
        
        # Bootstrap pip if missing (Debian fix)
        if [ ! -f "$INSTALL_DIR/venv/bin/pip" ]; then
            echo "⚠️  Pip missing. Bootstrapping..."
            "$INSTALL_DIR/venv/bin/python" -m ensurepip --upgrade
        fi
    fi

    echo "Installing dependencies..."
    if [ -f "$INSTALL_DIR/requirements.txt" ]; then
        "$INSTALL_DIR/venv/bin/pip" install -r "$INSTALL_DIR/requirements.txt" --quiet --disable-pip-version-check
    else
        echo "⚠️  No requirements.txt found. Skipping pip install."
    fi
    
    echo "Build Complete."
}

run() {
    echo "--- 🚀 Starting ${APP_NAME} ---"
    
    if ! check_port; then exit 1; fi
    if ! check_binary; then exit 1; fi

    mkdir -p "$SYSTEMD_DIR"

    # Generate Systemd Unit from Template
    cat "$TEMPLATE_FILE" | \
    sed "s|\${DESCRIPTION}|$DESCRIPTION|g" | \
    sed "s|\${INSTALL_DIR}|$INSTALL_DIR|g" | \
    sed "s|\${ENTRYPOINT}|$ENTRYPOINT|g" | \
    sed "s|\${APP_DIR}|$APP_DIR|g" | \
    sed "s|\${ARGS}|$ARGS|g" \
    > "$SERVICE_FILE"

    systemctl --user daemon-reload
    systemctl --user enable "${APP_NAME}"
    systemctl --user restart "${APP_NAME}"
    
    echo "Service started."
    sleep 1
    status
}

stop() {
    echo "--- 🛑 Stopping ${APP_NAME} ---"
    if systemctl --user is-active --quiet "${APP_NAME}"; then
        systemctl --user stop "${APP_NAME}"
        echo "Stopped."
    else
        echo "App was not running."
    fi
}

status() {
    echo "--- 📊 Status: ${APP_NAME} ---"
    IS_ACTIVE=$(systemctl --user is-active "${APP_NAME}")
    echo "Service State:  $IS_ACTIVE"
    
    if [ "$IS_ACTIVE" == "active" ]; then
        MAIN_PID=$(systemctl --user show --property MainPID --value "${APP_NAME}")
        MEM_USAGE=$(ps -o rss= -p "$MAIN_PID" 2>/dev/null | awk '{print int($1/1024) " MB"}')
        echo "Main PID:       $MAIN_PID"
        echo "Memory Usage:   $MEM_USAGE"
    fi

    if [ ! -z "$PORT" ]; then
        if ss -tuln | grep -q ":$PORT "; then
            echo "Port $PORT:      ✅ Listening"
        else
            echo "Port $PORT:      ❌ Not Listening"
        fi
    fi
    echo ""
    echo "--- Recent Logs ---"
    journalctl --user -u "${APP_NAME}" -n 3 --no-pager
}

# --- COMPOSITE COMMANDS ---

up() {
    echo "=== UP: ${APP_NAME} ==="
    build
    run
}

down() {
    echo "=== DOWN: ${APP_NAME} ==="
    stop
    systemctl --user disable "${APP_NAME}" 2>/dev/null
    rm -f "$SERVICE_FILE"
    systemctl --user daemon-reload
    
    if [ -d "$INSTALL_DIR/venv" ]; then
        echo "Removing venv..."
        rm -rf "$INSTALL_DIR/venv"
    fi
    echo "Cleanup complete."
}

logs() {
    journalctl --user -u "${APP_NAME}" -f
}

ps_dashboard() {
    echo "-----------------------------------------------------------------------------------------"
    printf "%-25s %-12s %-10s %-8s %-20s\n" "PROJECT ID" "STATUS" "PID" "PORT" "UPTIME"
    echo "-----------------------------------------------------------------------------------------"
    
    SEARCH_DIR="$APPS_ROOT"

    if [ ! -d "$SEARCH_DIR" ]; then
        echo "Error: APPS_ROOT directory '$SEARCH_DIR' does not exist."
        return
    fi

    for proj in "$SEARCH_DIR"/*; do
        if [ -d "$proj" ] && [ -f "$proj/config.env" ]; then
            NAME=$(grep '^APP_NAME=' "$proj/config.env" | cut -d '"' -f 2)
            STATUS=$(systemctl --user is-active "$NAME" 2>/dev/null || echo "not-found")
            
            PID="-"
            UPTIME="-"
            PORT_VAL="-"

            if [ "$STATUS" == "active" ]; then
                PID=$(systemctl --user show --property MainPID --value "$NAME")
                UPTIME=$(ps -p "$PID" -o etime= 2>/dev/null | xargs)
            fi

            if [ -f "$proj/.env" ]; then
                PORT_VAL=$(grep '^PORT=' "$proj/.env" | cut -d '=' -f 2)
            fi
            
            printf "%-25s %-12s %-10s %-8s %-20s\n" "$NAME" "$STATUS" "$PID" "$PORT_VAL" "$UPTIME"
        fi
    done
    echo "-----------------------------------------------------------------------------------------"
    echo "Scanning: $SEARCH_DIR"
}

# --- DISPATCHER ---

case "$COMMAND" in
    up)     up ;;
    down)   down ;;
    build)  build ;;
    run)    run ;;
    stop)   stop ;;
    status) status ;;
    logs)   logs ;;
    ps)     ps_dashboard ;;
    *)      echo "Unknown command: $COMMAND" ;;
esac