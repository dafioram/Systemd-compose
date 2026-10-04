# Shared setup for the bats tests.
# SDC/UNIT_DIR are used by the test files; $output is set by bats `run`.
# shellcheck disable=SC2034,SC2154
#
# Each test gets a throwaway HOME and fake systemctl/ss/journalctl/sleep
# (tests/stubs), so nothing touches the real systemd or your apps.

REPO_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
SDC="$REPO_DIR/systemd-compose.sh"

setup() {
    TEST_ROOT="$(mktemp -d)"
    export HOME="$TEST_ROOT/home"
    export STUB_STATE="$TEST_ROOT/state"
    export PATH="$REPO_DIR/tests/stubs:$PATH"
    mkdir -p "$HOME" "$STUB_STATE"
    UNIT_DIR="$HOME/.config/systemd/user"
    unset STUB_START_FAIL STUB_STATE_AFTER_START STUB_LISTEN STUB_NRESTARTS STUB_MEM STUB_SUBSTATE
}

teardown() {
    rm -rf "${TEST_ROOT:?}"
}

# make_app <dir> <APP_NAME> [REQUIRE_PORT] [PORT] [APP_DIR]
# Creates a project with a fake, already-built venv.
make_app() {
    local dir="$1" name="$2" require_port="${3:-true}" port="${4:-}" app_dir="${5:-.}"
    mkdir -p "$dir/$app_dir" "$dir/venv/bin"
    printf '#!/bin/sh\n' > "$dir/venv/bin/python"
    printf '#!/bin/sh\nexit 0\n' > "$dir/venv/bin/pip"
    chmod +x "$dir/venv/bin/python" "$dir/venv/bin/pip"
    cat > "$dir/config.env" <<EOF
APP_NAME="$name"
DESCRIPTION="test app"
APP_DIR="$app_dir"
ENTRYPOINT="python"
ARGS="\${INSTALL_DIR}/\${APP_DIR}/main.py"
REQUIRE_PORT="$require_port"
EOF
    if [ -n "$port" ]; then
        echo "PORT=$port" > "$dir/.env"
    fi
}

# Sets the stub state of an installed unit, e.g. unit_state sdc-web activating
unit_state() {
    mkdir -p "$STUB_STATE/units"
    echo "$2" > "$STUB_STATE/units/$1"
}

current_state() {
    cat "$STUB_STATE/units/$1" 2>/dev/null || echo inactive
}

# Fails the test with the command output when a substring is missing
assert_output_contains() {
    if [[ "$output" != *"$1"* ]]; then
        echo "expected output to contain: $1"
        echo "--- actual output:"
        echo "$output"
        return 1
    fi
}

refute_output_contains() {
    if [[ "$output" == *"$1"* ]]; then
        echo "expected output NOT to contain: $1"
        echo "--- actual output:"
        echo "$output"
        return 1
    fi
}
