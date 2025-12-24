#!/bin/bash

# 1. Load Settings (Just to be consistent, though not strictly needed for tail)
if [ ! -f ./app.settings ]; then echo "Error: app.settings not found"; exit 1; fi
source ./app.settings

echo "--- Streaming logs for $APP_NAME (Press Ctrl+C to exit) ---"

# 2. Tail both files
# The -F flag follows the file even if it gets rotated or recreated
tail -F -n 20 app.log error.log