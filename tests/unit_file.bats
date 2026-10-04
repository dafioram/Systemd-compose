#!/usr/bin/env bats
# The generated ~/.config/systemd/user/sdc-*.service file

# Single quotes below are intentional: the "$" must reach the files literally.
# shellcheck disable=SC2016

bats_require_minimum_version 1.5.0

load test_helper

unit_file() {
    echo "$UNIT_DIR/sdc-$1.service"
}

@test "service file has the expected settings" {
    make_app "$TEST_ROOT/app" app true 8000 src
    STUB_LISTEN=8000 run bash "$SDC" "$TEST_ROOT/app" run
    [ "$status" -eq 0 ]
    local f
    f="$(unit_file app)"
    grep -q "^X-SDC-Project=$TEST_ROOT/app$" "$f"
    grep -q '^X-SDC-Port=8000$' "$f"
    grep -q '^Type=exec$' "$f"
    grep -q '^Restart=on-failure$' "$f"
    grep -q '^StartLimitBurst=5$' "$f"
    grep -q "^WorkingDirectory=$TEST_ROOT/app/src$" "$f"
    grep -q "^EnvironmentFile=-$TEST_ROOT/app/.env$" "$f"
    run ! grep -q "^After=" "$f"
}

@test "background apps record no port" {
    make_app "$TEST_ROOT/app" app false
    echo "PORT=9000" > "$TEST_ROOT/app/.env"
    run bash "$SDC" "$TEST_ROOT/app" run
    grep -q '^X-SDC-Port=$' "$(unit_file app)"
}

@test "special characters are escaped, not interpreted" {
    make_app "$TEST_ROOT/app" app false
    cat > "$TEST_ROOT/app/config.env" <<'EOF'
APP_NAME="app"
DESCRIPTION="Tom & Jerry | 100% \done"
ENTRYPOINT="python"
ARGS="--fmt '%h %r' --price '$9'"
REQUIRE_PORT="false"
EOF
    run bash "$SDC" "$TEST_ROOT/app" run
    [ "$status" -eq 0 ]
    local f
    f="$(unit_file app)"
    grep -qF 'Description=Tom & Jerry | 100%% \done' "$f"
    grep -qF -- "--fmt '%%h %%r'" "$f"
}

@test "a literal dollar sign in ARGS is escaped in ExecStart" {
    make_app "$TEST_ROOT/app" app false
    printf 'TOKEN=abc$def\n' > "$TEST_ROOT/app/.env"
    sed -i 's|^ARGS=.*|ARGS="--token $TOKEN"|' "$TEST_ROOT/app/config.env"
    run bash "$SDC" "$TEST_ROOT/app" run
    [ "$status" -eq 0 ]
    grep -qF -- '--token abc$$def' "$(unit_file app)"
}

@test "a project path with spaces is quoted" {
    make_app "$TEST_ROOT/my app" app false
    run bash "$SDC" "$TEST_ROOT/my app" run
    [ "$status" -eq 0 ]
    grep -qF "ExecStart=\"$TEST_ROOT/my app/venv/bin/python\"" "$(unit_file app)"
    grep -qF "Environment=\"PATH=$TEST_ROOT/my app/venv/bin:" "$(unit_file app)"
}

@test "a project path with a double quote is rejected" {
    make_app "$TEST_ROOT/bad\"dir" app false
    run bash "$SDC" "$TEST_ROOT/bad\"dir" run
    [ "$status" -eq 1 ]
    assert_output_contains "can't contain"
}

@test "systemd accepts the generated file and parses ExecStart as intended" {
    if ! command -v systemd-analyze >/dev/null; then
        skip "systemd-analyze is not installed"
    fi
    make_app "$TEST_ROOT/my app" app false
    ln -sf "$(type -P true)" "$TEST_ROOT/my app/venv/bin/python"
    sed -i "s|^ARGS=.*|ARGS=\"--fmt '%h %r' --dir '\${INSTALL_DIR}'\"|" "$TEST_ROOT/my app/config.env"
    run bash "$SDC" "$TEST_ROOT/my app" run
    [ "$status" -eq 0 ]

    cp "$(unit_file app)" "$TEST_ROOT/sdc-app.service"
    run systemd-analyze verify "$TEST_ROOT/sdc-app.service"
    [ "$status" -eq 0 ]

    # The debug dump shows the command line after systemd has parsed it
    run env SYSTEMD_LOG_LEVEL=debug systemd-analyze verify "$TEST_ROOT/sdc-app.service"
    assert_output_contains "--fmt \"%h %r\""
    assert_output_contains "--dir \"$TEST_ROOT/my app\""
}
