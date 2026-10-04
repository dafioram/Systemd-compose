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
* **Isolated Environments:** Automatically creates and manages Python `venvs` for each project.
* **Conflict Detection:** Prevents multiple projects from trying to claim the same service name.
* **Quick Config Changes:** Edit `.env`, then `run` regenerates the service and restarts the app.
* **Flexible:** Supports Python scripts, Uvicorn (FastAPI), Gunicorn, or even static React sites (via wrapper).
* **Global Dashboard:** View the status of all your apps with a single `ps` command.

---

## 🚀 Installation

### 1. Clone & Setup
Clone this repository to your home directory (recommended location: `~/systemd-compose`).

```bash
git clone <your-repo-url> ~/systemd-compose
cd ~/systemd-compose
```

### 2. Run Host Setup

This script checks for OS compatibility (Debian/Ubuntu), installs necessary system dependencies (like `python3-venv`, `git`, `lsof`), enables systemd lingering (so apps run after logout), and links the binary to your path.
```bash
./host-setup.sh

```

**Note:** You will need `sudo` access only once during this step to install the Debian packages.

**Requires systemd 240 or newer** (Debian 10+, Ubuntu 20.04+, Raspberry Pi OS Buster+).

### 3. Verify

You can now run `systemd-compose` from anywhere.

```bash
systemd-compose --help
```

*Tip: Add `alias sdc='systemd-compose'` to your `.bashrc` for faster typing.*

---

## 🛠 Usage

### Creating a New Project

You can copy the included example to get started.

```bash
cp -r ~/systemd-compose/projects/example-app ~/my-new-bot
cd ~/my-new-bot
```

### The Workflow

| Command | Description |
| --- | --- |
| `systemd-compose . build` | Creates the `venv` and installs `requirements.txt`. |
| `systemd-compose . run` | Generates the Systemd service and (re)starts the app. Safe to re-run while it is running. |
| `systemd-compose . up` | **Recommended.** Runs `build` + `run` (like `docker-compose up`). |
| `systemd-compose . stop` | Stops the process (preserves venv and logs). It still starts again on boot. |
| `systemd-compose . restart` | Restarts with the existing service file. Re-reads `.env`, but use `run` if you changed `config.env` or `PORT`. |
| `systemd-compose . down` | Stops the process, removes the service, and **deletes the venv**. |
| `systemd-compose . logs` | Tails the real-time logs of the application. |
| `systemd-compose . status` | Shows detailed status (PID, memory of all workers, restarts, port). |

### Global Dashboard

To see all running projects managed by Systemd-compose:

```bash
systemd-compose ps
# Or stop everything at once
systemd-compose stop-all
```

---

## 📂 Project Structure

To "drop in" an existing Python project, just add these two files to your project root:

### 1. `config.env` (Project Definition)

This file defines *what* to run. It should be committed to Git.

```bash
APP_NAME="my-awesome-bot"
DESCRIPTION="A Discord bot"

# DIRECTORY STRUCTURE
# Use "." if your main script is in the root.
# Use "src" or "app" if your code is in a subfolder.
APP_DIR="."

# RUNNER CONFIGURATION
ENTRYPOINT="python"
ARGS="${INSTALL_DIR}/${APP_DIR}/bot.py"

# NETWORK CONFIGURATION
# "true": PORT must be set in .env and be free before the app starts.
# Set to "false" for background scripts/bots that don't listen on a port.
REQUIRE_PORT="true"
```

`config.env` is only read by systemd-compose. `export` lines in it do **not** reach your app; put those variables in `.env`.

`APP_NAME` becomes the systemd service name: use letters, digits, `-`, `_` or `.` (spaces are turned into `-`).

### 2. `.env` (Secrets & Local Config, Project Specific)

This file defines *how* to run (Ports, Keys). **Add this to `.gitignore`**.

```bash
PORT=8000
SECRET_KEY=super_secret_value
```

This is the **only** place to put environment variables your app should see; systemd hands it to the app with `EnvironmentFile=`. Use systemd's format:

* One plain `KEY=VALUE` per line. Quotes around the value are optional and are stripped.
* No `export`, no `$VARIABLE` expansion, no `$(commands)`, and no comments after a value. Full-line `#` comments are fine.
* systemd-compose also reads this file (it never executes it), so `config.env` can use `$PORT` and other values from it.

`.env` is optional when `REQUIRE_PORT="false"`.

---

## ⚙️ Configuration

### Switching to FastAPI / Uvicorn

Edit your `config.env`:

```bash
ENTRYPOINT="uvicorn"
# Syntax: <file_module>:<app_object>
ARGS="main:app --app-dir ${INSTALL_DIR}/${APP_DIR} --host 0.0.0.0 --port $PORT"
```

*Remember to add `uvicorn` to your `requirements.txt`!*

### How `ARGS` is used

`ARGS` is expanded by the shell when systemd-compose reads `config.env` (so `${INSTALL_DIR}`, `${APP_DIR}` and `$PORT` are filled in), then written into the service's `ExecStart=` line. There, systemd splits it into arguments:

* Wrap an argument containing spaces in quotes, e.g. `ARGS="--name 'My App'"`.
* `%` and `$` are passed through literally (systemd-compose escapes them), so a log format like `'%(h)s %(r)s'` is safe.
* Because values are filled in when the service is written, run `systemd-compose . run` (not `restart`) after changing `config.env` or `PORT`.

### Startup Check & Crash Handling

After starting the app, `run`/`up`/`restart` watch it before reporting success:

* **Apps with a port:** succeed as soon as `PORT` is listening. They fail if the app crashes, or if it isn't listening after `STARTUP_TIMEOUT` seconds (default `15`). Set `STARTUP_TIMEOUT="60"` in `config.env` for slow-starting apps.
* **Background apps** (`REQUIRE_PORT="false"`): succeed if the app is still running, without restarts, after 3 seconds.

On failure the last log lines are printed and the command exits with an error.

While running, systemd restarts the app 5 seconds after a crash (`Restart=on-failure`). If it crashes 5 times within 2 minutes, systemd gives up and `ps` shows it as **CRASHED**. Fix the problem, then `run` again. An app that exits cleanly (exit code 0) is not restarted.

User services can't wait for the system's network to come up at boot, so apps that connect to other hosts should retry on startup.

### Customizing the Project Root

By default, `systemd-compose ps` looks for projects in `~/systemd-compose/projects/`.
If you keep your code elsewhere (e.g., `~/Development`), configure the global environment:

1. Copy the example config:

```bash
cp ~/systemd-compose/.env.example ~/systemd-compose/.env
```

2. Edit `~/systemd-compose/.env`:

```bash
APPS_ROOT="$HOME/Development"
```

---

## 🗑 Uninstall

To remove the symlink and cleanup:

```bash
# Remove the symlink
sudo rm /usr/local/bin/systemd-compose

# (Optional) Disable background processing for your user
loginctl disable-linger $USER
```