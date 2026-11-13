#!/bin/bash

set -uo pipefail

# --- GLOBAL CONFIGURATION LOADING ---
SCRIPT_DIR="$(dirname "$(realpath "$0")")"
TEMPLATE_FILE="$SCRIPT_DIR/templates/service.unit"
SYSTEMD_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"

# Every service systemd-compose creates is named "sdc-<APP_NAME>.service".
# The prefix keeps apps from clashing with other user services and lets
# ps/stop-all/start-all find them without scanning project folders.
UNIT_PREFIX="sdc-"

# Default to system python if not specified in project config.env
PYTHON_BIN="${PYTHON_BIN:-python3}"

# Keys a project .env may not set inside systemd-compose itself
# (they would change how this script runs, not just the app).
RESERVED_ENV_KEYS=" sdc_env_pair sdc_env_key sdc_env_values PATH HOME USER SHELL IFS PWD OLDPWD UID EUID PPID SHLVL SCRIPT_DIR TEMPLATE_FILE SYSTEMD_DIR UNIT_PREFIX PROJECT_DIR INSTALL_DIR SERVICE_FILE UNIT COMMAND "

# --- HELPER FUNCTIONS ---

PROJECT_COMMANDS=" up down build run start adopt stop restart status logs exec config "
GLOBAL_COMMANDS=" ps stop-all start-all "

usage() {
    echo "Usage:"
    echo "  systemd-compose [project_folder] <command> [options]"
    echo ""
    echo "Project commands (project_folder defaults to the current folder):"
    echo "  up                 Build the venv, then install and start the app"
    echo "  build              Create the venv and install requirements.txt"
    echo "  run                Write the service file and (re)start the app"
    echo "  adopt              Reinstall an orphaned unit from a moved project"
    echo "  restart            Restart the app with the existing service file"
    echo "  stop               Stop the app"
    echo "  down [--volumes]   Stop and remove the service (--volumes also deletes the venv)"
    echo "  status             Show state, PID, memory, restarts and port"
    echo "  logs [options]     Follow the logs, or pass journalctl options (e.g. -n 100)"
    echo "  exec <cmd> [args]  Run a command with the app's venv and .env (e.g. exec python manage.py migrate)"
    echo "  config             Print the service file that 'run' would write"
    echo ""
    echo "Global commands:"
    echo "  ps                 List all installed apps"
    echo "  stop-all           Stop all installed apps"
    echo "  start-all          Start all installed apps"
}

die() {
    echo "❌ Error: $*" >&2
    exit 1
}

# Read the supported single-line subset of systemd's EnvironmentFile syntax.
# Reject values that systemd would interpret differently from the CLI.
parse_env_file() {
    local file="$1" line key value lineno=0
    local single_quoted="^'([^']*)'$" double_quoted='^"([^"\\]*)"$'
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
        case "$value" in
            \'*)
                if [[ "$value" =~ $single_quoted ]]; then
                    value="${BASH_REMATCH[1]}"
                else
                    echo "❌ $file:$lineno: Expected a single-line, single-quoted value." >&2
                    return 1
                fi
                ;;
            \"*)
                if [[ "$value" =~ $double_quoted ]]; then
                    value="${BASH_REMATCH[1]}"
                else
                    echo "❌ $file:$lineno: Expected a single-line, double-quoted value without escapes." >&2
                    return 1
                fi
                ;;
            *\\*)
                echo "❌ $file:$lineno: Put literal backslashes inside single quotes." >&2
                return 1
                ;;
        esac
        printf '%s=%s\n' "$key" "$value"
    done < "$file"
}

# Turns each key in a .env file into a (non-exported) shell variable, so
# config.env can use e.g. $PORT.
load_env_file() {
    local sdc_env_pair sdc_env_key sdc_env_values
    sdc_env_values=$(parse_env_file "$1") || die "Cannot read project environment."
    [ -n "$sdc_env_values" ] || return 0
    while IFS= read -r sdc_env_pair; do
        sdc_env_key="${sdc_env_pair%%=*}"
        if [[ "$RESERVED_ENV_KEYS" == *" $sdc_env_key "* || "$sdc_env_key" == BASH* ]]; then
            echo "⚠️  $1: '$sdc_env_key' is reserved; systemd-compose will not read it." >&2
            continue
        fi
        printf -v "$sdc_env_key" '%s' "${sdc_env_pair#*=}"
    done <<< "$sdc_env_values"
}

# Loads a project's .env and config.env into the current shell.
# Call it in a subshell when looping over several projects.
load_project_config() {
    INSTALL_DIR="$1"
    if [ -f "$1/.env" ]; then
        load_env_file "$1/.env"
    fi
    set +u
    # shellcheck source=/dev/null
    source "$1/config.env"
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
    MEMORY_MAX="${MEMORY_MAX:-}"
    CPU_QUOTA="${CPU_QUOTA:-}"
    if ! [[ "$STARTUP_TIMEOUT" =~ ^[1-9][0-9]{0,8}$ ]]; then
        STARTUP_TIMEOUT=15
    fi
}

# Reads an "X-SDC-<key>=" line that render_unit wrote into a service file.
# systemd ignores X- keys; systemd-compose uses them to map services to projects.
unit_meta() {
    local value
    value=$(grep -m1 "^X-SDC-$2=" "$1" 2>/dev/null | cut -d '=' -f 2-)
    echo "${value//%%/%}"
}

valid_app_name() {
    [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]]
}

# Return 0 for a listener, 1 for no listener, and 2 when ss failed.
port_listening() {
    local sockets
    sockets=$(ss -H -ltn "sport = :$1") || return 2
    [ -n "$sockets" ]
}

service_listening() {
    local cgroup sockets remaining pid path
    local -a paths
    cgroup=$(systemctl --user show --property ControlGroup --value "${UNIT}.service") || return 2
    [ -n "$cgroup" ] || return 1
    sockets=$(ss -H -ltnp "sport = :$1") || return 2
    remaining="$sockets"
    while [[ "$remaining" =~ pid=([0-9]+), ]]; do
        pid="${BASH_REMATCH[1]}"
        remaining="${remaining#*"${BASH_REMATCH[0]}"}"
        if mapfile -t paths 2>/dev/null < "/proc/$pid/cgroup"; then
            for path in "${paths[@]}"; do
                path="${path#*:*:}"
                if [[ "$path" == "$cgroup" || "$path" == "${cgroup%/}/"* ]]; then
                    return 0
                fi
            done
        fi
    done
    return 1
}

installed_port() {
    PORT=$(unit_meta "$SERVICE_FILE" Port)
    REQUIRE_PORT=false
    if [ -n "$PORT" ]; then REQUIRE_PORT=true; fi
}

# --- ARGUMENT PARSING ---

# Accepts "systemd-compose <command>" (current folder) as well as
# "systemd-compose <project_folder> <command>". Anything after the command
# is kept in EXTRA_ARGS for commands that take options (logs, down).
PROJECT_DIR_ARG=""
case "${1:-}" in
    "")
        usage
        exit 1
        ;;
    -h|--help|help)
        usage
        exit 0
        ;;
    *)
        if [[ "$GLOBAL_COMMANDS" == *" $1 "* ]]; then
            COMMAND="$1"
            shift
        elif [[ "$PROJECT_COMMANDS" == *" $1 "* ]]; then
            PROJECT_DIR_ARG="."
            COMMAND="$1"
            shift
        elif [ -n "${2:-}" ]; then
            PROJECT_DIR_ARG="$1"
            COMMAND="$2"
            shift 2
        elif [ -d "$1" ]; then
            usage
            exit 1
        else
            echo "Unknown command: $1"
            usage
            exit 1
        fi
        ;;
esac
EXTRA_ARGS=("$@")

# Only these commands take options; catch typos like "stop --all"
case "$COMMAND" in
    logs|down|exec) ;;
    *)
        if [ ${#EXTRA_ARGS[@]} -gt 0 ]; then
            die "'$COMMAND' does not take extra arguments: ${EXTRA_ARGS[*]}"
        fi
        ;;
esac

# --- PROJECT CONTEXT LOADING ---

if [ -n "$PROJECT_DIR_ARG" ]; then
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

    UNIT="${UNIT_PREFIX}${APP_NAME}"
    SERVICE_FILE="$SYSTEMD_DIR/${UNIT}.service"
fi

managed_service_file() {
    local file="$1" project
    [ -f "$file" ] && [ ! -L "$file" ] || return 1
    project=$(unit_meta "$file" Project)
    [[ "$project" == /* ]]
}

check_name_collision() {
    local existing
    if [ ! -e "$SERVICE_FILE" ] && [ ! -L "$SERVICE_FILE" ]; then
        if [ "$COMMAND" == "adopt" ]; then
            die "No orphaned service file to adopt for '$APP_NAME'."
        fi
        return 0
    fi

    if ! managed_service_file "$SERVICE_FILE"; then
        die "'$SERVICE_FILE' is not a managed unit. Choose a different APP_NAME."
    fi
    existing=$(unit_meta "$SERVICE_FILE" Project)
    if [ "$existing" == "$PROJECT_DIR" ]; then
        if [ "$COMMAND" == "adopt" ]; then
            die "This project already owns '$APP_NAME'. Use 'run'."
        fi
        return 0
    fi
    if [ -d "$existing" ]; then
        die "Name Conflict! '$APP_NAME' is already owned by '$existing'. Choose a different APP_NAME."
    fi
    if [ "$COMMAND" != "adopt" ]; then
        die "'$APP_NAME' belongs to the missing project '$existing'. If you moved it here, use 'adopt'."
    fi
    echo "Adopting '$APP_NAME' from '$existing'."
}

warn_config_exports() {
    if grep -qE '^[[:space:]]*export[[:space:]]' "$PROJECT_DIR/config.env"; then
        echo "⚠️  config.env contains 'export' lines. Those are NOT passed to your app;"
        echo "   put variables your app needs in $PROJECT_DIR/.env instead."
    fi
}

validate_port() {
    case "$REQUIRE_PORT" in
        false) PORT=""; return 0 ;;
        true) ;;
        *) die "REQUIRE_PORT must be true or false." ;;
    esac

    if [ -z "$PORT" ]; then
        echo "❌ Error: REQUIRE_PORT=true, but 'PORT' variable is missing in .env."
        return 1
    fi

    if [[ "$PORT" =~ ^0*([1-9][0-9]{0,4})$ ]] && [ "${BASH_REMATCH[1]}" -le 65535 ]; then
        PORT="${BASH_REMATCH[1]}"
        return 0
    fi
    echo "❌ Error: PORT='$PORT' is not a valid port number."
    return 1
}

check_port() {
    [ "$REQUIRE_PORT" == false ] && return 0
    local result=0
    port_listening "$PORT" || result=$?
    case "$result" in
        0)
            echo "❌ Error: Port $PORT is already in use."
            lsof -nP -iTCP:"$PORT" -sTCP:LISTEN 2>/dev/null || :
            return 1
            ;;
        2)
            echo "❌ Error: Could not inspect TCP port $PORT." >&2
            return 1
            ;;
    esac
    echo "✅ Port $PORT is free."
}

check_binary() {
    if [ -z "$ENTRYPOINT" ]; then
        echo "❌ Error: ENTRYPOINT is not set in config.env (e.g. ENTRYPOINT=\"python\")."
        return 1
    fi
    local binary_path="$1/bin/$ENTRYPOINT"
    if [ ! -f "$binary_path" ] || [ ! -x "$binary_path" ]; then
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
    # Only record a port in the service file when the app is meant to use one
    local PORT="$PORT"
    if [ "$REQUIRE_PORT" == "false" ]; then
        PORT=""
    fi

    for var in DESCRIPTION INSTALL_DIR ENTRYPOINT APP_DIR ARGS; do
        if [[ "${!var}" == *$'\n'* ]]; then
            die "$var in config.env must be a single line."
        fi
    done
    if [[ "$INSTALL_DIR" == *[\"\\]* ]]; then
        die "The project path can't contain '\"' or '\\': $INSTALL_DIR"
    fi
    if [ -n "$MEMORY_MAX" ] && ! [[ "$MEMORY_MAX" =~ ^[1-9][0-9]*[KMGT%]?$|^infinity$ ]]; then
        die "MEMORY_MAX='$MEMORY_MAX' is invalid. Use a size like 300M or 1G, a percentage like 25%, or leave it empty."
    fi
    if [ -n "$CPU_QUOTA" ] && ! [[ "$CPU_QUOTA" =~ ^[1-9][0-9]*%$ ]]; then
        die "CPU_QUOTA='$CPU_QUOTA' is invalid. Use a percentage of one core, like 50% (or 200% for two cores)."
    fi

    [ -r "$TEMPLATE_FILE" ] || die "Cannot read '$TEMPLATE_FILE'."
    while IFS= read -r line || [ -n "$line" ]; do
        key="${line%%=*}"
        for var in DESCRIPTION INSTALL_DIR ENTRYPOINT APP_DIR ARGS PORT MEMORY_MAX CPU_QUOTA; do
            value="${!var}"
            # MemoryMax=/CPUQuota= take "%" literally (no specifiers); their
            # values are validated above, so they are written as-is.
            if [[ "$var" != "MEMORY_MAX" && "$var" != "CPU_QUOTA" ]]; then
                value="${value//%/%%}"
            fi
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
    local elapsed=0 state restarts result
    local min_wait=3
    while true; do
        sleep 1
        elapsed=$((elapsed + 1))
        state=$(systemctl --user show --property ActiveState --value "${UNIT}.service") || return 1
        restarts=$(systemctl --user show --property NRestarts --value "${UNIT}.service") || return 1
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
        else
            result=0
            service_listening "$PORT" || result=$?
            if [ "$result" == 0 ]; then return 0; fi
            if [ "$result" == 2 ]; then
                echo "❌ Could not inspect the service's TCP listener." >&2
                return 1
            fi
            if [ "$elapsed" -ge "$STARTUP_TIMEOUT" ]; then
                echo "❌ The app is running but not listening on port $PORT after ${STARTUP_TIMEOUT}s."
                echo "   Check the app binds to this TCP port and exposes a listener PID, or raise STARTUP_TIMEOUT."
                return 1
            fi
        fi
    done
}

# Limits only work when the kernel lets the user manager control memory/CPU
# (cgroup v2 with the controllers delegated). Warn instead of failing silently.
warn_unenforced_limits() {
    local uid controllers_file controllers
    uid=$(id -u)
    controllers_file="/sys/fs/cgroup/user.slice/user-${uid}.slice/user@${uid}.service/cgroup.controllers"
    if [ ! -r "$controllers_file" ]; then
        if [ -n "$MEMORY_MAX$CPU_QUOTA" ]; then
            echo "⚠️  Could not verify cgroup v2 controller availability for user services."
        fi
        return 0
    fi
    controllers=" $(cat "$controllers_file") "
    if [ -n "$MEMORY_MAX" ] && [[ "$controllers" != *" memory "* ]]; then
        echo "⚠️  MEMORY_MAX is set, but the memory controller isn't available to user services, so it won't be enforced."
    fi
    if [ -n "$CPU_QUOTA" ] && [[ "$controllers" != *" cpu "* ]]; then
        echo "⚠️  CPU_QUOTA is set, but the cpu controller isn't available to user services, so it won't be enforced."
    fi
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
    local venv="${1:-$INSTALL_DIR/venv}"
    echo "--- 🏗️ Building ${APP_NAME} ---"

    if ! "$PYTHON_BIN" -c "import venv" 2>/dev/null; then
        die "'$PYTHON_BIN' is missing the 'venv' module. Run ./host-setup.sh"
    fi

    if [ ! -d "$venv" ]; then
        echo "Creating Python venv..."
        if ! "$PYTHON_BIN" -m venv "$venv"; then
            rm -rf "$venv"
            die "Failed to create the venv."
        fi
        if [ ! -f "$venv/bin/pip" ]; then
            echo "⚠️  Pip missing. Bootstrapping..."
            "$venv/bin/python" -m ensurepip --upgrade || die "Failed to bootstrap pip."
        fi
    fi

    echo "Installing dependencies..."
    if [ -f "$INSTALL_DIR/requirements.txt" ]; then
        if ! (cd "$INSTALL_DIR" &&
            "$venv/bin/pip" install -r requirements.txt --quiet --disable-pip-version-check); then
            die "Dependency installation failed (see pip output above)."
        fi
    else
        echo "⚠️  No requirements.txt found."
    fi
    echo "Build Complete."
}

# A fresh venv must stay at the path where Python created it: pip's entry
# point scripts have absolute shebangs. Only the stable venv symlink moves.
remove_old_venv() {
    local saved="$1" target
    if [ -L "$saved" ]; then
        target=$(readlink -- "$saved") || return 1
        if [[ "$target" != /* ]]; then target="$INSTALL_DIR/$target"; fi
        if [[ "$target" == "$INSTALL_DIR"/.sdc-venv.* && "${target#"$INSTALL_DIR/"}" != */* ]]; then
            rm -rf -- "$target" || return 1
        fi
    fi
    rm -rf -- "$saved"
}

rollback_deployment() {
    local result=$? restored=1
    if [ "$committed" == 0 ] && [ "$changed" == 1 ]; then
        echo "Restoring the previous deployment." >&2
        if [ "$start_attempted" == 1 ]; then
            systemctl --user stop "${UNIT}.service" || restored=0
        fi
        if [ "$enable_attempted" == 1 ] && [ "$was_enabled" != enabled ]; then
            systemctl --user disable --quiet "${UNIT}.service" || restored=0
        fi
        if [ "$unit_replaced" == 1 ]; then
            if [ -f "$scratch/previous.service" ]; then
                mv -fT -- "$scratch/previous.service" "$SERVICE_FILE" || restored=0
            else
                rm -f -- "$SERVICE_FILE" || restored=0
            fi
            systemctl --user daemon-reload || restored=0
        fi
        if [ "$venv_linked" == 1 ]; then
            rm -f -- "$INSTALL_DIR/venv" || restored=0
        fi
        if [ -e "$venv_backup/venv" ] || [ -L "$venv_backup/venv" ]; then
            mv -T -- "$venv_backup/venv" "$INSTALL_DIR/venv" || restored=0
        fi
        if [ "$resume_previous" == 1 ]; then
            systemctl --user reset-failed "${UNIT}.service" 2>/dev/null || :
            systemctl --user start "${UNIT}.service" || restored=0
        fi
    fi
    if [ "$restored" == 0 ]; then
        echo "❌ Rollback was incomplete. Inspect systemctl --user and backups at '$scratch' and '${venv_backup:-none}'." >&2
        return 1
    fi
    if [ -n "$scratch" ]; then rm -rf -- "$scratch"; fi
    if [ -n "$venv_backup" ]; then
        if ! remove_old_venv "$venv_backup/venv" || ! rmdir -- "$venv_backup"; then
            echo "⚠️  Could not clean up '$venv_backup'." >&2
        fi
    fi
    if [ "$committed" == 0 ] && [ -n "$staged_venv" ]; then rm -rf -- "$staged_venv"; fi
    return "$result"
}

run() (
    local action="${1:-run}" unit_content verification previous_state
    local scratch="" staged_venv="" venv_backup=""
    local committed=0 changed=0 resume_previous=0 unit_replaced=0
    local start_attempted=0 enable_attempted=0 venv_linked=0 was_enabled=""
    trap rollback_deployment EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM

    echo "--- 🚀 Starting ${APP_NAME} ---"
    warn_config_exports
    warn_unenforced_limits
    validate_port || exit 1
    unit_content=$(render_unit) || exit 1

    # Check a port change before stopping the previous service. For an
    # unchanged port, the previous instance may still own the listener.
    if [ ! -f "$SERVICE_FILE" ] || [ "$(unit_meta "$SERVICE_FILE" Port)" != "$PORT" ]; then
        check_port || exit 1
    fi

    scratch=$(mktemp -d "$SYSTEMD_DIR/.sdc-deploy.XXXXXX") || die "Cannot stage the service file."
    printf '%s\n' "$unit_content" > "$scratch/${UNIT}.service" || die "Cannot write the staged service file."
    if [ -f "$SERVICE_FILE" ]; then
        cp -p -- "$SERVICE_FILE" "$scratch/previous.service" || die "Cannot save the previous unit."
        previous_state=$(systemctl --user show --property ActiveState --value "${UNIT}.service") ||
            die "Cannot read the current service state."
        case "$previous_state" in
            active|activating|reloading) resume_previous=1 ;;
        esac
        was_enabled=$(systemctl --user is-enabled "${UNIT}.service" 2>/dev/null) || :
    fi

    if [ "$action" == up ]; then
        if [ -f "$SERVICE_FILE" ] && [ -f "$INSTALL_DIR/requirements.txt" ]; then
            staged_venv=$(mktemp -d "$INSTALL_DIR/.sdc-venv.XXXXXX") || die "Cannot stage a venv."
            rmdir -- "$staged_venv" || die "Cannot prepare the venv directory."
            build "$staged_venv"
        else
            build
        fi
    fi
    check_binary "${staged_venv:-$INSTALL_DIR/venv}" || exit 1

    # Verify the exact unit syntax, using the staged executable when the
    # stable venv path will only be switched during deployment.
    if [ -n "$staged_venv" ]; then
        mkdir "$scratch/verify" || die "Cannot stage unit verification."
        (
            INSTALL_DIR_ESCAPED="${INSTALL_DIR//%/%%}"
            INSTALL_DIR_ESCAPED="${INSTALL_DIR_ESCAPED//\$/\$\$}"
            staged_path="${staged_venv//%/%%}"
            staged_path="${staged_path//\$/\$\$}"
            while IFS= read -r line; do
                if [[ "$line" == ExecStart=* ]]; then
                    line="${line/"$INSTALL_DIR_ESCAPED/venv/bin/"/"$staged_path/bin/"}"
                fi
                printf '%s\n' "$line"
            done < "$scratch/${UNIT}.service"
        ) > "$scratch/verify/${UNIT}.service" || die "Cannot write verification unit."
    fi
    local verify_path="$scratch/${UNIT}.service"
    if [ -n "$staged_venv" ]; then verify_path="$scratch/verify/${UNIT}.service"; fi
    verification=$(systemd-analyze verify "$verify_path" 2>&1) || {
        printf '%s\n' "$verification" >&2
        die "Generated service did not pass systemd verification."
    }
    if [[ "$verification" == *"$verify_path:"* ]]; then
        printf '%s\n' "$verification" >&2
        die "Generated service has systemd configuration errors."
    fi

    if [ -f "$SERVICE_FILE" ]; then
        systemctl --user stop "${UNIT}.service" || die "Cannot stop the previous service."
        changed=1
        check_port || exit 1
    fi

    if [ -n "$staged_venv" ]; then
        venv_backup=$(mktemp -d "$INSTALL_DIR/.sdc-backup.XXXXXX") || die "Cannot stage the venv switch."
        if [ -e "$INSTALL_DIR/venv" ] || [ -L "$INSTALL_DIR/venv" ]; then
            mv -T -- "$INSTALL_DIR/venv" "$venv_backup/venv" || die "Cannot save the previous venv."
        fi
        ln -s -- "${staged_venv##*/}" "$INSTALL_DIR/venv" || die "Cannot switch to the staged venv."
        venv_linked=1
    fi

    mv -fT -- "$scratch/${UNIT}.service" "$SERVICE_FILE" || die "Cannot install the staged unit."
    changed=1
    unit_replaced=1
    systemctl --user daemon-reload || die "Cannot reload the user manager."
    systemctl --user reset-failed "${UNIT}.service" 2>/dev/null || :

    start_attempted=1
    if ! systemctl --user start "${UNIT}.service"; then
        echo "❌ Fatal: Systemd failed to start the service." >&2
        show_recent_logs 10 || :
        exit 1
    fi
    if ! wait_for_startup; then
        show_recent_logs 15 || :
        exit 1
    fi
    if [ "$was_enabled" != enabled ]; then
        enable_attempted=1
        systemctl --user enable --quiet "${UNIT}.service" || die "Cannot enable boot startup."
    fi

    committed=1
    echo "✅ Service started."
    status || echo "⚠️  The service started, but its status could not be displayed." >&2
)

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

    installed_port
    validate_port || return 1
    systemctl --user reset-failed "${UNIT}.service" 2>/dev/null || :

    if systemctl --user restart "${UNIT}.service" && wait_for_startup; then
        echo "✅ Restarted successfully."
        status || echo "⚠️  The service restarted, but its status could not be displayed." >&2
    else
        echo "❌ Restart Failed."
        show_recent_logs 10
        exit 1
    fi
}

status() {
    local PORT="" REQUIRE_PORT=false memory_limit=""
    if [ -f "$SERVICE_FILE" ]; then
        installed_port
        validate_port || return 1
        memory_limit=$(sed -n 's/^MemoryMax=//p' "$SERVICE_FILE")
    fi
    echo "--- 📊 Status: ${APP_NAME} ---"
    local IS_ACTIVE
    IS_ACTIVE=$(systemctl --user is-active "${UNIT}.service") || :
    if [ -z "$IS_ACTIVE" ]; then
        echo "❌ Could not query service state." >&2
        return 1
    fi

    echo "Service State:  $IS_ACTIVE"
    if [ "$IS_ACTIVE" == "active" ]; then
        MAIN_PID=$(systemctl --user show --property MainPID --value "${UNIT}.service")
        echo "Main PID:       $MAIN_PID"
        echo "Memory Usage:   $(service_memory)${memory_limit:+ (limit $memory_limit)}"
        echo "Restarts:       $(systemctl --user show --property NRestarts --value "${UNIT}.service")"
    fi

    if [ "$REQUIRE_PORT" == "false" ]; then
        echo "Port:           N/A (Background Service)"
    elif [ -n "$PORT" ]; then
        if service_listening "$PORT"; then
            echo "Port $PORT:      ✅ Listening"
        else
            echo "Port $PORT:      ❌ Not Listening"
        fi
    fi
    echo ""
    if ! journalctl --user -u "${UNIT}.service" -n 3 --no-pager; then
        echo "⚠️  Could not read recent journal entries." >&2
    fi
}

up() {
    echo "=== UP: ${APP_NAME} ==="
    run up
}

down() {
    local remove_venv=0 arg
    for arg in "${EXTRA_ARGS[@]}"; do
        case "$arg" in
            -v|--volumes) remove_venv=1 ;;
            *) die "Unknown option for down: $arg (did you mean --volumes?)" ;;
        esac
    done

    echo "=== DOWN: ${APP_NAME} ==="
    stop
    if [ -f "$SERVICE_FILE" ]; then
        systemctl --user disable --quiet "${UNIT}.service" || die "Could not disable ${UNIT}."
        rm -f -- "$SERVICE_FILE" || die "Could not remove the unit file."
        systemctl --user daemon-reload || die "Unit file removed, but the user manager could not reload."
        systemctl --user reset-failed "${UNIT}.service" 2>/dev/null || :
    fi
    if [ "$remove_venv" == 1 ] && { [ -d "$INSTALL_DIR/venv" ] || [ -L "$INSTALL_DIR/venv" ]; }; then
        echo "Removing venv..."
        remove_old_venv "$INSTALL_DIR/venv" || die "Could not remove the venv."
    fi
    echo "Cleanup complete."
}

# With no options, follow the logs. Otherwise pass the options to journalctl,
# e.g. "logs -n 100" or "logs --since today -f".
logs() {
    if [ ${#EXTRA_ARGS[@]} -eq 0 ]; then
        EXTRA_ARGS=(-f)
    fi
    journalctl --user -u "${UNIT}.service" "${EXTRA_ARGS[@]}"
}

# Runs a one-off command the way the service runs the app: venv first on
# PATH, the variables from .env, in the app's working directory.
exec_command() {
    if [ ${#EXTRA_ARGS[@]} -eq 0 ]; then
        die "Usage: systemd-compose [project_folder] exec <command> [args...]"
    fi
    if [ ! -d "$INSTALL_DIR/venv" ]; then
        die "No venv in $INSTALL_DIR. Run 'build' first."
    fi

    local -a env_vars=()
    local values
    if [ -f "$INSTALL_DIR/.env" ]; then
        values=$(parse_env_file "$INSTALL_DIR/.env" 2>/dev/null) || die "Cannot read project environment."
        if [ -n "$values" ]; then mapfile -t env_vars <<< "$values"; fi
    fi

    cd "$INSTALL_DIR/$APP_DIR" || die "Can't enter $INSTALL_DIR/$APP_DIR"
    # Same order as the service: .env comes last, so it wins (as in systemd)
    exec env -- \
        "PATH=$INSTALL_DIR/venv/bin:/usr/local/bin:/usr/bin:/bin" \
        "VIRTUAL_ENV=$INSTALL_DIR/venv" \
        PYTHONUNBUFFERED=1 \
        PYTHONDONTWRITEBYTECODE=1 \
        "${env_vars[@]}" \
        "${EXTRA_ARGS[@]}"
}

# Prints the service file "run" would write, and whether it differs from
# the installed one. Nothing is changed.
show_config() {
    local unit_content
    validate_port || return 1
    unit_content=$(render_unit) || exit 1
    echo "# $SERVICE_FILE"
    printf '%s\n' "$unit_content"
    echo ""
    if [ ! -f "$SERVICE_FILE" ]; then
        echo "# Not installed yet. Run 'up' or 'run' to install it."
    elif [ "$(cat "$SERVICE_FILE")" == "$unit_content" ]; then
        echo "# The installed service file is up to date."
    else
        echo "# The installed service file is different. Run 'run' to apply these changes."
    fi
}

# --- GLOBAL DASHBOARD COMMANDS ---

# Prints the path of every service file systemd-compose has installed
managed_service_files() {
    local file
    for file in "$SYSTEMD_DIR/${UNIT_PREFIX}"*.service; do
        if managed_service_file "$file"; then
            echo "$file"
        fi
    done
}

# "sdc-my-app.service" -> "sdc-my-app"
unit_from_file() {
    basename "$1" .service
}

stop_all() {
    echo "--- 🛑 Stopping ALL Managed Services ---"
    local file unit count=0 failed=0
    while IFS= read -r file; do
        [ -n "$file" ] || continue
        unit=$(unit_from_file "$file")
        printf "Stopping %-25s ... " "${unit#"$UNIT_PREFIX"}"
        # Always stop: an app in a crash loop is "activating", not "active".
        if systemctl --user stop "${unit}.service"; then
            echo "✅ Done"
        else
            echo "❌ Failed"
            failed=1
        fi
        count=$((count + 1))
    done <<< "$(managed_service_files)"
    echo "--- Processed $count apps ---"
    return "$failed"
}

start_all() {
    echo "--- 🚀 Starting ALL Managed Services ---"
    local file unit count=0 failed=0
    while IFS= read -r file; do
        [ -n "$file" ] || continue
        unit=$(unit_from_file "$file")
        printf "Starting %-25s ... " "${unit#"$UNIT_PREFIX"}"
        systemctl --user reset-failed "${unit}.service" 2>/dev/null
        if systemctl --user start "${unit}.service"; then
            echo "✅ Triggered"
        else
            echo "❌ Failed"
            failed=1
        fi
        count=$((count + 1))
    done <<< "$(managed_service_files)"
    echo "--- Processed $count apps ---"
    return "$failed"
}

ps_dashboard() {
    local line="--------------------------------------------------------------------------------------------"
    echo "$line"
    printf "%-25s %-12s %-8s %-6s %-12s %s\n" "APP NAME" "STATUS" "PID" "PORT" "UPTIME" "PROJECT"
    echo "$line"

    local file unit project port raw_status display_status pid uptime failed=0
    while IFS= read -r file; do
        [ -n "$file" ] || continue
        unit=$(unit_from_file "$file")
        project=$(unit_meta "$file" Project)
        port=$(unit_meta "$file" Port)
        pid="-"
        uptime="-"

        # is-active prints the state and exits non-zero for anything but
        # "active"; we only want the printed state.
        raw_status=$(systemctl --user is-active "${unit}.service") || :
        if [ -z "$raw_status" ]; then failed=1; fi
        case "$raw_status" in
            active)     display_status="RUNNING" ;;
            inactive)   display_status="STOPPED" ;;
            failed)     display_status="CRASHED" ;;
            activating)
                if [ "$(systemctl --user show --property SubState --value "${unit}.service")" == "auto-restart" ]; then
                    display_status="RESTARTING"
                else
                    display_status="STARTING"
                fi
                ;;
            *)          display_status="${raw_status:-unknown}" ;;
        esac

        if [ "$display_status" == "RUNNING" ]; then
            pid=$(systemctl --user show --property MainPID --value "${unit}.service")
            uptime=$(ps -p "$pid" -o etime= 2>/dev/null | xargs)
        fi

        if [ -z "$project" ]; then
            project="?"
        elif [ ! -d "$project" ]; then
            project="$project (missing)"
        fi
        project="${project/#"$HOME"/\~}"

        printf "%-25s %-12s %-8s %-6s %-12s %s\n" "${unit#"$UNIT_PREFIX"}" "$display_status" "$pid" "${port:--}" "${uptime:--}" "$project"
    done <<< "$(managed_service_files)"
    echo "$line"
    return "$failed"
}

# --- DISPATCHER ---

# Serialize mutations before inspecting ownership or changing files.
case "$COMMAND" in
    up|down|build|run|start|adopt|stop|restart|stop-all|start-all)
        mkdir -p "$SYSTEMD_DIR" || die "Cannot create '$SYSTEMD_DIR'."
        exec {mutation_lock}>"$SYSTEMD_DIR/.systemd-compose.lock" || die "Cannot open the management lock."
        flock -x "$mutation_lock" || die "Cannot acquire the management lock."
        ;;
esac

# Every command that manages the service acts on the service named APP_NAME,
# so make sure that name is not owned by a different project folder first.
# exec and config don't touch the service.
if [ -n "${SERVICE_FILE:-}" ] && [[ "$COMMAND" != "exec" && "$COMMAND" != "config" && "$COMMAND" != "build" ]]; then
    if ! check_name_collision; then exit 1; fi
fi

case "$COMMAND" in
    up)        up ;;
    down)      down ;;
    build)     build ;;
    run|start|adopt) run ;;
    stop)      stop ;;
    restart)   restart ;;
    status)    status ;;
    logs)      logs ;;
    exec)      exec_command ;;
    config)    show_config ;;
    ps)        ps_dashboard ;;
    stop-all)  stop_all ;;
    start-all) start_all ;;
    *)
        echo "Unknown command: $COMMAND"
        usage
        exit 1
        ;;
esac
