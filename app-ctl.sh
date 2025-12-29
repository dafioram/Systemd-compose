#!/bin/bash

# --- GLOBAL CONFIGURATION LOADING ---
SCRIPT_DIR="$(dirname "$(realpath "$0")")"
TEMPLATE_FILE="$SCRIPT_DIR/templates/service.unit"

if [ -f "$SCRIPT_DIR/.env" ]; then
    set -a
    source "$SCRIPT_DIR/.env"
    set +a
fi

APPS_ROOT="${APPS_ROOT:-$SCRIPT_DIR/projects}"
# Default to system python if not specified in project config.env
# Can override python version there
PYTHON_BIN="${PYTHON_BIN:-python3}"

# --- ARGUMENT PARSING ---

if [ "$1" == "ps" ]; then
    COMMAND="ps"
elif [ -n "$1" ] && [ -n "$2" ]; then
    PROJECT_DIR_ARG="$1"
    COMMAND="$2"
else
    echo "Usage:"
    echo "  Global:  app-ctl ps"
    echo "  Project: app-ctl <project_folder> [up|down|build|run|stop|restart|status|logs]"
    exit 1
fi

# --- PROJECT CONTEXT LOADING ---

if [ "$COMMAND" != "ps" ]; then
    if [ ! -d "$PROJECT_DIR_ARG" ]; then
        echo "❌ Error: Project directory '$PROJECT_DIR_ARG' not found."
        exit 1
    fi
    PROJECT_DIR="$(realpath "$PROJECT_DIR_ARG")"
    INSTALL_DIR="$PROJECT_DIR"
    
    # [FIX 1] Robust .env Loading
    # Handles comments, DOS line endings (\r), and exports automatically
    if [ -f "$PROJECT_DIR/.env" ]; then
        set -a
        source <(sed 's/\r$//' "$PROJECT_DIR/.env" | grep -v '^\s*#')
        set +a
    fi

    if [ -f "$PROJECT_DIR/config.env" ]; then
        source "$PROJECT_DIR/config.env"
    else
        echo "❌ Error: config.env not found in $PROJECT_DIR"
        exit 1
    fi
    
    APP_NAME=$(echo "$APP_NAME" | tr ' ' '-')
    if [ -z "$APP_DIR" ]; then APP_DIR="."; fi

    SYSTEMD_DIR="$HOME/.config/systemd/user"
    SERVICE_FILE="$SYSTEMD_DIR/${APP_NAME}.service"
fi

# --- HELPER FUNCTIONS ---

check_port() {
    # [FIX 2] Explicitly warn if check is skipped
    if [ -z "$PORT" ]; then 
        echo "⚠️  Warning: PORT variable not found. Skipping port check."
        return 0
    fi

    # Check for listening ports (both IPv4 and IPv6)
    if ss -tuln | grep -q ":$PORT "; then
        echo "❌ Error: Port $PORT is already in use."
        echo "   Process blocking this port:"
        lsof -i :$PORT | grep LISTEN
        return 1
    fi
    echo "✅ Port $PORT is free."
    return 0
}

check_binary() {
    BINARY_PATH="$INSTALL_DIR/venv/bin/$ENTRYPOINT"
    if [ ! -f "$BINARY_PATH" ]; then
        echo "❌ Error: Binary '$ENTRYPOINT' not found in venv."
        return 1
    fi
    return 0
}

# --- CORE COMMANDS ---

build() {
    echo "--- 🏗️ Building ${APP_NAME} ---"
    $PYTHON_BIN -c "import venv" 2>/dev/null
    if [ $? -ne 0 ]; then
        echo "❌ Error: 'venv' module missing. Run ./host-setup.sh"
        exit 1
    fi

    if [ ! -d "$INSTALL_DIR/venv" ]; then
        echo "Creating Python venv..."
        $PYTHON_BIN -m venv "$INSTALL_DIR/venv"
        if [ ! -f "$INSTALL_DIR/venv/bin/pip" ]; then
            echo "⚠️  Pip missing. Bootstrapping..."
            "$INSTALL_DIR/venv/bin/python" -m ensurepip --upgrade
        fi
    fi

    echo "Installing dependencies..."
    if [ -f "$INSTALL_DIR/requirements.txt" ]; then
        "$INSTALL_DIR/venv/bin/pip" install -r "$INSTALL_DIR/requirements.txt" --quiet --disable-pip-version-check
    else
        echo "⚠️  No requirements.txt found."
    fi
    echo "Build Complete."
}

run() {
    echo "--- 🚀 Starting ${APP_NAME} ---"
    if ! check_port; then exit 1; fi
    if ! check_binary; then exit 1; fi

    mkdir -p "$SYSTEMD_DIR"

    cat "$TEMPLATE_FILE" | \
    sed "s|\${DESCRIPTION}|$DESCRIPTION|g" | \
    sed "s|\${INSTALL_DIR}|$INSTALL_DIR|g" | \
    sed "s|\${ENTRYPOINT}|$ENTRYPOINT|g" | \
    sed "s|\${APP_DIR}|$APP_DIR|g" | \
    sed "s|\${ARGS}|$ARGS|g" \
    > "$SERVICE_FILE"

    systemctl --user daemon-reload
    systemctl --user enable "${APP_NAME}"
    
    # [FIX 3] Capture Systemd Failure
    if ! systemctl --user restart "${APP_NAME}"; then
        echo ""
        echo "❌ Fatal: Systemd failed to start the service."
        echo "   This usually means the app crashed immediately (e.g., port conflict)."
        echo "--- 📜 Last 10 Log Lines ---"
        journalctl --user -u "${APP_NAME}" -n 10 --no-pager
        exit 1
    fi
    
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

restart() {
    echo "--- ♻️  Restarting ${APP_NAME} ---"
    
    # Check if the service is actually installed
    if ! systemctl --user list-unit-files "${APP_NAME}.service" >/dev/null 2>&1; then
        echo "❌ Service '${APP_NAME}' is not installed."
        echo "   Run 'app-ctl <project> up' first to build and install it."
        exit 1
    fi

    # Trigger restart
    systemctl --user restart "${APP_NAME}"
    
    # Validate health
    if systemctl --user is-active --quiet "${APP_NAME}"; then
        echo "✅ Restarted successfully."
        # Show status to verify PID/Port
        status
    else
        echo "❌ Restart Failed. Check logs:"
        journalctl --user -u "${APP_NAME}" -n 10 --no-pager
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
    journalctl --user -u "${APP_NAME}" -n 3 --no-pager
}

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
            RAW_NAME=$(grep '^APP_NAME=' "$proj/config.env" | cut -d '"' -f 2)
            NAME=$(echo "$RAW_NAME" | tr ' ' '-')
            RAW_STATUS=$(systemctl --user is-active "$NAME" 2>/dev/null || echo "unknown")
            
            case "$RAW_STATUS" in
                active)      DISPLAY_STATUS="RUNNING" ;;
                inactive)    DISPLAY_STATUS="STOPPED" ;;
                unknown)     DISPLAY_STATUS="UNREGISTERED" ;;
                failed)      DISPLAY_STATUS="CRASHED" ;;
                *)           DISPLAY_STATUS="$RAW_STATUS" ;;
            esac
            
            PID="-"
            UPTIME="-"
            PORT_VAL="-"

            if [ "$DISPLAY_STATUS" == "RUNNING" ]; then
                PID=$(systemctl --user show --property MainPID --value "$NAME")
                UPTIME=$(ps -p "$PID" -o etime= 2>/dev/null | xargs)
            fi
            if [ -f "$proj/.env" ]; then
                PORT_VAL=$(grep '^PORT=' "$proj/.env" | cut -d '=' -f 2)
            fi
            printf "%-25s %-12s %-10s %-8s %-20s\n" "$NAME" "$DISPLAY_STATUS" "$PID" "$PORT_VAL" "$UPTIME"
        fi
    done
    echo "-----------------------------------------------------------------------------------------"
}

# --- DISPATCHER ---
case "$COMMAND" in
    up)      up ;;
    down)    down ;;
    build)   build ;;
    run)     run ;;
    stop)    stop ;;
    restart) restart ;;
    status)  status ;;
    logs)    logs ;;
    ps)      ps_dashboard ;;
    *)       echo "Unknown command: $COMMAND" ;;
esac