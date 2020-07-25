#!/bin/sh

# Disable wifi, and remove all modules.
if [ -x "/sbin/dhcpcd" ]; then
    env -u LD_LIBRARY_PATH dhcpcd -d -k "${INTERFACE}"
else
    killall udhcpc default.script 2>/dev/null
fi
wpa_cli terminate

[ "${WIFI_MODULE}" != "8189fs" ] && [ "${WIFI_MODULE}" != "8192es" ] && wlarm_le -i "${INTERFACE}" down
ifconfig "${INTERFACE}" down

# Some sleep in between may avoid system getting hung
# (we test if a module is actually loaded to avoid unneeded sleeps)
if lsmod | grep -q "${WIFI_MODULE}"; then
    usleep 250000
    rmmod "${WIFI_MODULE}"
fi
if lsmod | grep -q sdio_wifi_pwr; then
    usleep 250000
    rmmod sdio_wifi_pwr
fi
