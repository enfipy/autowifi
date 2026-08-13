#!/usr/bin/env bash
# Install Autowifi as a lingering user service without changing Wi-Fi state.

set -euo pipefail

if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
  printf '%s\n' 'Run this installer as the regular Spark user, without sudo.' >&2
  exit 64
fi

linger="$(loginctl show-user "$(id -un)" --property=Linger --value 2>/dev/null || true)"
if [[ "$linger" != "yes" ]]; then
  printf '%s\n' \
    'User lingering is disabled; use sudo scripts/install_spark.sh instead.' >&2
  exit 69
fi

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
install_root="$HOME/.local/lib/autowifi"
unit_root="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
service_name="autowifi-setupd.service"

# Do not install stale generated BLE identifiers that the iOS picker cannot match.
PYTHONDONTWRITEBYTECODE=1 python3 "$project_root/tools/generate_constants.py" --check

if systemctl is-active --quiet "$service_name"; then
  printf '%s\n' \
    'The root Autowifi service is already active; no user service is needed.' >&2
  exit 69
fi

install -d -m 0755 "$install_root" "$unit_root"
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
  "$project_root/packaging/autowifi-setupd.user.service" \
  "$unit_root/$service_name"

# Stop only the legacy foreground daemon before systemd takes ownership. This
# intentionally leaves NetworkManager and its active Wi-Fi connection alone.
if ! systemctl --user is-active --quiet "$service_name"; then
  legacy_pids="$(pgrep -u "$(id -u)" -f '[a]utowifi_setupd.py' || true)"
  if [[ -n "$legacy_pids" ]]; then
    kill $legacy_pids
    for _ in 1 2 3 4 5; do
      [[ -z "$(pgrep -u "$(id -u)" -f '[a]utowifi_setupd.py' || true)" ]] && break
      sleep 1
    done
    if [[ -n "$(pgrep -u "$(id -u)" -f '[a]utowifi_setupd.py' || true)" ]]; then
      printf '%s\n' 'The manually launched Autowifi daemon did not stop.' >&2
      exit 1
    fi
  fi
fi

systemctl --user daemon-reload
systemctl --user enable "$service_name"
systemctl --user restart "$service_name"
systemctl --user --no-pager --full status "$service_name"
