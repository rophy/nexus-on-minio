#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib.sh"

init_nexus_password

SCENARIO="maven-upload"
TRACE_DIR="${RESULTS_DIR}/${SCENARIO}"
mkdir -p "$TRACE_DIR"

echo "=== Scenario: Maven Multi-file Artifact Upload ==="

GAV_PATH="com/example/test-lib/1.0.0"
BASE_URL="${NEXUS_URL}/repository/maven-hosted-test/${GAV_PATH}"

TMP_DIR=$(mktemp -d)
dd if=/dev/urandom of="${TMP_DIR}/test-lib-1.0.0.jar" bs=1K count=512 2>/dev/null

cat > "${TMP_DIR}/test-lib-1.0.0.pom" << 'POMEOF'
<?xml version="1.0" encoding="UTF-8"?>
<project>
  <modelVersion>4.0.0</modelVersion>
  <groupId>com.example</groupId>
  <artifactId>test-lib</artifactId>
  <version>1.0.0</version>
  <packaging>jar</packaging>
</project>
POMEOF

echo "Uploading Maven artifact (jar + pom)..."
start_trace "${TRACE_DIR}/upload.json"

nexus_curl -X PUT "${BASE_URL}/test-lib-1.0.0.jar" \
  --upload-file "${TMP_DIR}/test-lib-1.0.0.jar" \
  -H 'Content-Type: application/java-archive' >/dev/null

nexus_curl -X PUT "${BASE_URL}/test-lib-1.0.0.pom" \
  --upload-file "${TMP_DIR}/test-lib-1.0.0.pom" \
  -H 'Content-Type: application/xml' >/dev/null

stop_trace "${TRACE_DIR}/upload.json"
summarize_trace "${TRACE_DIR}/upload.json" "Maven Upload (jar + pom)" | tee "${TRACE_DIR}/upload.md"

rm -rf "$TMP_DIR"
echo "=== Scenario complete ==="
