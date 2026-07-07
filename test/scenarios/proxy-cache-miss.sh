#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib.sh"

init_nexus_password

SCENARIO="proxy-cache-miss"
TRACE_DIR="${RESULTS_DIR}/${SCENARIO}"
mkdir -p "$TRACE_DIR"

echo "=== Scenario: Proxy Cache Miss (Maven Central) ==="

# Warmup: trigger the one-time blobstore health check before measuring.
# The first-ever fetch from a proxy repo causes a ListObjectsV2 on
# content/directpath/health-check/<repo-name> that is unrelated to the
# cache miss itself.
WARMUP_ARTIFACT="org/apache/commons/commons-lang3/3.17.0/commons-lang3-3.17.0.pom"
echo "Warming up proxy repo (triggers one-time health check)..."
nexus_curl -o /dev/null \
  "${NEXUS_URL}/repository/maven-proxy-test/${WARMUP_ARTIFACT}"
sleep 3

# Now measure a real cache miss without the health-check noise
ARTIFACT="org/slf4j/slf4j-api/2.0.16/slf4j-api-2.0.16.pom"

echo "Fetching artifact via proxy (cache miss)..."
start_trace "${TRACE_DIR}/cache-miss.json"

nexus_curl -o /dev/null \
  "${NEXUS_URL}/repository/maven-proxy-test/${ARTIFACT}"

# Allow async S3 writes to complete
sleep 3

stop_trace "${TRACE_DIR}/cache-miss.json"
summarize_trace "${TRACE_DIR}/cache-miss.json" "Proxy Cache Miss" | tee "${TRACE_DIR}/cache-miss.md"

echo "Fetching same artifact again (cache hit)..."
start_trace "${TRACE_DIR}/cache-hit.json"

nexus_curl -o /dev/null \
  "${NEXUS_URL}/repository/maven-proxy-test/${ARTIFACT}"

stop_trace "${TRACE_DIR}/cache-hit.json"
summarize_trace "${TRACE_DIR}/cache-hit.json" "Proxy Cache Hit" | tee "${TRACE_DIR}/cache-hit.md"

echo "=== Scenario complete ==="
