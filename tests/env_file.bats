#!/usr/bin/env bats
# How .env and config.env are read

# Single quotes below are intentional: the "$(...)" must reach .env literally.
# shellcheck disable=SC2016

load test_helper

@test ".env values are read, quotes stripped, comments skipped" {
    make_app "$TEST_ROOT/app" app true
    printf '# a comment\n\nPORT="8123"\r\n' > "$TEST_ROOT/app/.env"
    STUB_LISTEN=8123 run bash "$SDC" "$TEST_ROOT/app" run
    [ "$status" -eq 0 ]
    grep -q '^X-SDC-Port=8123$' "$UNIT_DIR/sdc-app.service"
}

@test ".env is never executed as shell code" {
    make_app "$TEST_ROOT/app" app false
    printf 'NAME=hello world $(touch %s/pwned)\nOTHER=`touch %s/pwned2`\n' "$TEST_ROOT" "$TEST_ROOT" > "$TEST_ROOT/app/.env"
    run bash "$SDC" "$TEST_ROOT/app" run
    [ "$status" -eq 0 ]
    [ ! -e "$TEST_ROOT/pwned" ]
    [ ! -e "$TEST_ROOT/pwned2" ]
}

@test ".env cannot override PATH or INSTALL_DIR inside systemd-compose" {
    make_app "$TEST_ROOT/app" app false
    printf 'PATH=/nope\nINSTALL_DIR=/tmp/elsewhere\n' > "$TEST_ROOT/app/.env"
    run bash "$SDC" "$TEST_ROOT/app" run
    [ "$status" -eq 0 ]
    assert_output_contains "'PATH' is reserved"
    assert_output_contains "'INSTALL_DIR' is reserved"
    grep -q "^WorkingDirectory=$TEST_ROOT/app/.$" "$UNIT_DIR/sdc-app.service"
}

@test "export lines in .env are skipped with a warning" {
    make_app "$TEST_ROOT/app" app true
    printf 'export PORT=9000\n' > "$TEST_ROOT/app/.env"
    run bash "$SDC" "$TEST_ROOT/app" run
    [ "$status" -eq 1 ]
    assert_output_contains "systemd ignores 'export' lines"
    assert_output_contains "'PORT' variable is missing"
}

@test "export lines in config.env trigger a warning on run" {
    make_app "$TEST_ROOT/app" app false
    echo 'export WEB_WORKERS=1' >> "$TEST_ROOT/app/config.env"
    run bash "$SDC" "$TEST_ROOT/app" run
    [ "$status" -eq 0 ]
    assert_output_contains "Those are NOT passed to your app"
}

@test "an app without .env starts when REQUIRE_PORT=false" {
    make_app "$TEST_ROOT/app" app false
    run bash "$SDC" "$TEST_ROOT/app" run
    [ "$status" -eq 0 ]
    grep -q '^EnvironmentFile=-' "$UNIT_DIR/sdc-app.service"
}
