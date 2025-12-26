#!/bin/bash
set -e
source ./lib.sh

echo "--- Restarting $APP_NAME ---"

if [ -d .git ]; then
    echo "Pulling latest changes..."
    git pull || true
fi

./up.sh

echo "Success: $APP_NAME restarted"
