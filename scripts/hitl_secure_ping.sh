#!/usr/bin/env bash
set -euo pipefail

device_id="${1:?usage: hitl_secure_ping.sh <CoreDevice identifier>}"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/lib/spark_ssh.sh"

ping_count() {
    spark_ssh \
      "awk '/Autowifi secure transport request completed/{count++} END{print count+0}' /tmp/autowifi-setupd.log"
}

before="$(ping_count)"
xcrun devicectl device process launch \
    --device "$device_id" \
    --terminate-existing \
    --environment-variables '{"AUTOWIFI_AUTOMATIC_PROBE":"1"}' \
    --timeout 10 \
    com.enfipy.autowifi >/dev/null
sleep 5
after="$(ping_count)"

if ((after > before)); then
    echo "GREEN: encrypted BLE ping/pong succeeded"
    exit 0
fi

echo "RED: Spark did not acknowledge an encrypted BLE ping" >&2
exit 1
