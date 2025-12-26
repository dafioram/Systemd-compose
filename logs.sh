#!/bin/bash
source ./lib.sh

echo "--- Streaming logs for $APP_NAME ---"
tail -F -n 20 app.log error.log
