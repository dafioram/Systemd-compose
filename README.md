Below are **production-ready, Debian-correct, rootless-first** rewrites of:

* `status.sh`
* `restart.sh`
* `README.md`

These are fully consistent with your current `lib.sh`, `.env`, `app.settings`, and systemd user-service model.

---

## `status.sh` (full rewrite)

Improvements over your current version:

* Uses `ENV_PORT_KEY` (not hardcoded `PORT`)
* Handles user/system mode transparently
* More robust PID + port detection
* Cleaner output
* No false warnings when port cannot be detected

```bash
#!/bin/bash
set -e

source ./lib.sh

echo "--- $APP_NAME Status ---"

if ! $SYSTEMCTL is-active --quiet "$SERVICE_NAME"; then
    echo "Status: DOWN"
    exit 0
fi

echo "Status: ACTIVE"

PID="$($SYSTEMCTL show -p MainPID --value "$SERVICE_NAME")"
echo "PID:    $PID"

if [ -z "$PID" ] || [ "$PID" = "0" ]; then
    echo "Process not fully started yet"
    exit 0
fi

# -----------------------------
# Memory usage
# -----------------------------

if ps -p "$PID" >/dev/null 2>&1; then
    RAM=$(ps -p "$PID" -o rss= | awk '{printf "%.2f MB", $1/1024}')
    echo "Memory: $RAM"
fi

# -----------------------------
# Port detection
# -----------------------------

PORT=$(ss -lntp 2>/dev/null \
    | grep "pid=$PID" \
    | grep -oP '(?<=:)\d+' \
    | head -n1)

echo "Port:   ${PORT:-Unknown}"

# -----------------------------
# Configuration audit
# -----------------------------

if [ -f .env ]; then
    ENV_PORT=$(grep -E "^${ENV_PORT_KEY}=" .env | cut -d= -f2)
    if [ -n "$ENV_PORT" ] && [ -n "$PORT" ] && [ "$ENV_PORT" != "$PORT" ]; then
        echo "Warning: .env ${ENV_PORT_KEY}=$ENV_PORT but process bound to $PORT"
    fi
fi
```

---

## `restart.sh` (full rewrite)

Key decisions:

* No sudo
* Pulls git changes if applicable
* Delegates lifecycle to `up.sh` (single source of truth)
* Safe even if not a git repo

```bash
#!/bin/bash
set -e

source ./lib.sh

echo "--- Restarting $APP_NAME ---"

if [ -d .git ]; then
    echo "Pulling latest changes..."
    git pull || echo "Git pull failed (continuing)"
else
    echo "Not a git repository; skipping pull"
fi

./up.sh

echo "Success: $APP_NAME restarted"
```

---

## `README.md` (documentation)

This documents **exactly** how your framework works and why it exists.

```markdown
# App Lifecycle Framework (systemd + Python venv)

This project provides a **Docker-like lifecycle** for Python web applications using:

- systemd (user or system mode)
- Python virtual environments
- `.env` configuration
- Zero containers
- Rootless by default (Debian-correct)

---

## Philosophy

This framework mirrors Docker concepts:

| Docker Concept | This Framework |
|----------------|----------------|
| Container      | systemd service |
| Image          | Git repo + venv |
| docker-compose | app.settings + .env |
| docker up      | up.sh |
| docker down    | down.sh |
| docker logs    | logs.sh |
| docker restart | restart.sh |

It is designed to:
- Work cleanly on Debian
- Avoid implicit sudo
- Keep host and app responsibilities separate
- Be transparent and debuggable

---

## Directory Structure

Recommended layout:

```

project/
├── app/
│   └── main.py
├── 
│   ├── lib.sh
│   ├── up.sh
│   ├── down.sh
│   ├── restart.sh
│   ├── status.sh
│   ├── logs.sh
│   ├── validator.sh
│   ├── install-deps.sh
│   └── enable_linger.sh
├── .env
├── app.settings
├── requirements.txt
├── app.service.template
└── .venv/

````

Run scripts from the **project root**.

---

## One-Time Host Setup (Debian)

Run once per machine:

```bash
sudo ./install-deps.sh
````

Optional but recommended for user services:

```bash
sudo loginctl enable-linger <username>
```

---

## Configuration

### `app.settings`

Defines identity and execution command:

```bash
APP_NAME="my-awesome-app"
APP_DESCRIPTION="An awesome service"
ENV_PORT_KEY="APP_PORT"
EXEC_CMD="{{VENV}}/uvicorn main:app --host 0.0.0.0 --port {{PORT}}"
```

### `.env`

Defines runtime configuration (Docker-style):

```env
APP_PORT=8000
```

---

## Lifecycle Commands

From project root:

```bash
./up.sh        # Build venv, install deps, start service
./down.sh      # Stop and remove service
./restart.sh   # Pull + rebuild + restart
./status.sh    # Show health and diagnostics
./logs.sh      # Tail logs
```

---

## systemd Modes

Default is **user mode** (rootless):

```bash
SYSTEMD_MODE=user
```

System mode is supported but requires root:

```bash
SYSTEMD_MODE=system
sudo ./control/up.sh
```

---

## Debian Python Model (Important)

* `pip` is bootstrapped **inside each venv**
* Host pip is optional
* This is intentional and Debian-correct
* Each app is isolated

---

## Logs

Logs are written to:

```
app.log
error.log
```

Managed by systemd.

---

## Why Not Docker?

* No container overhead
* Native system integration
* Faster startup
* Easier debugging
* Fewer moving parts

This is ideal for:

* Homelabs
* Single-host deployments
* Internal services
* Lightweight production systems

---

## License / Usage

Internal tooling. Adapt freely.

```

---

## Final Notes

At this point, your framework is:

- Architecturally sound
- Debian-policy compliant
- Rootless by default
- Docker-conceptually consistent
- Safe to replicate across projects

If you want next:
- `logs.sh` upgrade (journalctl support)
- `restart.sh --no-pull`
- `status.sh --json`
- Versioned templates
- Multi-service support
