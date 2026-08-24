#!/usr/bin/env bash
# Install and start Autowifi without changing NetworkManager connections.

set -euo pipefail

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  printf '%s\n' 'Run this installer as root (for example: sudo scripts/install_spark.sh).' >&2
  exit 64
fi

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
install_root="/opt/autowifi"
service_name="autowifi-setupd.service"

# Refuse a mixed deployment where the config and generated BLE identifiers differ.
# Such a mismatch makes a healthy daemon invisible to the iOS picker.
PYTHONDONTWRITEBYTECODE=1 python3 "$project_root/tools/generate_constants.py" --check

install -d -m 0755 "$install_root"
for source in \
  autowifi_protocol.py \
  bluez_gatt.py \
  generated_constants.py \
  network_manager.py \
  network_manager_dbus.py \
  ownership_policy.py \
  product_identity.py; do
  install -m 0644 "$project_root/linux/$source" "$install_root/$source"
done
install -m 0755 "$project_root/linux/autowifi_setupd.py" "$install_root/autowifi_setupd.py"
install -m 0644 \
  "$project_root/packaging/$service_name" \
  "/etc/systemd/system/$service_name"

# Replace only the legacy manually launched Autowifi daemon. NetworkManager and
# its active Wi-Fi connection are deliberately left untouched.
if ! systemctl is-active --quiet "$service_name"; then
  legacy_pids="$(pgrep -f '[a]utowifi_setupd.py' || true)"
  if [[ -n "$legacy_pids" ]]; then
    kill $legacy_pids
    for _ in 1 2 3 4 5; do
      [[ -z "$(pgrep -f '[a]utowifi_setupd.py' || true)" ]] && break
      sleep 1
    done
    if [[ -n "$(pgrep -f '[a]utowifi_setupd.py' || true)" ]]; then
      printf '%s\n' 'The manually launched Autowifi daemon did not stop.' >&2
      exit 1
    fi
  fi
fi

systemctl daemon-reload
systemctl enable "$service_name"
systemctl restart "$service_name"
systemctl --no-pager --full status "$service_name"
