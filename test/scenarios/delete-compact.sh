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

# Create the compact task via ExtDirect API (REST API POST /v1/tasks returns 405)
echo "Creating compact blobstore task via ExtDirect API..."
COMPACT_RESULT=$(curl -sf -u "${NEXUS_USER}:${NEXUS_PASS}" -X POST "${NEXUS_URL}/service/extdirect" \
  -H 'Content-Type: application/json' \
  -d '{
    "action": "coreui_Task",
    "method": "create",
    "data": [{
      "typeId": "blobstore.compact",
      "enabled": true,
      "name": "Compact minio blobstore (test)",
      "notificationCondition": "FAILURE",
      "schedule": "manual",
      "properties": {
        "blobstoreName": "minio"
      }
    }],
    "type": "rpc",
    "tid": 1
  }' 2>/dev/null)

COMPACT_TASK_ID=$(echo "$COMPACT_RESULT" | jq -r '.result.data.id // empty')
if [ -z "$COMPACT_TASK_ID" ]; then
  echo "ERROR: Could not create compact task" >&2
  echo "$COMPACT_RESULT" | jq .
  exit 1
fi
echo "  Created compact task: ${COMPACT_TASK_ID}"

# Count objects before compact
BEFORE_COUNT=$($DC exec -T minio mc ls --recursive local/nexus-blobstore/ 2>/dev/null | wc -l)
echo "  Objects before compact: ${BEFORE_COUNT}"

# Run the compact task with trace
echo "Running compact task..."
start_trace "${TRACE_DIR}/compact.json"

nexus_curl -X POST "${NEXUS_URL}/service/rest/v1/tasks/${COMPACT_TASK_ID}/run" >/dev/null

# Wait for task to complete
for i in $(seq 1 30); do
  STATE=$(nexus_curl "${NEXUS_URL}/service/rest/v1/tasks/${COMPACT_TASK_ID}" 2>/dev/null \
    | jq -r '.currentState // "UNKNOWN"')
  [ "$STATE" = "WAITING" ] && break
  sleep 1
done

stop_trace "${TRACE_DIR}/compact.json"
summarize_trace "${TRACE_DIR}/compact.json" "Compact Blobstore" | tee "${TRACE_DIR}/compact.md"

# Count objects after compact
AFTER_COUNT=$($DC exec -T minio mc ls --recursive local/nexus-blobstore/ 2>/dev/null | wc -l)
echo "  Objects after compact: ${AFTER_COUNT}"
echo "  Objects removed: $((BEFORE_COUNT - AFTER_COUNT))"
echo ""
echo "NOTE: Compact may report 0 objects removed because the assetBlob.cleanup"
echo "      task has a grace period (default 60 min) before orphaned blobs become"
echo "      eligible for compaction. The two-stage process is:"
echo "      1. assetBlob.cleanup (cron) -> moves orphaned blobs to SoftDeletedBlobIndex"
echo "      2. blobstore.compact (manual) -> issues S3 DeleteObject for indexed blobs"

# Clean up the test task
curl -sf -u "${NEXUS_USER}:${NEXUS_PASS}" -X POST "${NEXUS_URL}/service/extdirect" \
  -H 'Content-Type: application/json' \
  -d "{
    \"action\": \"coreui_Task\",
    \"method\": \"remove\",
    \"data\": [\"${COMPACT_TASK_ID}\"],
    \"type\": \"rpc\",
    \"tid\": 2
  }" >/dev/null 2>&1 || true

echo "=== Scenario complete ==="
