#!/usr/bin/env bats
# Argument parsing, usage and config validation

load test_helper

@test "no arguments prints usage and fails" {
    run bash "$SDC"
    [ "$status" -eq 1 ]
    assert_output_contains "Usage:"
}

@test "unknown command fails" {
    make_app "$TEST_ROOT/app" app false
    run bash "$SDC" "$TEST_ROOT/app" frobnicate
    [ "$status" -eq 1 ]
    assert_output_contains "Unknown command: frobnicate"
}

@test "missing project folder fails" {
    run bash "$SDC" "$TEST_ROOT/nope" status
    [ "$status" -eq 1 ]
    assert_output_contains "not found"
}

@test "folder without config.env fails" {
    mkdir -p "$TEST_ROOT/empty"
    run bash "$SDC" "$TEST_ROOT/empty" status
    [ "$status" -eq 1 ]
    assert_output_contains "config.env not found"
}

@test "APP_NAME with a path is rejected and writes nothing" {
    make_app "$TEST_ROOT/evil" "../../evil" false
    run bash "$SDC" "$TEST_ROOT/evil" run
    [ "$status" -eq 1 ]
    assert_output_contains "is invalid"
    [ ! -e "$HOME/.config/evil.service" ]
    [ ! -e "$HOME/evil.service" ]
}

@test "empty APP_NAME is rejected" {
    make_app "$TEST_ROOT/app" "" false
    run bash "$SDC" "$TEST_ROOT/app" status
    [ "$status" -eq 1 ]
    assert_output_contains "is invalid"
}

@test "spaces in APP_NAME become dashes" {
    make_app "$TEST_ROOT/app" "Task List" false
    run bash "$SDC" "$TEST_ROOT/app" run
    [ "$status" -eq 0 ]
    [ -f "$UNIT_DIR/sdc-Task-List.service" ]
}

@test "missing ENTRYPOINT gives a clear error" {
    mkdir -p "$TEST_ROOT/app"
    printf 'APP_NAME=app\nREQUIRE_PORT=false\n' > "$TEST_ROOT/app/config.env"
    run bash "$SDC" "$TEST_ROOT/app" run
    [ "$status" -eq 1 ]
    assert_output_contains "ENTRYPOINT is not set"
}

@test "unquoted values in config.env work" {
    make_app "$TEST_ROOT/app" app false
    sed -i 's/^APP_NAME=.*/APP_NAME=plain/' "$TEST_ROOT/app/config.env"
    run bash "$SDC" "$TEST_ROOT/app" run
    [ "$status" -eq 0 ]
    [ -f "$UNIT_DIR/sdc-plain.service" ]
}
