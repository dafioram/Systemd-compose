#!/bin/bash
set -e

if [ "$EUID" -ne 0 ]; then
    echo "Run as root"
    exit 1
fi

echo "--- Installing Debian Python dependencies ---"

apt update
apt install -y python3 python3-venv python3-pip

echo "Dependencies installed"