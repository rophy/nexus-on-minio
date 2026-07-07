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

# Count objects before delete
BEFORE_DELETE=$($DC exec -T minio mc ls --recursive local/nexus-blobstore/ 2>/dev/null | wc -l)
echo "Objects before delete: ${BEFORE_DELETE}"

# Find the raw cleanup task ID (needed for phase 2)
RAW_CLEANUP_ID=$(nexus_curl "${NEXUS_URL}/service/rest/v1/tasks" 2>/dev/null \
  | jq -r '.items[] | select(.name | contains("raw")) | select(.type == "assetBlob.cleanup") | .id')

if [ -z "$RAW_CLEANUP_ID" ]; then
  echo "ERROR: Could not find raw assetBlob.cleanup task" >&2
  exit 1
fi

# Create compact task upfront (needed for phase 3)
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

# Restart MinIO to ensure mc admin trace works cleanly.
# Killing mc processes in earlier scenarios can corrupt MinIO's trace subsystem.
$DC restart minio
sleep 5

# --- Use a single long-lived trace for all three phases ---
start_trace "${TRACE_DIR}/all-phases.json"

# --- Phase 1: Delete component (soft-delete, DB only) ---
echo "Phase 1: Deleting component ${COMPONENT_ID}..."
nexus_curl -X DELETE "${NEXUS_URL}/service/rest/v1/components/${COMPONENT_ID}" >/dev/null
sleep 3

AFTER_DELETE=$($DC exec -T minio mc ls --recursive local/nexus-blobstore/ 2>/dev/null | wc -l)
echo "Objects after delete: ${AFTER_DELETE} (expected: same as before)"

# --- Phase 2: Run assetBlob.cleanup to move orphans to SoftDeletedBlobIndex ---
# Grace period is set to 0 via nexus.assetBlobCleanupTask.blobCreatedDelayMinute=0
echo ""
echo "Phase 2: Running assetBlob.cleanup task..."
nexus_curl -X POST "${NEXUS_URL}/service/rest/v1/tasks/${RAW_CLEANUP_ID}/run" >/dev/null

for i in $(seq 1 30); do
  STATE=$(nexus_curl "${NEXUS_URL}/service/rest/v1/tasks/${RAW_CLEANUP_ID}" 2>/dev/null \
    | jq -r '.currentState // "UNKNOWN"')
  [ "$STATE" = "WAITING" ] && break
  sleep 1
done
sleep 2

AFTER_CLEANUP=$($DC exec -T minio mc ls --recursive local/nexus-blobstore/ 2>/dev/null | wc -l)
echo "Objects after cleanup: ${AFTER_CLEANUP}"

# --- Phase 3: Run compact to hard-delete from S3 ---
echo ""
echo "Phase 3: Running compact task..."
nexus_curl -X POST "${NEXUS_URL}/service/rest/v1/tasks/${COMPACT_TASK_ID}/run" >/dev/null

for i in $(seq 1 30); do
  STATE=$(nexus_curl "${NEXUS_URL}/service/rest/v1/tasks/${COMPACT_TASK_ID}" 2>/dev/null \
    | jq -r '.currentState // "UNKNOWN"')
  [ "$STATE" = "WAITING" ] && break
  sleep 1
done
sleep 3

AFTER_COMPACT=$($DC exec -T minio mc ls --recursive local/nexus-blobstore/ 2>/dev/null | wc -l)

stop_trace "${TRACE_DIR}/all-phases.json"
summarize_trace "${TRACE_DIR}/all-phases.json" "Delete + Cleanup + Compact (all phases)" | tee "${TRACE_DIR}/all-phases.md"

echo "Objects after compact: ${AFTER_COMPACT}"
echo "Objects removed by compact: $((AFTER_CLEANUP - AFTER_COMPACT))"

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

echo ""
echo "Summary: before=${BEFORE_DELETE} afterDelete=${AFTER_DELETE} afterCleanup=${AFTER_CLEANUP} afterCompact=${AFTER_COMPACT}"
echo "=== Scenario complete ==="
