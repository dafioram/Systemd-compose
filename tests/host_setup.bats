#!/usr/bin/env bats
# host-setup.sh: making app logs readable (persistent journal vs. group)

# Single quotes below are intentional: the fake tools expand "$@" themselves.
# shellcheck disable=SC2016

load test_helper

setup() {
    TEST_ROOT="$(mktemp -d)"
    export STUB_STATE="$TEST_ROOT/state"
    export JOURNAL_DIR="$TEST_ROOT/var/log/journal"
    export JOURNALD_DROPIN_DIR="$TEST_ROOT/etc/journald.conf.d"
    export JOURNALD_CONF="$TEST_ROOT/etc/journald.conf"
    export STUB_GROUPS="user"
    mkdir -p "$STUB_STATE" "$TEST_ROOT/bin" "$TEST_ROOT/etc"
    printf '[Journal]\n#Storage=auto\n' > "$JOURNALD_CONF"

    # Fakes for the system tools ensure_log_access uses
    cat > "$TEST_ROOT/bin/systemd-analyze" <<'EOF'
#!/bin/bash
# Effective config = main file, then drop-ins in name order (like systemd)
cat "$JOURNALD_CONF"
for f in "$JOURNALD_DROPIN_DIR"/*.conf; do [ -f "$f" ] && cat "$f"; done
exit 0
EOF
    printf '#!/bin/bash\necho "sudo $*" >> "$STUB_STATE/calls"\nexec "$@"\n' > "$TEST_ROOT/bin/sudo"
    printf '#!/bin/bash\necho "systemctl $*" >> "$STUB_STATE/calls"\n' > "$TEST_ROOT/bin/systemctl"
    printf '#!/bin/bash\necho "usermod $*" >> "$STUB_STATE/calls"\n' > "$TEST_ROOT/bin/usermod"
    printf '#!/bin/bash\nif [ "$1" == "-nG" ]; then echo "$STUB_GROUPS"; else exec /usr/bin/id "$@"; fi\n' > "$TEST_ROOT/bin/id"
    chmod +x "$TEST_ROOT/bin/"*
    export PATH="$TEST_ROOT/bin:$REPO_DIR/tests/stubs:$PATH"
}

# Runs ensure_log_access with the given answers to its y/N prompts
log_access() {
    run bash -c "source '$REPO_DIR/host-setup.sh' && ensure_log_access" <<< "$1"
}

@test "sourcing host-setup.sh only defines functions" {
    run bash -c "source '$REPO_DIR/host-setup.sh' && type -t ensure_log_access"
    [ "$status" -eq 0 ]
    [ "$output" == "function" ]
}

@test "Storage=auto with /var/log/journal counts as persistent" {
    mkdir -p "$JOURNAL_DIR"
    log_access ""
    [ "$status" -eq 0 ]
    assert_output_contains "stored on disk, so you can read"
    [ ! -f "$STUB_STATE/calls" ]
}

@test "members of systemd-journal are not asked anything" {
    STUB_GROUPS="user systemd-journal" log_access ""
    [ "$status" -eq 0 ]
    assert_output_contains "'systemd-journal' group (logs visible)"
}

@test "an in-memory journal is switched to disk when accepted" {
    log_access "y"
    [ "$status" -eq 0 ]
    assert_output_contains "only kept in memory (Storage=auto)"
    assert_output_contains "now stored on disk"
    grep -q '^Storage=persistent$' "$JOURNALD_DROPIN_DIR/99-systemd-compose.conf"
    grep -q 'systemctl restart systemd-journald' "$STUB_STATE/calls"
    refute_output_contains "Alternative"
}

@test "an explicit Storage=volatile is overridden by the drop-in" {
    printf '[Journal]\nStorage=volatile\n' > "$JOURNALD_CONF"
    log_access "y"
    assert_output_contains "(Storage=volatile)"
    assert_output_contains "now stored on disk"
}

@test "a later drop-in that keeps volatile storage is reported" {
    mkdir -p "$JOURNALD_DROPIN_DIR"
    printf '[Journal]\nStorage=volatile\n' > "$JOURNALD_DROPIN_DIR/zz-ramlog.conf"
    log_access "yn"
    assert_output_contains "Couldn't switch the journal to disk"
    assert_output_contains "Alternative: join the 'systemd-journal' group"
}

@test "declining disk storage offers the group as a fallback" {
    log_access "ny"
    [ "$status" -eq 0 ]
    assert_output_contains "can read ALL system logs"
    grep -q 'usermod -aG systemd-journal' "$STUB_STATE/calls"
    [ ! -f "$JOURNALD_DROPIN_DIR/99-systemd-compose.conf" ]
}

@test "declining both changes nothing" {
    log_access "nn"
    [ "$status" -eq 0 ]
    assert_output_contains "may show nothing"
    [ ! -f "$STUB_STATE/calls" ]
}
