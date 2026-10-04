# Systemd-compose

A **rootless**, **Docker-like** process manager for Python applications on Debian/Ubuntu systems.

**Systemd-compose** allows you to manage Python projects (Flask, FastAPI, scripts, bots) using a familiar workflow (`build`, `up`, `down`, `logs`) without the overhead or complexity of Docker containers. It leverages native Linux tools (`systemd --user`, `venv`, `pip`) to ensure your apps are robust, isolated, and auto-start on boot—all without needing `sudo` for day-to-day operations.

## ⚖️ Why Systemd-compose?

Get the developer experience of Docker without the resource cost.

| Feature | Docker | Systemd-compose |
| :--- | :--- | :--- |
| **Isolation** | Heavy (Container Virtualization) | Light (Venv / Native Process) |
| **RAM Usage** | High (Daemon + Container Overhead) | **Near Zero** (Native OS usage only) |
| **Disk Space** | Heavy (Duplicated OS layers) | **Tiny** (Shared OS libs) |
| **Management** | `docker compose up` | `systemd-compose . up` |
| **Best For** | Cloud / Complex Deps | Raspberry Pi / Home Lab / Old PCs |

---

## ✨ Features

* **Rootless Architecture:** Runs entirely in userspace using `systemd --user`.
* **Docker-like CLI:** Commands like `up`, `down`, `ps`, and `logs` make it easy to learn.
* **Isolated Environments:** Automatically creates and manages a Python `venv` for each project.
* **Namespaced Services:** Every app runs as `sdc-<APP_NAME>.service`, so it can never replace one of your other user services.
* **Conflict Detection:** Prevents two project folders from claiming the same app name.
* **Crash Detection:** `up` waits until your app is actually running (and listening on its port) and shows the logs if it isn't. Crash loops end as **CRASHED** instead of restarting forever.
* **Global Dashboard:** `ps` shows every app you've started, wherever its project folder lives.
* **Flexible:** Runs anything installed in the venv: plain Python scripts, Uvicorn (FastAPI), Gunicorn (Flask/Django), or `python -m http.server` for a static site.

---

## 🚀 Installation

**Requirements:** Debian, Ubuntu, Raspberry Pi OS or DietPi with **systemd 240 or newer** (Debian 10+, Ubuntu 20.04+, Raspberry Pi OS Buster+), and Python 3.

### 1. Clone

Clone this repository to your home directory (recommended location: `~/systemd-compose`).

```bash
git clone https://github.com/dafioram/Systemd-compose ~/systemd-compose
cd ~/systemd-compose
```

### 2. Run Host Setup

```bash
./host-setup.sh
```

The script asks before changing anything. It:

1. Installs missing packages: `python3`, `python3-venv`, `python3-pip`, `git`, `lsof`, `iproute2`, `dbus-user-session`, `libpam-systemd`.
2. Fixes minimal systems such as DietPi (masked `systemd-logind`, missing `XDG_RUNTIME_DIR`).
3. Offers to add you to the `systemd-journal` group, so `logs` and `status` can show your apps' output on systems that don't keep a per-user journal. This group can read **all** system logs.
4. Enables **linger** for your user, so apps start at boot and keep running after you log out.
5. Links `systemd-compose` into `/usr/local/bin`.

You need `sudo` only for this step. If you were added to a group, **log out and back in** before continuing.

### 3. Verify

```bash
systemd-compose ps
```

This should print an empty table. *Tip: add `alias sdc='systemd-compose'` to your `.bashrc` for faster typing.*

---

## ⚡ Quick Start

```bash
# Copy the example anywhere you like
cp -r ~/systemd-compose/projects/example-app ~/my-new-bot
cd ~/my-new-bot

# Pick a unique name for it
nano config.env        # set APP_NAME="my-new-bot"

# Create the venv, install requirements.txt, install and start the service
systemd-compose . up

systemd-compose ps     # see all apps
systemd-compose . logs # follow this app's output (Ctrl+C to exit)
```

---

## 📂 Project Structure

Any folder with a `config.env` is a project. A typical project looks like this:

```
my-app/
├── config.env         # What to run. Commit it.
├── .env               # Port, secrets and settings for your app. Don't commit it.
├── requirements.txt   # Installed into venv/ by `build`
├── venv/              # Created by `build`. Don't commit it.
└── app/               # Your code (or put it in the root and use APP_DIR=".")
    └── main.py
```

The `.gitignore` in your project should contain at least:

```
.env
venv/
```

### 1. `config.env` (Project Definition)

This file defines *what* to run. It is read only by systemd-compose, as a bash file, when you run a command.

```bash
APP_NAME="my-awesome-bot"
DESCRIPTION="A Discord bot"

# Use "." if your main script is in the root.
# Use "src" or "app" if your code is in a subfolder.
APP_DIR="."

# The program to run from venv/bin, and its arguments
ENTRYPOINT="python"
ARGS="${INSTALL_DIR}/${APP_DIR}/bot.py"

# "true": PORT must be set in .env and be free before the app starts.
# "false": background scripts/bots that don't listen on a port.
REQUIRE_PORT="false"
```

| Setting | Required | Description |
| :--- | :--- | :--- |
| `APP_NAME` | Yes | Unique name. The service is called `sdc-<APP_NAME>`. Letters, digits, `-`, `_` and `.` only; spaces become `-`. |
| `DESCRIPTION` | No | Shown by `systemctl --user status`. |
| `ENTRYPOINT` | Yes | Program in `venv/bin` to run: `python`, `uvicorn`, `gunicorn`, … |
| `ARGS` | No | Arguments for `ENTRYPOINT`. See [How `ARGS` is used](#how-args-is-used). |
| `APP_DIR` | No | Folder (relative to the project) that the app runs in. Default `.`. |
| `REQUIRE_PORT` | No | `true` (default) or `false`. See above. |
| `PYTHON_BIN` | No | Python used to create the venv. Default `python3`. Delete `venv/` and run `build` after changing it. |
| `STARTUP_TIMEOUT` | No | Seconds to wait for the port to start listening. Default `15`. |

`config.env` can use `${INSTALL_DIR}` (the project folder), `${APP_DIR}`, and any value from `.env`, such as `$PORT`.

> ⚠️ `export` lines in `config.env` do **not** reach your app. Variables your app reads at runtime belong in `.env`. systemd-compose warns you when `config.env` contains `export`.

### 2. `.env` (Port, Secrets & App Settings)

This file is handed to your app by systemd (`EnvironmentFile=`). It is the **only** way to give your app environment variables.

```bash
PORT=8000
SECRET_KEY=super_secret_value
WEB_WORKERS=1
```

Use systemd's format:

* One plain `KEY=VALUE` per line. Quotes around the value are optional and are stripped.
* No `export`, no `$VARIABLE` expansion, no `$(commands)`, and no comments after a value. Full-line `#` comments are fine.
* systemd-compose reads this file too (it never executes it), so `config.env` can use `$PORT`.

`.env` is optional when `REQUIRE_PORT="false"`. `PYTHONUNBUFFERED=1` is always set for you, so `print()` output shows up in the logs immediately.

---

## 🛠 Commands

### Project Commands

Run these with the path to a project folder (`.` for the current folder).

| Command | Description |
| --- | --- |
| `systemd-compose . up` | **Recommended.** `build` + `run` (like `docker compose up`). |
| `systemd-compose . build` | Creates the `venv` and installs `requirements.txt`. Stops if `pip` fails. |
| `systemd-compose . run` | Writes the service file and (re)starts the app, then waits until it is running. Safe to re-run while the app is running. |
| `systemd-compose . restart` | Restarts the app with the existing service file. Picks up `.env` changes. |
| `systemd-compose . stop` | Stops the app (keeps the venv and logs). It still starts again at boot. |
| `systemd-compose . down` | Stops the app, removes the service, and **deletes the venv**. |
| `systemd-compose . status` | State, PID, memory of all workers, restart count, port and recent log lines. |
| `systemd-compose . logs` | Follows the app's logs. |

**`run` or `restart`?** Values in `config.env` (including `$PORT` in `ARGS`) are written into the service file. After changing `config.env` or `PORT`, use `run` or `up`. For other `.env` changes, `restart` is enough.

### Global Commands

| Command | Description |
| --- | --- |
| `systemd-compose ps` | Lists every installed app: status, PID, port, uptime and project folder. |
| `systemd-compose stop-all` | Stops every installed app. |
| `systemd-compose start-all` | Starts every installed app. |

`ps` statuses: **RUNNING**, **STOPPED**, **STARTING**, **RESTARTING** (crashed, systemd will retry in a few seconds), **CRASHED** (systemd gave up; fix it and `run` again). A project folder marked `(missing)` was moved or deleted; run `down` from its new location, or remove the service by hand (see [Under the Hood](#-under-the-hood)).

---

## ⚙️ Configuration Examples

### Plain Python Script

```bash
ENTRYPOINT="python"
ARGS="${INSTALL_DIR}/${APP_DIR}/main.py"
```

### FastAPI / Uvicorn

```bash
ENTRYPOINT="uvicorn"
# Syntax: <file_module>:<app_object>
ARGS="main:app --app-dir ${INSTALL_DIR}/${APP_DIR} --host 0.0.0.0 --port $PORT"
REQUIRE_PORT="true"
```

### Flask / Django with Gunicorn

```bash
ENTRYPOINT="gunicorn"
ARGS="wsgi:app --chdir ${INSTALL_DIR}/${APP_DIR} --bind 0.0.0.0:$PORT"
REQUIRE_PORT="true"
```

Or keep the settings in a `gunicorn.conf.py` and only pass the port:

```bash
ARGS="-c ${INSTALL_DIR}/${APP_DIR}/gunicorn.conf.py --bind 0.0.0.0:$PORT"
```

*Remember to add `uvicorn` / `gunicorn` to your `requirements.txt`!*

### How `ARGS` is used

`ARGS` is expanded by bash when systemd-compose reads `config.env` (so `${INSTALL_DIR}`, `${APP_DIR}` and `$PORT` are filled in), then written into the service's `ExecStart=` line. There, systemd splits it into arguments:

* Wrap an argument containing spaces in quotes, e.g. `ARGS="--name 'My App'"`.
* `%` and `$` are passed through literally (systemd-compose escapes them), so a log format like `'%(h)s %(r)s'` is safe.

### Startup Check & Crash Handling

After starting the app, `run`/`up`/`restart` watch it before reporting success:

* **Apps with a port:** succeed as soon as `PORT` is listening. They fail if the app crashes, or if it isn't listening after `STARTUP_TIMEOUT` seconds.
* **Background apps** (`REQUIRE_PORT="false"`): succeed if the app is still running, without restarts, after 3 seconds.

On failure the last log lines are printed and the command exits with an error.

While running, systemd restarts the app 5 seconds after a crash. If it crashes 5 times within 2 minutes, systemd gives up and `ps` shows **CRASHED**. An app that exits cleanly (exit code 0) is not restarted.

User services can't wait for the system's network to come up at boot, so apps that connect to other hosts should retry on startup.

---

## 🔧 Under the Hood

`run` writes `~/.config/systemd/user/sdc-<APP_NAME>.service` from [`templates/service.unit`](templates/service.unit). The service file records which project folder owns it (`X-SDC-Project=`); that is how `ps` finds your apps and how name conflicts are detected.

Because these are ordinary systemd user services, the usual tools work too:

```bash
systemctl --user status sdc-my-app
journalctl --user -u sdc-my-app --since "1 hour ago"
systemctl --user list-units 'sdc-*'
```

To remove an app whose project folder is gone:

```bash
systemctl --user disable --now sdc-my-app
rm ~/.config/systemd/user/sdc-my-app.service
systemctl --user daemon-reload
```

---

## 🩺 Troubleshooting

| Problem | Fix |
| --- | --- |
| `Name Conflict!` | Another project folder already uses this `APP_NAME`. Change `APP_NAME` in this project's `config.env`. |
| `Port 8000 is already in use` | Another program (or another app) is listening on `PORT`. Change `PORT` in `.env`, or stop the other program. |
| `running but not listening on port …` | The app started but isn't using `$PORT`. Check `ARGS` binds to `$PORT`, or raise `STARTUP_TIMEOUT`. |
| `logs` shows nothing / "No journal files were found" | Accept the `systemd-journal` group in `host-setup.sh`, then log out and back in. |
| Apps stop when you log out / don't start at boot | Linger is off. Run `loginctl enable-linger $USER`. |
| `Failed to connect to bus` | Re-run `./host-setup.sh` and open a new shell. |

---

## 🧪 Development

The tests use [bats](https://github.com/bats-core/bats-core) with fake `systemctl`, `ss` and `journalctl` commands (`tests/stubs/`), so they never touch your real services.

```bash
sudo apt install bats shellcheck
bats tests
shellcheck systemd-compose.sh host-setup.sh tests/stubs/* tests/test_helper.bash tests/*.bats
```

CI runs both on every pull request.

---

## 🗑 Uninstall

```bash
# Remove each app (run in each project folder)
systemd-compose . down

# Remove the command
sudo rm /usr/local/bin/systemd-compose

# (Optional) Stop user services from running without a login session
loginctl disable-linger $USER
```

*Upgrading from a version before the `sdc-` prefix?* Older versions named services `<APP_NAME>.service`. Remove those as shown in [Under the Hood](#-under-the-hood) (without the `sdc-`) before running `up` with this version.
