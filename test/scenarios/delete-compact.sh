#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib.sh"

init_nexus_password

SCENARIO="delete-compact"
TRACE_DIR="${RESULTS_DIR}/${SCENARIO}"
mkdir -p "$TRACE_DIR"

echo "=== Scenario: Delete + Compact ==="

# Upload an artifact to delete
TEST_FILE=$(mktemp)
dd if=/dev/urandom of="$TEST_FILE" bs=1K count=100 2>/dev/null

nexus_curl -X PUT \
  "${NEXUS_URL}/repository/raw-hosted-test/test/to-delete.bin" \
  --upload-file "$TEST_FILE" \
  -H 'Content-Type: application/octet-stream' >/dev/null
rm -f "$TEST_FILE"

# Wait for indexing
sleep 3

# Find the component ID
COMPONENT_ID=""
for i in 1 2 3 4 5; do
  COMPONENT_ID=$(nexus_curl "${NEXUS_URL}/service/rest/v1/search?q=to-delete&repository=raw-hosted-test" 2>/dev/null \
    | jq -r '.items[0].id // empty' 2>/dev/null) || true
  [ -n "$COMPONENT_ID" ] && break
  echo "  Waiting for component to be indexed (attempt $i)..."
  sleep 2
done

if [ -z "$COMPONENT_ID" ]; then
  echo "ERROR: Could not find component to delete" >&2
  exit 1
fi

echo "Deleting component ${COMPONENT_ID}..."
start_trace "${TRACE_DIR}/delete.json"

nexus_curl -X DELETE "${NEXUS_URL}/service/rest/v1/components/${COMPONENT_ID}" >/dev/null

# Give Nexus a moment to process the soft-delete
sleep 3

stop_trace "${TRACE_DIR}/delete.json"
summarize_trace "${TRACE_DIR}/delete.json" "Delete Component" | tee "${TRACE_DIR}/delete.md"

# Check MinIO for soft-delete evidence
echo "Checking MinIO for soft-deleted objects..."
$DC exec -T minio mc ls --recursive local/nexus-blobstore/ 2>/dev/null | wc -l | xargs -I{} echo "  Total objects in bucket: {}"

echo ""
echo "NOTE: Compact blobstore task cannot be created via REST API in Nexus 3.93.2."
echo "      It must be created via the admin UI (Administration > System > Tasks)."

echo "=== Scenario complete ==="
