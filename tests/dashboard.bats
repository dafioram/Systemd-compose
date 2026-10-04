#!/usr/bin/env bats
# ps / stop-all / start-all and name conflicts between projects

load test_helper

@test "ps on a fresh install prints an empty table" {
    run bash "$SDC" ps
    [ "$status" -eq 0 ]
    assert_output_contains "APP NAME"
    [ "$(echo "$output" | wc -l)" -eq 4 ]
}

@test "ps lists apps from any folder with the right status" {
    make_app "$TEST_ROOT/apps/web" web true 8000 app
    make_app "$TEST_ROOT/elsewhere/bot" bot false
    make_app "$TEST_ROOT/elsewhere/worker" worker false
    STUB_LISTEN=8000 bash "$SDC" "$TEST_ROOT/apps/web" run
    bash "$SDC" "$TEST_ROOT/elsewhere/bot" run
    bash "$SDC" "$TEST_ROOT/elsewhere/worker" run
    unit_state sdc-bot failed
    unit_state sdc-worker inactive

    run bash "$SDC" ps
    [ "$status" -eq 0 ]
    # One line per app, no stray "unknown" lines
    [ "$(echo "$output" | wc -l)" -eq 7 ]
    refute_output_contains "unknown"
    [[ "$output" =~ web[[:space:]]+RUNNING[[:space:]].*8000.*apps/web ]]
    [[ "$output" =~ bot[[:space:]]+CRASHED ]]
    [[ "$output" =~ worker[[:space:]]+STOPPED ]]
}

@test "ps shows RESTARTING for an app waiting to be restarted" {
    make_app "$TEST_ROOT/app" app false
    bash "$SDC" "$TEST_ROOT/app" run
    unit_state sdc-app activating
    STUB_SUBSTATE=auto-restart run bash "$SDC" ps
    [[ "$output" =~ app[[:space:]]+RESTARTING ]]
}

@test "ps marks a project folder that no longer exists" {
    make_app "$TEST_ROOT/app" app false
    bash "$SDC" "$TEST_ROOT/app" run
    mv "$TEST_ROOT/app" "$TEST_ROOT/moved"
    run bash "$SDC" ps
    assert_output_contains "(missing)"
}

@test "a copied project with the same APP_NAME is refused" {
    make_app "$TEST_ROOT/app" web false
    bash "$SDC" "$TEST_ROOT/app" run
    cp -r "$TEST_ROOT/app" "$TEST_ROOT/copy"

    for cmd in run stop restart down status logs; do
        run bash "$SDC" "$TEST_ROOT/copy" "$cmd"
        [ "$status" -eq 1 ]
        assert_output_contains "Name Conflict"
    done
    # The original app was not touched
    [ "$(current_state sdc-web)" == "active" ]
    [ -f "$UNIT_DIR/sdc-web.service" ]
}

@test "a moved project can claim its old name" {
    make_app "$TEST_ROOT/app" web false
    bash "$SDC" "$TEST_ROOT/app" run
    mv "$TEST_ROOT/app" "$TEST_ROOT/moved"
    run bash "$SDC" "$TEST_ROOT/moved" run
    [ "$status" -eq 0 ]
    assert_output_contains "Claiming orphaned service name"
    grep -q "^X-SDC-Project=$TEST_ROOT/moved$" "$UNIT_DIR/sdc-web.service"
}

@test "stop-all stops every app, including crash-looping ones" {
    make_app "$TEST_ROOT/a" a false
    make_app "$TEST_ROOT/b" b false
    bash "$SDC" "$TEST_ROOT/a" run
    bash "$SDC" "$TEST_ROOT/b" run
    unit_state sdc-b activating
    run bash "$SDC" stop-all
    [ "$status" -eq 0 ]
    assert_output_contains "Processed 2 apps"
    [ "$(current_state sdc-a)" == "inactive" ]
    [ "$(current_state sdc-b)" == "inactive" ]
}

@test "start-all starts every installed app and clears failed state" {
    make_app "$TEST_ROOT/a" a false
    make_app "$TEST_ROOT/b" b false
    bash "$SDC" "$TEST_ROOT/a" run
    bash "$SDC" "$TEST_ROOT/b" run
    unit_state sdc-a inactive
    unit_state sdc-b failed
    run bash "$SDC" start-all
    [ "$status" -eq 0 ]
    [ "$(current_state sdc-a)" == "active" ]
    [ "$(current_state sdc-b)" == "active" ]
}

@test "other user services are not listed or touched" {
    mkdir -p "$UNIT_DIR"
    printf '[Service]\nExecStart=/bin/true\n' > "$UNIT_DIR/pipewire.service"
    unit_state pipewire active
    run bash "$SDC" stop-all
    refute_output_contains "pipewire"
    [ "$(current_state pipewire)" == "active" ]
}
