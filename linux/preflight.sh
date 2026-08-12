#!/usr/bin/env bash
set -u

section() {
    printf '\n[%s]\n' "$1"
}

run_if_available() {
    local command_name="$1"
    shift
    if command -v "$command_name" >/dev/null 2>&1; then
        "$command_name" "$@" 2>&1 || true
    else
        printf 'missing command: %s\n' "$command_name"
    fi
}

section system
uname -a
if [[ -r /etc/os-release ]]; then
    sed -n -E 's/^(PRETTY_NAME|VERSION_ID)=/\1=/p' /etc/os-release
fi

section versions
run_if_available bluetoothctl --version
run_if_available btmgmt --version
run_if_available nmcli --version
run_if_available busctl --version
python3 --version 2>&1 || true

section bluetooth-adapter
run_if_available bluetoothctl show
run_if_available btmgmt info

adapter_path=""
if command -v busctl >/dev/null 2>&1; then
    adapter_path="$(busctl tree --list org.bluez 2>/dev/null | awk '/\/hci[0-9]+$/ { print; exit }')"
fi
printf 'adapter_dbus_path=%s\n' "${adapter_path:-not-found}"

section bluez-managers
if [[ -n "$adapter_path" ]]; then
    for interface_name in org.bluez.GattManager1 org.bluez.LEAdvertisingManager1; do
        if busctl introspect org.bluez "$adapter_path" "$interface_name" >/dev/null 2>&1; then
            printf '%s=present\n' "$interface_name"
        else
            printf '%s=missing\n' "$interface_name"
        fi
    done
else
    printf 'No BlueZ adapter object found.\n'
fi

section networkmanager
run_if_available nmcli general status
if command -v nmcli >/dev/null 2>&1; then
    nmcli -t -f GENERAL.DEVICE,GENERAL.TYPE,GENERAL.STATE,GENERAL.DBUS-PATH device show 2>&1 || true
fi

section python-dbus
python3 - <<'PY'
from importlib.util import find_spec

for module in ("dbus", "dbus_next", "gi"):
    print(f"{module}={'present' if find_spec(module) else 'missing'}")
PY

section service-state
run_if_available systemctl is-active bluetooth.service
run_if_available systemctl is-active NetworkManager.service

printf '\nPreflight is read-only. Review the output before sharing it.\n'
