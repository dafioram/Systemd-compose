#!/bin/bash

set -uo pipefail

# --- GLOBAL CONFIGURATION LOADING ---
SCRIPT_DIR="$(dirname "$(realpath "$0")")"
TEMPLATE_FILE="$SCRIPT_DIR/templates/service.unit"
SYSTEMD_DIR="$HOME/.config/systemd/user"

if [ -f "$SCRIPT_DIR/.env" ]; then
    set -a +u
    # shellcheck source=/dev/null
    source "$SCRIPT_DIR/.env"
    set +a -u
fi

APPS_ROOT="${APPS_ROOT:-$SCRIPT_DIR/projects}"

# Default to system python if not specified in project config.env
PYTHON_BIN="${PYTHON_BIN:-python3}"

# Keys a project .env may not set inside systemd-compose itself
# (they would change how this script runs, not just the app).
RESERVED_ENV_KEYS=" PATH HOME USER SHELL IFS PWD OLDPWD UID EUID PPID SHLVL SCRIPT_DIR TEMPLATE_FILE SYSTEMD_DIR APPS_ROOT PROJECT_DIR INSTALL_DIR SERVICE_FILE UNIT COMMAND "

# --- HELPER FUNCTIONS ---

usage() {
    echo "Usage:"
    echo "  Global:  systemd-compose [ps | stop-all | start-all]"
    echo "  Project: systemd-compose <project_folder> [up|down|build|run|stop|restart|status|logs]"
}

die() {
    echo "❌ Error: $*" >&2
    exit 1
}

# Reads a KEY=VALUE file the same way systemd's EnvironmentFile= does:
# nothing is executed, surrounding quotes are stripped, '#'/';' lines are comments.
# Each key becomes a (non-exported) shell variable, so config.env can use e.g. $PORT.
load_env_file() {
    local file="$1" line key value lineno=0
    while IFS= read -r line || [ -n "$line" ]; do
        lineno=$((lineno + 1))
        line="${line%$'\r'}"
        line="${line#"${line%%[![:space:]]*}"}"
        if [ -z "$line" ] || [[ "$line" == \#* || "$line" == \;* ]]; then
            continue
        fi
        if [[ "$line" == export[[:space:]]* ]]; then
            echo "⚠️  $file:$lineno: systemd ignores 'export' lines. Use plain KEY=VALUE." >&2
            continue
        fi
        if [[ ! "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=[[:space:]]*(.*)$ ]]; then
            echo "⚠️  $file:$lineno: ignoring malformed line (expected KEY=VALUE)." >&2
            continue
        fi
        key="${BASH_REMATCH[1]}"
        value="${BASH_REMATCH[2]}"
        value="${value%"${value##*[![:space:]]}"}"
        if [[ "$value" =~ ^\"(.*)\"$ || "$value" =~ ^\'(.*)\'$ ]]; then
            value="${BASH_REMATCH[1]}"
        fi
        if [[ "$RESERVED_ENV_KEYS" == *" $key "* || "$key" == BASH* ]]; then
            echo "⚠️  $file:$lineno: '$key' is reserved; systemd-compose will not read it." >&2
            continue
        fi
        printf -v "$key" '%s' "$value"
    done < "$file"
}

# Loads a project's .env and config.env into the current shell.
# Call it in a subshell when looping over several projects.
load_project_config() {
    local dir="$1"
    if [ -f "$dir/.env" ]; then
        load_env_file "$dir/.env"
    fi
    INSTALL_DIR="$dir"
    set +u
    # shellcheck source=/dev/null
    source "$dir/config.env"
    set -u

    APP_NAME="${APP_NAME:-}"
    APP_NAME="${APP_NAME// /-}"
    APP_DIR="${APP_DIR:-.}"
    REQUIRE_PORT="${REQUIRE_PORT:-true}"
    PORT="${PORT:-}"
    ENTRYPOINT="${ENTRYPOINT:-}"
    ARGS="${ARGS:-}"
    DESCRIPTION="${DESCRIPTION:-$APP_NAME}"
    STARTUP_TIMEOUT="${STARTUP_TIMEOUT:-15}"
    if ! [[ "$STARTUP_TIMEOUT" =~ ^[0-9]+$ ]]; then
        STARTUP_TIMEOUT=15
    fi
}

valid_app_name() {
    [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]]
}

port_listening() {
    ss -tuln 2>/dev/null | grep -qE ":$1[[:space:]]"
}

# --- ARGUMENT PARSING ---

# List of global commands that DO NOT require a project directory
case "${1:-}" in
    ps|stop-all|start-all)
        COMMAND="$1"
        ;;
    *)
        if [ -z "${1:-}" ] || [ -z "${2:-}" ]; then
            usage
            exit 1
        fi
        PROJECT_DIR_ARG="$1"
        COMMAND="$2"
        ;;
esac

# --- PROJECT CONTEXT LOADING ---

if [[ "$COMMAND" != "ps" && "$COMMAND" != "stop-all" && "$COMMAND" != "start-all" ]]; then
    if [ ! -d "$PROJECT_DIR_ARG" ]; then
        die "Project directory '$PROJECT_DIR_ARG' not found."
    fi
    PROJECT_DIR="$(realpath "$PROJECT_DIR_ARG")"
    if [ ! -f "$PROJECT_DIR/config.env" ]; then
        die "config.env not found in $PROJECT_DIR"
    fi

    load_project_config "$PROJECT_DIR"

    if ! valid_app_name "$APP_NAME"; then
        die "APP_NAME '$APP_NAME' in $PROJECT_DIR/config.env is invalid. Use letters, digits, '-', '_' or '.' (spaces become '-')."
    fi

    UNIT="$APP_NAME"
    SERVICE_FILE="$SYSTEMD_DIR/${UNIT}.service"
fi

check_name_collision() {
    # If the service file doesn't exist, we are safe (new app)
    if [ ! -f "$SERVICE_FILE" ]; then
        return 0
    fi

    # Extract the directory of the CURRENTLY registered service
    EXISTING_PATH=$(grep '^WorkingDirectory=' "$SERVICE_FILE" | cut -d '=' -f 2-)

    if [ -n "$EXISTING_PATH" ]; then
        EXISTING_REAL=$(realpath "$EXISTING_PATH" 2>/dev/null || echo "")
        CURRENT_REAL=$(realpath "$INSTALL_DIR/$APP_DIR" 2>/dev/null || echo "$INSTALL_DIR/$APP_DIR")

        # THE CHECK: Paths are different AND the old path still exists
        if [ "$EXISTING_REAL" != "$CURRENT_REAL" ] && [ -d "$EXISTING_REAL" ]; then
            echo "❌ Error: Name Conflict!"
            echo "   The app name '$APP_NAME' is already claimed by another active project:"
            echo "   👉 $EXISTING_REAL"
            echo ""
            echo "   To manage this project, you MUST change 'APP_NAME' in:"
            echo "   $PROJECT_DIR/config.env"
            echo "   (Example: APP_NAME=\"${APP_NAME}-2\")"
            return 1
        fi

        if [ ! -d "$EXISTING_REAL" ] && [[ "$COMMAND" == "up" || "$COMMAND" == "run" || "$COMMAND" == "start" ]]; then
            echo "⚠️  Notice: Claiming orphaned service name '$APP_NAME' (Old path missing)."
        fi
    fi
    return 0
}

warn_config_exports() {
    if grep -qE '^[[:space:]]*export[[:space:]]' "$PROJECT_DIR/config.env"; then
        echo "⚠️  config.env contains 'export' lines. Those are NOT passed to your app;"
        echo "   put variables your app needs in $PROJECT_DIR/.env instead."
    fi
}

check_port() {
    if [ "$REQUIRE_PORT" == "false" ]; then
        return 0
    fi

    if [ -z "$PORT" ]; then
        echo "❌ Error: REQUIRE_PORT=true, but 'PORT' variable is missing in .env."
        return 1
    fi

    if ! [[ "$PORT" =~ ^[0-9]+$ ]] || [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
        echo "❌ Error: PORT='$PORT' is not a valid port number."
        return 1
    fi

    if port_listening "$PORT"; then
        echo "❌ Error: Port $PORT is already in use."
        echo "   Process blocking this port:"
        if ! lsof -nP -i ":$PORT" -sTCP:LISTEN 2>/dev/null; then
            echo "   (Owned by another user. Try: sudo lsof -i :$PORT)"
        fi
        return 1
    fi
    echo "✅ Port $PORT is free."
    return 0
}

check_binary() {
    if [ -z "$ENTRYPOINT" ]; then
        echo "❌ Error: ENTRYPOINT is not set in config.env (e.g. ENTRYPOINT=\"python\")."
        return 1
    fi
    BINARY_PATH="$INSTALL_DIR/venv/bin/$ENTRYPOINT"
    if [ ! -f "$BINARY_PATH" ]; then
        echo "❌ Error: Binary '$ENTRYPOINT' not found in venv. Run 'build' first, and check requirements.txt."
        return 1
    fi
    return 0
}

# Fills in templates/service.unit. Values are escaped for systemd ("%" is a
# specifier, "$" expands variables in ExecStart) and copied literally, so
# characters such as "&" or "|" can't corrupt the file the way sed did.
render_unit() {
    local var value line key
    for var in DESCRIPTION INSTALL_DIR ENTRYPOINT APP_DIR ARGS; do
        if [[ "${!var}" == *$'\n'* ]]; then
            die "$var in config.env must be a single line."
        fi
    done
    if [[ "$INSTALL_DIR" == *[\"\\]* ]]; then
        die "The project path can't contain '\"' or '\\': $INSTALL_DIR"
    fi

    while IFS= read -r line || [ -n "$line" ]; do
        key="${line%%=*}"
        for var in DESCRIPTION INSTALL_DIR ENTRYPOINT APP_DIR ARGS; do
            value="${!var}"
            value="${value//%/%%}"
            if [ "$key" == "ExecStart" ]; then
                value="${value//\$/\$\$}"
            fi
            line="${line//"\${$var}"/"$value"}"
        done
        printf '%s\n' "$line"
    done < "$TEMPLATE_FILE"
}

# Type=exec only catches a binary that can't be started. Watch the app for a
# few seconds so a crash right after startup (bad import, port taken, wrong
# PORT) is reported here instead of silently looping in the background.
wait_for_startup() {
    local elapsed=0 state restarts
    local min_wait=3
    while true; do
        sleep 1
        elapsed=$((elapsed + 1))
        state=$(systemctl --user show --property ActiveState --value "${UNIT}.service")
        restarts=$(systemctl --user show --property NRestarts --value "${UNIT}.service")
        if [ "${restarts:-0}" != "0" ]; then
            echo "❌ The app crashed during startup and systemd restarted it (${restarts}x)."
            return 1
        fi
        if [ "$state" != "active" ]; then
            echo "❌ The app exited during startup (state: $state)."
            return 1
        fi
        if [ "$REQUIRE_PORT" == "false" ]; then
            [ "$elapsed" -ge "$min_wait" ] && return 0
        elif port_listening "$PORT"; then
            return 0
        elif [ "$elapsed" -ge "$STARTUP_TIMEOUT" ]; then
            echo "❌ The app is running but not listening on port $PORT after ${STARTUP_TIMEOUT}s."
            echo "   Check that ARGS binds to \$PORT, or raise STARTUP_TIMEOUT in config.env."
            return 1
        fi
    done
}

# Memory of the whole service (all workers), not just the main process.
service_memory() {
    local bytes cgroup pids
    bytes=$(systemctl --user show --property MemoryCurrent --value "${UNIT}.service")
    if [[ "$bytes" =~ ^[0-9]+$ ]] && [ "$bytes" != "18446744073709551615" ]; then
        echo "$((bytes / 1024 / 1024)) MB"
        return
    fi
    # Memory accounting is off: add up every process in the service's cgroup
    cgroup=$(systemctl --user show --property ControlGroup --value "${UNIT}.service")
    if [ -n "$cgroup" ] && [ -r "/sys/fs/cgroup${cgroup}/cgroup.procs" ]; then
        pids=$(paste -sd, "/sys/fs/cgroup${cgroup}/cgroup.procs")
    else
        pids=$(systemctl --user show --property MainPID --value "${UNIT}.service")
    fi
    if [ -n "$pids" ] && [ "$pids" != "0" ]; then
        ps -o rss= -p "$pids" 2>/dev/null | awk '{ kb += $1 } END { print int(kb / 1024) " MB" }'
    fi
}

show_recent_logs() {
    echo "--- 📜 Last ${1} Log Lines ---"
    journalctl --user -u "${UNIT}.service" -n "$1" --no-pager
}

# --- CORE COMMANDS ---

build() {
    echo "--- 🏗️ Building ${APP_NAME} ---"

    if ! "$PYTHON_BIN" -c "import venv" 2>/dev/null; then
        die "'$PYTHON_BIN' is missing the 'venv' module. Run ./host-setup.sh"
    fi

    if [ ! -d "$INSTALL_DIR/venv" ]; then
        echo "Creating Python venv..."
        if ! "$PYTHON_BIN" -m venv "$INSTALL_DIR/venv"; then
            rm -rf "$INSTALL_DIR/venv"
            die "Failed to create the venv."
        fi
        if [ ! -f "$INSTALL_DIR/venv/bin/pip" ]; then
            echo "⚠️  Pip missing. Bootstrapping..."
            "$INSTALL_DIR/venv/bin/python" -m ensurepip --upgrade || die "Failed to bootstrap pip."
        fi
    fi

    echo "Installing dependencies..."
    if [ -f "$INSTALL_DIR/requirements.txt" ]; then
        if ! "$INSTALL_DIR/venv/bin/pip" install -r "$INSTALL_DIR/requirements.txt" --quiet --disable-pip-version-check; then
            die "Dependency installation failed (see pip output above)."
        fi
    else
        echo "⚠️  No requirements.txt found."
    fi
    echo "Build Complete."
}

run() {
    echo "--- 🚀 Starting ${APP_NAME} ---"

    warn_config_exports
    if ! check_binary; then exit 1; fi

    # If this app is already installed, stop it first so a port it holds
    # does not count as "in use" and the new config is applied cleanly.
    if [ -f "$SERVICE_FILE" ]; then
        systemctl --user stop "${UNIT}.service" 2>/dev/null
    fi

    if ! check_port; then exit 1; fi

    mkdir -p "$SYSTEMD_DIR"

    local unit_content
    unit_content=$(render_unit) || exit 1
    printf '%s\n' "$unit_content" > "$SERVICE_FILE"

    systemctl --user daemon-reload
    systemctl --user enable --quiet "${UNIT}.service"
    # Clear a previous "failed" state so the start limit doesn't block us
    systemctl --user reset-failed "${UNIT}.service" 2>/dev/null

    if ! systemctl --user start "${UNIT}.service"; then
        echo ""
        echo "❌ Fatal: Systemd failed to start the service."
        show_recent_logs 10
        exit 1
    fi

    if ! wait_for_startup; then
        show_recent_logs 15
        exit 1
    fi

    echo "✅ Service started."
    status
}

stop() {
    echo "--- 🛑 Stopping ${APP_NAME} ---"
    if [ ! -f "$SERVICE_FILE" ]; then
        echo "Service is not installed."
        return 0
    fi
    # Always stop: an app in a crash loop is "activating", not "active".
    if ! systemctl --user stop "${UNIT}.service"; then
        die "Failed to stop ${UNIT}."
    fi
    echo "Stopped."
}

restart() {
    echo "--- ♻️  Restarting ${APP_NAME} ---"
    if [ ! -f "$SERVICE_FILE" ]; then
        echo "❌ Service '${UNIT}' is not installed."
        echo "   Run 'systemd-compose <project> up' first to build and install it."
        exit 1
    fi

    systemctl --user reset-failed "${UNIT}.service" 2>/dev/null

    if systemctl --user restart "${UNIT}.service" && wait_for_startup; then
        echo "✅ Restarted successfully."
        status
    else
        echo "❌ Restart Failed."
        show_recent_logs 10
        exit 1
    fi
}

status() {
    echo "--- 📊 Status: ${APP_NAME} ---"
    IS_ACTIVE=$(systemctl --user is-active "${UNIT}.service" 2>/dev/null)

    echo "Service State:  $IS_ACTIVE"
    if [ "$IS_ACTIVE" == "active" ]; then
        MAIN_PID=$(systemctl --user show --property MainPID --value "${UNIT}.service")
        echo "Main PID:       $MAIN_PID"
        echo "Memory Usage:   $(service_memory)"
        echo "Restarts:       $(systemctl --user show --property NRestarts --value "${UNIT}.service")"
    fi

    if [ "$REQUIRE_PORT" == "false" ]; then
        echo "Port:           N/A (Background Service)"
    elif [ -n "$PORT" ]; then
        if port_listening "$PORT"; then
            echo "Port $PORT:      ✅ Listening"
        else
            echo "Port $PORT:      ❌ Not Listening"
        fi
    fi
    echo ""
    journalctl --user -u "${UNIT}.service" -n 3 --no-pager
}

up() {
    echo "=== UP: ${APP_NAME} ==="
    build
    run
}

down() {
    echo "=== DOWN: ${APP_NAME} ==="
    stop
    systemctl --user disable --quiet "${UNIT}.service" 2>/dev/null
    rm -f "$SERVICE_FILE"
    systemctl --user daemon-reload
    systemctl --user reset-failed "${UNIT}.service" 2>/dev/null
    if [ -d "$INSTALL_DIR/venv" ]; then
        echo "Removing venv..."
        rm -rf "$INSTALL_DIR/venv"
    fi
    echo "Cleanup complete."
}

logs() {
    journalctl --user -u "${UNIT}.service" -f
}

# --- GLOBAL DASHBOARD COMMANDS ---

# Prints "NAME|WORKING_DIR|REQUIRE_PORT|PORT" for a project folder,
# loading its config in a subshell so nothing leaks between projects.
project_summary() {
    (
        APP_NAME="" APP_DIR="" REQUIRE_PORT="" PORT=""
        load_project_config "$1" >/dev/null 2>&1
        echo "${APP_NAME}|$1/${APP_DIR}|${REQUIRE_PORT}|${PORT}"
    )
}

# Prints each project folder under APPS_ROOT that has a config.env
list_projects() {
    if [ ! -d "$APPS_ROOT" ]; then
        die "APPS_ROOT directory '$APPS_ROOT' does not exist."
    fi
    local proj
    for proj in "$APPS_ROOT"/*/; do
        proj="${proj%/}"
        if [ -f "$proj/config.env" ]; then
            echo "$proj"
        fi
    done
}

stop_all() {
    echo "--- 🛑 Stopping ALL Managed Services ---"
    local projects proj name count=0
    projects=$(list_projects) || exit 1

    while IFS= read -r proj; do
        [ -n "$proj" ] || continue
        IFS='|' read -r name _ _ _ <<< "$(project_summary "$proj")"
        if ! valid_app_name "$name"; then
            printf "Skipping %-25s ... (Invalid APP_NAME)\n" "$(basename "$proj")"
        elif [ -f "$SYSTEMD_DIR/${name}.service" ]; then
            printf "Stopping %-25s ... " "$name"
            if systemctl --user stop "${name}.service"; then
                echo "✅ Done"
            else
                echo "❌ Failed"
            fi
        else
            printf "Skipping %-25s ... (Not installed)\n" "$name"
        fi
        count=$((count + 1))
    done <<< "$projects"
    echo "--- Processed $count apps ---"
}

start_all() {
    echo "--- 🚀 Starting ALL Managed Services ---"
    local projects proj name
    projects=$(list_projects) || exit 1

    while IFS= read -r proj; do
        [ -n "$proj" ] || continue
        IFS='|' read -r name _ _ _ <<< "$(project_summary "$proj")"
        if valid_app_name "$name" && [ -f "$SYSTEMD_DIR/${name}.service" ]; then
            printf "Starting %-25s ... " "$name"
            systemctl --user reset-failed "${name}.service" 2>/dev/null
            if systemctl --user start "${name}.service"; then
                echo "✅ Triggered"
            else
                echo "❌ Failed"
            fi
        else
            printf "Skipping %-25s ... (Not installed)\n" "${name:-$(basename "$proj")}"
        fi
    done <<< "$projects"
}

ps_dashboard() {
    echo "-----------------------------------------------------------------------------------------"
    printf "%-25s %-12s %-10s %-8s %-20s\n" "PROJECT ID" "STATUS" "PID" "PORT" "UPTIME"
    echo "-----------------------------------------------------------------------------------------"

    local projects proj name workdir req_port port_val raw_status display_status pid uptime
    local running_dir real_running real_current
    projects=$(list_projects) || exit 1

    while IFS= read -r proj; do
        [ -n "$proj" ] || continue
        IFS='|' read -r name workdir req_port port_val <<< "$(project_summary "$proj")"

        pid="-"
        uptime="-"

        if ! valid_app_name "$name"; then
            name="$(basename "$proj")"
            display_status="BAD-CONFIG"
        elif [ ! -f "$SYSTEMD_DIR/${name}.service" ]; then
            display_status="UNREGISTERED"
        else
            # is-active prints the state and exits non-zero for anything but
            # "active"; we only want the printed state.
            raw_status=$(systemctl --user is-active "${name}.service" 2>/dev/null)
            case "$raw_status" in
                active)     display_status="RUNNING" ;;
                inactive)   display_status="STOPPED" ;;
                failed)     display_status="CRASHED" ;;
                activating)
                    if [ "$(systemctl --user show --property SubState --value "${name}.service")" == "auto-restart" ]; then
                        display_status="RESTARTING"
                    else
                        display_status="STARTING"
                    fi
                    ;;
                *)          display_status="${raw_status:-unknown}" ;;
            esac
        fi

        # Detect a service with this name that runs from another folder
        if [ "$display_status" == "RUNNING" ]; then
            running_dir=$(systemctl --user show --property WorkingDirectory --value "${name}.service")
            real_running=$(realpath "$running_dir" 2>/dev/null || echo "$running_dir")
            real_current=$(realpath "$workdir" 2>/dev/null || echo "$workdir")

            if [ "$real_running" != "$real_current" ]; then
                display_status="CONFLICT"
            else
                pid=$(systemctl --user show --property MainPID --value "${name}.service")
                uptime=$(ps -p "$pid" -o etime= 2>/dev/null | xargs)
            fi
        fi

        if [ "$req_port" == "false" ]; then
            port_val="N/A"
        fi

        printf "%-25s %-12s %-10s %-8s %-20s\n" "$name" "$display_status" "$pid" "${port_val:--}" "${uptime:--}"
    done <<< "$projects"
    echo "-----------------------------------------------------------------------------------------"
}

# --- DISPATCHER ---

# Every project command acts on the service named APP_NAME, so make sure
# that name is not owned by a different project folder first.
if [ -n "${SERVICE_FILE:-}" ]; then
    if ! check_name_collision; then exit 1; fi
fi

case "$COMMAND" in
    up)        up ;;
    down)      down ;;
    build)     build ;;
    run|start) run ;;
    stop)      stop ;;
    restart)   restart ;;
    status)    status ;;
    logs)      logs ;;
    ps)        ps_dashboard ;;
    stop-all)  stop_all ;;
    start-all) start_all ;;
    *)
        echo "Unknown command: $COMMAND"
        usage
        exit 1
        ;;
esac
