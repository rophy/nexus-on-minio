#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib.sh"

init_nexus_password

SCENARIO="raw-upload-download"
TRACE_DIR="${RESULTS_DIR}/${SCENARIO}"
mkdir -p "$TRACE_DIR"

echo "=== Scenario: Raw Upload + Download ==="

TEST_FILE=$(mktemp)
dd if=/dev/urandom of="$TEST_FILE" bs=1K count=1024 2>/dev/null

# --- Upload ---
echo "Uploading 1MB raw artifact..."
start_trace "${TRACE_DIR}/upload.json"

nexus_curl -X PUT \
  "${NEXUS_URL}/repository/raw-hosted-test/test/artifact-1.bin" \
  --upload-file "$TEST_FILE" \
  -H 'Content-Type: application/octet-stream' >/dev/null

stop_trace "${TRACE_DIR}/upload.json"
summarize_trace "${TRACE_DIR}/upload.json" "Raw Upload (1MB)" | tee "${TRACE_DIR}/upload.md"

# --- Download ---
echo "Downloading raw artifact..."
start_trace "${TRACE_DIR}/download.json"

nexus_curl -o /dev/null \
  "${NEXUS_URL}/repository/raw-hosted-test/test/artifact-1.bin"

stop_trace "${TRACE_DIR}/download.json"
summarize_trace "${TRACE_DIR}/download.json" "Raw Download (1MB)" | tee "${TRACE_DIR}/download.md"

# --- Re-download ---
echo "Re-downloading raw artifact..."
start_trace "${TRACE_DIR}/redownload.json"

nexus_curl -o /dev/null \
  "${NEXUS_URL}/repository/raw-hosted-test/test/artifact-1.bin"

stop_trace "${TRACE_DIR}/redownload.json"
summarize_trace "${TRACE_DIR}/redownload.json" "Raw Re-download (1MB)" | tee "${TRACE_DIR}/redownload.md"

rm -f "$TEST_FILE"
echo "=== Scenario complete ==="
