#!/usr/bin/env bats
# Default project folder, help, logs/down options, exec, config, limits

# Single quotes below are intentional: "$VAR" must be expanded by the tool.
# shellcheck disable=SC2016

load test_helper

@test "the project folder defaults to the current folder" {
    make_app "$TEST_ROOT/app" app false
    cd "$TEST_ROOT/app"
    run bash "$SDC" up
    [ "$status" -eq 0 ]
    [ -f "$UNIT_DIR/sdc-app.service" ]
    run bash "$SDC" status
    [ "$status" -eq 0 ]
    assert_output_contains "Service State:  active"
}

@test "-h and --help print usage and succeed" {
    for flag in -h --help help; do
        run bash "$SDC" "$flag"
        [ "$status" -eq 0 ]
        assert_output_contains "Project commands"
    done
}

@test "a folder without a command prints usage and fails" {
    mkdir -p "$TEST_ROOT/app"
    run bash "$SDC" "$TEST_ROOT/app"
    [ "$status" -eq 1 ]
    assert_output_contains "Usage:"
}

@test "an unknown single word is an unknown command" {
    run bash "$SDC" frobnicate
    [ "$status" -eq 1 ]
    assert_output_contains "Unknown command: frobnicate"
}

@test "commands without options reject extra arguments" {
    make_app "$TEST_ROOT/app" app false
    run bash "$SDC" "$TEST_ROOT/app" stop --all
    [ "$status" -eq 1 ]
    assert_output_contains "does not take extra arguments"
    run bash "$SDC" ps extra
    [ "$status" -eq 1 ]
}

@test "logs follows by default" {
    make_app "$TEST_ROOT/app" app false
    run bash "$SDC" "$TEST_ROOT/app" logs
    [ "$status" -eq 0 ]
    assert_output_contains "[journal: --user -u sdc-app.service -f]"
}

@test "logs passes options to journalctl" {
    make_app "$TEST_ROOT/app" app false
    run bash "$SDC" "$TEST_ROOT/app" logs -n 100 --since today
    [ "$status" -eq 0 ]
    assert_output_contains "[journal: --user -u sdc-app.service -n 100 --since today]"
}

@test "down keeps the venv" {
    make_app "$TEST_ROOT/app" app false
    bash "$SDC" "$TEST_ROOT/app" run
    run bash "$SDC" "$TEST_ROOT/app" down
    [ "$status" -eq 0 ]
    [ ! -f "$UNIT_DIR/sdc-app.service" ]
    [ -d "$TEST_ROOT/app/venv" ]
}

@test "down --volumes also deletes the venv" {
    make_app "$TEST_ROOT/app" app false
    bash "$SDC" "$TEST_ROOT/app" run
    run bash "$SDC" "$TEST_ROOT/app" down --volumes
    [ "$status" -eq 0 ]
    [ ! -d "$TEST_ROOT/app/venv" ]
}

@test "down rejects unknown options without removing anything" {
    make_app "$TEST_ROOT/app" app false
    bash "$SDC" "$TEST_ROOT/app" run
    run bash "$SDC" "$TEST_ROOT/app" down --volume
    [ "$status" -eq 1 ]
    assert_output_contains "did you mean --volumes"
    [ -f "$UNIT_DIR/sdc-app.service" ]
}

@test "exec runs in the app folder with the venv and .env" {
    make_app "$TEST_ROOT/app" app false 8000 src
    printf 'SECRET="s3cret"\n' >> "$TEST_ROOT/app/.env"
    printf '#!/bin/sh\necho "tool: $*"\n' > "$TEST_ROOT/app/venv/bin/mytool"
    chmod +x "$TEST_ROOT/app/venv/bin/mytool"

    run bash "$SDC" "$TEST_ROOT/app" exec mytool migrate --yes
    [ "$status" -eq 0 ]
    assert_output_contains "tool: migrate --yes"

    run bash "$SDC" "$TEST_ROOT/app" exec sh -c 'echo "$PWD|$SECRET|$PORT|$VIRTUAL_ENV"'
    [ "$status" -eq 0 ]
    [ "$output" == "$TEST_ROOT/app/src|s3cret|8000|$TEST_ROOT/app/venv" ]
}

@test "exec returns the command's exit code" {
    make_app "$TEST_ROOT/app" app false
    run bash "$SDC" "$TEST_ROOT/app" exec sh -c 'exit 7'
    [ "$status" -eq 7 ]
}

@test "exec without a command or venv gives a clear error" {
    make_app "$TEST_ROOT/app" app false
    run bash "$SDC" "$TEST_ROOT/app" exec
    [ "$status" -eq 1 ]
    assert_output_contains "Usage: systemd-compose [project_folder] exec"

    rm -rf "$TEST_ROOT/app/venv"
    run bash "$SDC" "$TEST_ROOT/app" exec python
    [ "$status" -eq 1 ]
    assert_output_contains "Run 'build' first"
}

@test "config prints the service file without installing it" {
    make_app "$TEST_ROOT/app" app false
    run bash "$SDC" "$TEST_ROOT/app" config
    [ "$status" -eq 0 ]
    assert_output_contains "ExecStart="
    assert_output_contains "Not installed yet"
    [ ! -f "$UNIT_DIR/sdc-app.service" ]
}

@test "config says whether the installed service is up to date" {
    make_app "$TEST_ROOT/app" app false
    bash "$SDC" "$TEST_ROOT/app" run
    run bash "$SDC" "$TEST_ROOT/app" config
    assert_output_contains "up to date"

    sed -i 's/^DESCRIPTION=.*/DESCRIPTION="changed"/' "$TEST_ROOT/app/config.env"
    run bash "$SDC" "$TEST_ROOT/app" config
    assert_output_contains "Run 'run' to apply"
}

@test "MEMORY_MAX and CPU_QUOTA end up in the service file" {
    make_app "$TEST_ROOT/app" app false
    printf 'MEMORY_MAX="300M"\nCPU_QUOTA="50%%"\n' >> "$TEST_ROOT/app/config.env"
    run bash "$SDC" "$TEST_ROOT/app" run
    [ "$status" -eq 0 ]
    grep -q '^MemoryMax=300M$' "$UNIT_DIR/sdc-app.service"
    grep -q '^CPUQuota=50%$' "$UNIT_DIR/sdc-app.service"

    run bash "$SDC" "$TEST_ROOT/app" status
    assert_output_contains "(limit 300M)"
}

@test "systemd parses the limits (percentages are not escaped)" {
    if ! command -v systemd-analyze >/dev/null; then
        skip "systemd-analyze is not installed"
    fi
    make_app "$TEST_ROOT/app" app false
    ln -sf "$(type -P true)" "$TEST_ROOT/app/venv/bin/python"
    printf 'MEMORY_MAX="25%%"\nCPU_QUOTA="50%%"\n' >> "$TEST_ROOT/app/config.env"
    bash "$SDC" "$TEST_ROOT/app" run
    cp "$UNIT_DIR/sdc-app.service" "$TEST_ROOT/sdc-app.service"

    run env SYSTEMD_LOG_LEVEL=debug systemd-analyze verify "$TEST_ROOT/sdc-app.service"
    refute_output_contains "Invalid"
    assert_output_contains "CPUQuotaPerSecSec: 500ms"
}

@test "no limits by default" {
    make_app "$TEST_ROOT/app" app false
    run bash "$SDC" "$TEST_ROOT/app" run
    grep -q '^MemoryMax=$' "$UNIT_DIR/sdc-app.service"
    grep -q '^CPUQuota=$' "$UNIT_DIR/sdc-app.service"
}

@test "invalid limits are rejected" {
    make_app "$TEST_ROOT/app" app false
    echo 'MEMORY_MAX="lots"' >> "$TEST_ROOT/app/config.env"
    run bash "$SDC" "$TEST_ROOT/app" run
    [ "$status" -eq 1 ]
    assert_output_contains "MEMORY_MAX='lots' is invalid"

    sed -i '/^MEMORY_MAX=/d' "$TEST_ROOT/app/config.env"
    echo 'CPU_QUOTA="50"' >> "$TEST_ROOT/app/config.env"
    run bash "$SDC" "$TEST_ROOT/app" run
    [ "$status" -eq 1 ]
    assert_output_contains "CPU_QUOTA='50' is invalid"
}
