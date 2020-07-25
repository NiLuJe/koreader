#!/bin/sh

# Release IP and shutdown udhcpc.
if [ -x "/sbin/dhcpcd" ]; then
    env -u LD_LIBRARY_PATH dhcpcd -d -k "${INTERFACE}"
else
    killall udhcpc default.script 2>/dev/null
    ifconfig "${INTERFACE}" 0.0.0.0
fi
