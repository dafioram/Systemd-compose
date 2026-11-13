#!/bin/bash
# Run on a Linux host with an available systemd user manager.
set -euo pipefail

repo_dir=$(cd -- "$(dirname -- "$0")/.." && pwd)
sdc="$repo_dir/systemd-compose.sh"
scratch=$(mktemp -d)
project="$scratch/example app"
app_name="smoke-${scratch##*.}"
unit="sdc-$app_name.service"

cleanup() {
    if [ -f "$project/config.env" ]; then
        "$sdc" "$project" down --volumes || :
    fi
    rm -rf -- "$scratch"
}
trap cleanup EXIT

systemctl --user show-environment >/dev/null
cp -r -- "$repo_dir/projects/example-app" "$project"
sed -i "s/^APP_NAME=.*/APP_NAME=$app_name/" "$project/config.env"
"$sdc" "$project" up
systemctl --user is-active --quiet "$unit"
systemctl --user is-enabled --quiet "$unit"
old_pid=$(systemctl --user show "$unit" --property=MainPID --value)
printf '\nMEMORY_MAX=invalid\n' >> "$project/config.env"
if "$sdc" "$project" run; then
    echo "Expected the invalid update to fail." >&2
    exit 1
fi
systemctl --user is-active --quiet "$unit"
[ "$(systemctl --user show "$unit" --property=MainPID --value)" = "$old_pid" ]
sed -i '/^MEMORY_MAX=/d' "$project/config.env"
"$sdc" "$project" restart
systemctl --user is-active --quiet "$unit"
[ "$(systemctl --user show "$unit" --property=MainPID --value)" != "$old_pid" ]

# Exercise TCP readiness against an actual socket and service cgroup.
port=$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
printf 'PORT=%s\n' "$port" > "$project/.env"
cat >> "$project/config.env" <<'CONFIG'
REQUIRE_PORT=true
ARGS="-m http.server --bind 127.0.0.1 $PORT"
CONFIG
"$sdc" "$project" run
curl --fail --silent "http://127.0.0.1:$port/" >/dev/null

"$sdc" "$project" down --volumes
[ ! -e "${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/$unit" ]
[ ! -e "$project/venv" ]
if systemctl --user is-active --quiet "$unit"; then
    echo "The service is still active after down." >&2
    exit 1
fi
