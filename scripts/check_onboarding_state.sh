#!/usr/bin/env bash
# Assert the BlueZ ownership invariant without changing Bluetooth or Wi-Fi.

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/lib/spark_ssh.sh"

state="$(spark_ssh '
  adapter=""
  for candidate in $(busctl tree --list org.bluez | awk "/\/hci[0-9]+$/ { print }"); do
    if busctl introspect org.bluez "$candidate" org.bluez.GattManager1 >/dev/null 2>&1 \
      && busctl introspect org.bluez "$candidate" org.bluez.LEAdvertisingManager1 >/dev/null 2>&1; then
      adapter="$candidate"
      break
    fi
  done
  test -n "$adapter"
  bonded=$(bluetoothctl devices Paired | wc -l)
  pairable=$(busctl get-property org.bluez "$adapter" org.bluez.Adapter1 Pairable | awk "{print \$2}")
  active_instances=$(busctl get-property org.bluez "$adapter" org.bluez.LEAdvertisingManager1 ActiveInstances | awk "{print \$2}")
  daemon_count=$(pgrep -fc "[a]utowifi_setupd.py")
  printf "%s|%s|%s|%s\n" "$bonded" "$pairable" "$active_instances" "$daemon_count"
')"
IFS='|' read -r bonded pairable active_instances daemon_count <<EOF
$state
EOF

printf 'bonded=%s pairable=%s advertisements=%s daemons=%s\n' \
  "$bonded" "$pairable" "$active_instances" "$daemon_count"

if [[ "$daemon_count" -ne 1 || "$active_instances" -lt 1 ]]; then
  printf '%s\n' 'RESULT=FAIL transport-unavailable'
  exit 1
fi

if [[ "$bonded" -eq 0 && "$pairable" != true ]]; then
  printf '%s\n' 'RESULT=FAIL unowned-but-not-pairable'
  exit 1
fi

if [[ "$bonded" -gt 0 && "$pairable" != false ]]; then
  printf '%s\n' 'RESULT=FAIL owned-but-pairable'
  exit 1
fi

printf '%s\n' 'RESULT=PASS ownership-invariant'
