```markdown
# App-Ctl

A **rootless**, **Docker-like** process manager for Python applications on Debian/Ubuntu systems.

App-Ctl allows you to manage Python projects (Flask, FastAPI, scripts, bots) using a familiar workflow (`build`, `up`, `down`, `logs`) without the overhead or complexity of Docker containers. It leverages native Linux tools (`systemd --user`, `venv`, `pip`) to ensure your apps are robust, isolated, and auto-start on boot—all without needing `sudo` for day-to-day operations.

## ✨ Features

* **Rootless Architecture:** Runs entirely in userspace using `systemd --user`.
* **Docker-like CLI:** Commands like `up`, `down`, `ps`, and `logs` make it easy to learn.
* **Isolated Environments:** Automatically creates and manages Python `venvs` for each project.
* **Zero-Downtime Config:** Change secrets in `.env` and restart instantly.
* **Flexible:** Supports standard Python scripts, Uvicorn (FastAPI), and Gunicorn out of the box.
* **Global Dashboard:** View the status of all your apps with a single `ps` command.

---

## 🚀 Installation

### 1. Clone & Setup
Clone this repository to your home directory (recommended location: `~/app-ctl`).

```bash
git clone <your-repo-url> ~/app-ctl
cd ~/app-ctl

```

### 2. Run Host Setup

This script installs necessary system dependencies (like `python3-venv`, `git`, `lsof`), enables systemd lingering (so apps run after logout), and links the binary to your path.

```bash
./host-setup.sh

```

**Note:** You will need `sudo` access only once during this step to install the Debian packages.

### 3. Verify

You can now run `app-ctl` from anywhere.

```bash
app-ctl --help

```

---

## 🛠 Usage

### Creating a New Project

You can copy the included example to get started.

```bash
cp -r ~/app-ctl/projects/example-app ~/my-new-bot
cd ~/my-new-bot

```

### The Workflow

| Command | Description |
| --- | --- |
| `app-ctl . build` | Creates the `venv` and installs `requirements.txt`. |
| `app-ctl . run` | Generates the Systemd service and starts the app. |
| `app-ctl . up` | **Recommended.** Runs `build` + `run` (like `docker-compose up`). |
| `app-ctl . stop` | Stops the process (preserves venv and logs). |
| `app-ctl . down` | Stops the process, removes the service, and **deletes the venv**. |
| `app-ctl . logs` | Tails the real-time logs of the application. |
| `app-ctl . status` | Shows detailed status (PID, Memory, Port connectivity). |

### Global Dashboard

To see all running projects managed by App-Ctl:

```bash
app-ctl ps

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

```

### 2. `.env` (Secrets & Local Config)

This file defines *how* to run (Ports, Keys). **Add this to `.gitignore**`.

```bash
PORT=8000
SECRET_KEY=super_secret_value

```

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

### Customizing the Project Root

By default, `app-ctl ps` looks for projects in `~/app-ctl/projects/`.
If you keep your code elsewhere (e.g., `~/Development`), configure the global environment:

1. Copy the example config:
```bash
cp ~/app-ctl/.env.example ~/app-ctl/.env

```


2. Edit `~/app-ctl/.env`:
```bash
APPS_ROOT="$HOME/Development"

```



---

## 🗑 Uninstall

To remove the symlink and cleanup:

```bash
# Remove the symlink
sudo rm /usr/local/bin/app-ctl

# (Optional) Disable background processing for your user
loginctl disable-linger $USER

```