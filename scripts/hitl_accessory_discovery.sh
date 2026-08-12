#!/usr/bin/env bash
# Human-in-the-loop AccessorySetupKit discovery gate.

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/lib/spark_ssh.sh"

step() {
  printf '\n>>> %s\n' "$1"
  read -r -p "    [Enter when done] " _
}

capture() {
  local var="$1" question="$2" answer
  printf '\n>>> %s\n' "$question"
  read -r -p "    > " answer
  printf -v "$var" '%s' "$answer"
}

printf '%s\n' '--- Spark precondition ---'
spark_ssh '
  adapter=""
  for candidate in $(busctl tree --list org.bluez | awk "/\/hci[0-9]+$/ { print }"); do
    if busctl introspect org.bluez "$candidate" org.bluez.GattManager1 >/dev/null 2>&1 \
      && busctl introspect org.bluez "$candidate" org.bluez.LEAdvertisingManager1 >/dev/null 2>&1; then
      adapter="$candidate"
      break
    fi
  done
  test -n "$adapter"
  pgrep -af "[a]utowifi_setupd.py" || true
  busctl get-property org.bluez "$adapter" org.bluez.Adapter1 Pairable
  busctl get-property org.bluez "$adapter" org.bluez.Adapter1 Discoverable
  busctl get-property org.bluez "$adapter" org.bluez.LEAdvertisingManager1 ActiveInstances
'

step "On the iPhone, open Autowifi, tap Add DGX Spark, and wait for the picker result."
capture FOUND "Did the picker show DGX Spark? (y/n)"

paired="$({ spark_ssh 'bluetoothctl devices Paired'; } 2>&1)"

printf '\n%s\n' '--- Captured ---'
printf 'PICKER_FOUND=%s\n' "$FOUND"
printf 'BLUEZ_PAIRED=%s\n' "$paired"

if [[ "$FOUND" == "y" ]]; then
  printf '%s\n' 'RESULT=PASS'
  exit 0
fi

printf '%s\n' 'RESULT=FAIL accessory-not-discovered'
exit 1
