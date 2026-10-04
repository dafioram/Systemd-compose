#!/usr/bin/env bats
# build / run / stop / restart / status / down for a single project

load test_helper

@test "build creates a real venv" {
    mkdir -p "$TEST_ROOT/app"
    printf 'APP_NAME=app\nENTRYPOINT=python\nREQUIRE_PORT=false\n' > "$TEST_ROOT/app/config.env"
    run bash "$SDC" "$TEST_ROOT/app" build
    [ "$status" -eq 0 ]
    assert_output_contains "Build Complete."
    [ -x "$TEST_ROOT/app/venv/bin/python" ]
}

@test "build fails and up stops when pip fails" {
    make_app "$TEST_ROOT/app" app false
    printf '#!/bin/sh\nexit 1\n' > "$TEST_ROOT/app/venv/bin/pip"
    echo "some-package" > "$TEST_ROOT/app/requirements.txt"
    run bash "$SDC" "$TEST_ROOT/app" up
    [ "$status" -eq 1 ]
    assert_output_contains "Dependency installation failed"
    refute_output_contains "Build Complete."
    [ ! -f "$UNIT_DIR/sdc-app.service" ]
}

@test "run fails when the venv binary is missing" {
    make_app "$TEST_ROOT/app" app false
    rm "$TEST_ROOT/app/venv/bin/python"
    run bash "$SDC" "$TEST_ROOT/app" run
    [ "$status" -eq 1 ]
    assert_output_contains "not found in venv"
}

@test "run fails when REQUIRE_PORT=true and PORT is missing" {
    make_app "$TEST_ROOT/app" app true
    run bash "$SDC" "$TEST_ROOT/app" run
    [ "$status" -eq 1 ]
    assert_output_contains "'PORT' variable is missing"
}

@test "run rejects a non-numeric PORT" {
    make_app "$TEST_ROOT/app" app true abc
    run bash "$SDC" "$TEST_ROOT/app" run
    [ "$status" -eq 1 ]
    assert_output_contains "not a valid port"
}

@test "run fails when another program holds the port" {
    make_app "$TEST_ROOT/app" app true 8000
    echo "8000 someone-else" > "$STUB_STATE/ports"
    run bash "$SDC" "$TEST_ROOT/app" run
    [ "$status" -eq 1 ]
    assert_output_contains "Port 8000 is already in use"
}

@test "run on an app that is already running does not trip the port check" {
    make_app "$TEST_ROOT/app" app true 8000
    export STUB_LISTEN=8000
    run bash "$SDC" "$TEST_ROOT/app" run
    [ "$status" -eq 0 ]
    run bash "$SDC" "$TEST_ROOT/app" run
    [ "$status" -eq 0 ]
    assert_output_contains "Port 8000 is free"
    [ "$(current_state sdc-app)" == "active" ]
}

@test "run reports a start failure with logs" {
    make_app "$TEST_ROOT/app" app false
    STUB_START_FAIL=1 run bash "$SDC" "$TEST_ROOT/app" run
    [ "$status" -eq 1 ]
    assert_output_contains "Systemd failed to start the service"
    assert_output_contains "[journal:"
}

@test "run reports an app that crashes right after starting" {
    make_app "$TEST_ROOT/app" app false
    STUB_STATE_AFTER_START=activating run bash "$SDC" "$TEST_ROOT/app" run
    [ "$status" -eq 1 ]
    assert_output_contains "exited during startup"
}

@test "run reports an app that systemd had to restart" {
    make_app "$TEST_ROOT/app" app false
    STUB_NRESTARTS=2 run bash "$SDC" "$TEST_ROOT/app" run
    [ "$status" -eq 1 ]
    assert_output_contains "restarted it (2x)"
}

@test "run reports a port app that never listens" {
    make_app "$TEST_ROOT/app" app true 8000
    echo 'STARTUP_TIMEOUT=2' >> "$TEST_ROOT/app/config.env"
    run bash "$SDC" "$TEST_ROOT/app" run
    [ "$status" -eq 1 ]
    assert_output_contains "not listening on port 8000 after 2s"
}

@test "run clears a previous failed state before starting" {
    make_app "$TEST_ROOT/app" app false
    run bash "$SDC" "$TEST_ROOT/app" run
    unit_state sdc-app failed
    run bash "$SDC" "$TEST_ROOT/app" run
    [ "$status" -eq 0 ]
    grep -q 'reset-failed sdc-app.service' "$STUB_STATE/calls"
}

@test "stop stops an app stuck in a crash loop" {
    make_app "$TEST_ROOT/app" app false
    run bash "$SDC" "$TEST_ROOT/app" run
    unit_state sdc-app activating
    run bash "$SDC" "$TEST_ROOT/app" stop
    [ "$status" -eq 0 ]
    [ "$(current_state sdc-app)" == "inactive" ]
}

@test "stop on an app that was never installed is not an error" {
    make_app "$TEST_ROOT/app" app false
    run bash "$SDC" "$TEST_ROOT/app" stop
    [ "$status" -eq 0 ]
    assert_output_contains "not installed"
}

@test "restart fails when the app is not installed" {
    make_app "$TEST_ROOT/app" app false
    run bash "$SDC" "$TEST_ROOT/app" restart
    [ "$status" -eq 1 ]
    assert_output_contains "is not installed"
}

@test "restart reports a failure with a non-zero exit" {
    make_app "$TEST_ROOT/app" app false
    run bash "$SDC" "$TEST_ROOT/app" run
    STUB_STATE_AFTER_START=activating run bash "$SDC" "$TEST_ROOT/app" restart
    [ "$status" -eq 1 ]
    assert_output_contains "Restart Failed"
}

@test "status shows memory of the whole service and restarts" {
    make_app "$TEST_ROOT/app" app false
    run bash "$SDC" "$TEST_ROOT/app" run
    STUB_MEM=52428800 run bash "$SDC" "$TEST_ROOT/app" status
    [ "$status" -eq 0 ]
    assert_output_contains "Memory Usage:   50 MB"
    assert_output_contains "Restarts:       0"
}

@test "down removes the service" {
    make_app "$TEST_ROOT/app" app false
    run bash "$SDC" "$TEST_ROOT/app" run
    [ -f "$UNIT_DIR/sdc-app.service" ]
    run bash "$SDC" "$TEST_ROOT/app" down
    [ "$status" -eq 0 ]
    [ ! -f "$UNIT_DIR/sdc-app.service" ]
    [ "$(current_state sdc-app)" == "inactive" ]
}
