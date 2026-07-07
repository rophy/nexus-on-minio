#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib.sh"

init_nexus_password

SCENARIO="proxy-cache-miss"
TRACE_DIR="${RESULTS_DIR}/${SCENARIO}"
mkdir -p "$TRACE_DIR"

echo "=== Scenario: Proxy Cache Miss (Maven Central) ==="

ARTIFACT_PATH="org/apache/commons/commons-lang3/3.17.0/commons-lang3-3.17.0.pom"

echo "Fetching artifact via proxy (cache miss)..."
start_trace "${TRACE_DIR}/cache-miss.json"

nexus_curl -o /dev/null \
  "${NEXUS_URL}/repository/maven-proxy-test/${ARTIFACT_PATH}"

# Allow async S3 writes to complete
sleep 3

stop_trace "${TRACE_DIR}/cache-miss.json"
summarize_trace "${TRACE_DIR}/cache-miss.json" "Proxy Cache Miss" | tee "${TRACE_DIR}/cache-miss.md"

echo "Fetching same artifact again (cache hit)..."
start_trace "${TRACE_DIR}/cache-hit.json"

nexus_curl -o /dev/null \
  "${NEXUS_URL}/repository/maven-proxy-test/${ARTIFACT_PATH}"

stop_trace "${TRACE_DIR}/cache-hit.json"
summarize_trace "${TRACE_DIR}/cache-hit.json" "Proxy Cache Hit" | tee "${TRACE_DIR}/cache-hit.md"

echo "=== Scenario complete ==="
