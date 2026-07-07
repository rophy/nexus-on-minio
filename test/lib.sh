#!/usr/bin/env bash
set -euo pipefail

# --- Configuration ---
NEXUS_USER="admin"
NEXUS_PASS=""
NEXUS_NEW_PASS="admin123"
MINIO_ALIAS="local"
RESULTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/results"

DC="docker compose"

init_nexus_password() {
  NEXUS_IP=$($DC exec -T nexus hostname -i 2>/dev/null | tr -d '[:space:]')
  NEXUS_URL="http://${NEXUS_IP}:8081"

  # Try new password first (already onboarded)
  if curl -sf -u "${NEXUS_USER}:${NEXUS_NEW_PASS}" "${NEXUS_URL}/service/rest/v1/status/writable" >/dev/null 2>&1; then
    NEXUS_PASS="${NEXUS_NEW_PASS}"
    return
  fi

  # First-time setup: read initial password, change it, accept EULA
  NEXUS_PASS=$($DC exec -T nexus cat /nexus-data/admin.password 2>/dev/null) || {
    echo "ERROR: Could not read admin password. Has Nexus started?" >&2
    exit 1
  }

  echo "Completing first-time setup..."
  curl -sf -u "${NEXUS_USER}:${NEXUS_PASS}" -X PUT \
    "${NEXUS_URL}/service/rest/v1/security/users/admin/change-password" \
    -H 'Content-Type: text/plain' \
    -d "${NEXUS_NEW_PASS}" >/dev/null

  NEXUS_PASS="${NEXUS_NEW_PASS}"

  # Accept EULA
  local eula
  eula=$(nexus_curl "${NEXUS_URL}/service/rest/v1/system/eula" 2>/dev/null) || true
  if [ -n "$eula" ]; then
    echo "$eula" | jq '.accepted = true' | nexus_curl -X POST \
      "${NEXUS_URL}/service/rest/v1/system/eula" \
      -H 'Content-Type: application/json' \
      -d @- >/dev/null 2>&1 || true
  fi
  echo "First-time setup complete."
}

nexus_curl() {
  curl -sf -u "${NEXUS_USER}:${NEXUS_PASS}" "$@"
}

wait_for_nexus() {
  echo "Waiting for Nexus to start..."
  until $DC exec -T nexus curl -sf http://localhost:8081/service/rest/v1/status >/dev/null 2>&1; do
    sleep 5
  done
  echo "Nexus is ready."
}

# --- Trace capture ---
start_trace() {
  local trace_file="$1"
  # Kill any leftover mc processes from previous traces
  $DC exec -T minio sh -c '
    for p in /proc/[0-9]*/cmdline; do
      if grep -ql "mc" "$p" 2>/dev/null; then
        pid=$(echo "$p" | grep -o "[0-9]*")
        kill "$pid" 2>/dev/null || true
      fi
    done
  ' 2>/dev/null
  sleep 1
  $DC exec -T minio mc alias set "$MINIO_ALIAS" http://localhost:9000 minioadmin minioadmin >/dev/null 2>&1
  $DC exec -T minio rm -f /tmp/trace.json
  $DC exec -d minio sh -c "exec mc admin trace --call s3 --json ${MINIO_ALIAS} > /tmp/trace.json 2>/dev/null"
  sleep 2
}

stop_trace() {
  local trace_file="$1"
  # kill mc processes inside the container (no pidof/pkill available)
  $DC exec -T minio sh -c '
    for p in /proc/[0-9]*/cmdline; do
      if grep -ql "mc" "$p" 2>/dev/null; then
        pid=$(echo "$p" | grep -o "[0-9]*")
        kill "$pid" 2>/dev/null || true
      fi
    done
  '
  sleep 1
  mkdir -p "$(dirname "$trace_file")"
  $DC cp minio:/tmp/trace.json "$trace_file" 2>/dev/null || echo '{}' > "$trace_file"
  $DC exec -T minio rm -f /tmp/trace.json
}

summarize_trace() {
  local trace_file="$1"
  local label="$2"

  echo ""
  echo "### ${label}"
  echo ""

  if [ ! -s "$trace_file" ]; then
    echo "**Total S3 calls: 0**"
    echo ""
    return
  fi

  echo "| S3 API Call | Count | Total Bytes (RX) | Total Bytes (TX) |"
  echo "|---|---|---|---|"
  jq -r '
    select(.api != null) |
    [.api, (.callStats.rx // 0), (.callStats.tx // 0)] | @tsv
  ' "$trace_file" 2>/dev/null \
    | sort \
    | awk -F'\t' '
      { count[$1]++; rx[$1]+=$2; tx[$1]+=$3 }
      END {
        for (api in count)
          printf "| %s | %d | %d | %d |\n", api, count[api], rx[api], tx[api]
      }
    ' \
    | sort -t'|' -k3 -rn
  echo ""
  local total
  total=$(jq -s '[.[] | select(.api != null)] | length' "$trace_file" 2>/dev/null || echo 0)
  echo "**Total S3 calls: ${total}**"
  echo ""
}
