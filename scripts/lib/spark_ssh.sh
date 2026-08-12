#!/usr/bin/env bash
# Shared SSH boundary for Spark-side diagnostic scripts.

spark_ssh() {
  local spark_host="${AUTOWIFI_SPARK_HOST:-}"

  if [[ -z "$spark_host" ]]; then
    printf '%s\n' \
      'Set AUTOWIFI_SPARK_HOST to an SSH target (for example, user@spark-host).' >&2
    return 64
  fi
  if [[ -n "${AUTOWIFI_SPARK_HOSTNAME:-}" ]]; then
    command ssh -o "HostName=$AUTOWIFI_SPARK_HOSTNAME" "$spark_host" "$@"
    return
  fi

  command ssh "$spark_host" "$@"
}
