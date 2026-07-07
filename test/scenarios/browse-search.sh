#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib.sh"

init_nexus_password

SCENARIO="browse-search"
TRACE_DIR="${RESULTS_DIR}/${SCENARIO}"
mkdir -p "$TRACE_DIR"

echo "=== Scenario: Browse & Search ==="

echo "Browsing components via REST API..."
start_trace "${TRACE_DIR}/browse-components.json"

nexus_curl "${NEXUS_URL}/service/rest/v1/components?repository=raw-hosted-test" >/dev/null

stop_trace "${TRACE_DIR}/browse-components.json"
summarize_trace "${TRACE_DIR}/browse-components.json" "Browse Components (REST API)" | tee "${TRACE_DIR}/browse-components.md"

echo "Browsing assets via REST API..."
start_trace "${TRACE_DIR}/browse-assets.json"

nexus_curl "${NEXUS_URL}/service/rest/v1/assets?repository=raw-hosted-test" >/dev/null

stop_trace "${TRACE_DIR}/browse-assets.json"
summarize_trace "${TRACE_DIR}/browse-assets.json" "Browse Assets (REST API)" | tee "${TRACE_DIR}/browse-assets.md"

echo "Searching for artifact by keyword..."
start_trace "${TRACE_DIR}/search.json"

nexus_curl "${NEXUS_URL}/service/rest/v1/search?q=artifact-1&repository=raw-hosted-test" >/dev/null

stop_trace "${TRACE_DIR}/search.json"
summarize_trace "${TRACE_DIR}/search.json" "Search by keyword" | tee "${TRACE_DIR}/search.md"

echo "=== Scenario complete ==="
