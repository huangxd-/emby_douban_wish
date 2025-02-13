#!/bin/bash

SERVICE="emby-server"

status=$(systemctl is-active $SERVICE)

if [ "$status" != "active" ]; then
    echo "Service $SERVICE is not running. Starting it now..."
    systemctl start $SERVICE
else
    echo "Service $SERVICE is running."
fi
