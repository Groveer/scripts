#!/bin/bash

# Check if a username is provided as an argument
if [ $# -lt 1 ]; then
    echo "Usage: $0 <username>"
    exit 1
fi

USERNAME=$1

# Get the UID of the user
USER_ID=$(id -u "$USERNAME" 2>/dev/null)

if [ $? -ne 0 ]; then
    echo "Error: User '$USERNAME' not found."
    exit 2
fi

# Construct the user.slice path
USER_SLICE="user.slice/user-$USER_ID.slice"

# Use systemd-cgtop to monitor memory usage for the user slice
echo "Monitoring memory usage for $USER_SLICE..."
while true; do
    echo "$(date)" >> 1.log
    systemd-cgtop -m "$USER_SLICE" >> 1.log
    echo "Printed the log to 1.log"
    sleep 1
done

