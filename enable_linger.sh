#!/bin/bash

USER_NAME=$(id -un)

if loginctl show-user "$USER_NAME" | grep -q 'Linger=yes'; then
    echo "Linger already enabled for $USER_NAME"
else
    echo "Enabling linger for $USER_NAME"
    sudo loginctl enable-linger "$USER_NAME"
fi