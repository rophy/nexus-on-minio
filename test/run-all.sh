#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

REPORT="${RESULTS_DIR}/report.md"
mkdir -p "$RESULTS_DIR"

echo "============================================="
echo " Nexus-on-MinIO S3 Overhead Test Suite"
echo "============================================="
echo ""

# Pre-flight checks
echo "Pre-flight checks..."
$DC ps --format '{{.Service}}\t{{.State}}'
echo ""

wait_for_nexus
init_nexus_password
echo "Nexus URL: ${NEXUS_URL}"
echo ""

# Setup
echo "--- Setting up test repositories ---"
bash "${SCRIPT_DIR}/setup-repos.sh"
echo ""

# Count objects before
BEFORE_COUNT=$($DC exec -T minio mc ls --recursive --summarize local/nexus-blobstore 2>/dev/null \
  | grep "Total Objects:" | awk '{print $3}') || BEFORE_COUNT=0
echo "MinIO objects before tests: ${BEFORE_COUNT}"
echo ""

# Run scenarios
SCENARIOS=(
  "raw-upload-download"
  "maven-crud"
  "npm-crud"
  "pypi-crud"
  "cargo-crud"
  "helm-crud"
  "proxy-cache-miss"
  "browse-search"
  "delete-compact"
)

for scenario in "${SCENARIOS[@]}"; do
  echo "============================================="
  echo " Running: ${scenario}"
  echo "============================================="
  bash "${SCRIPT_DIR}/scenarios/${scenario}.sh"
  echo ""
done

# Count objects after
AFTER_COUNT=$($DC exec -T minio mc ls --recursive --summarize local/nexus-blobstore 2>/dev/null \
  | grep "Total Objects:" | awk '{print $3}') || AFTER_COUNT=0
echo "MinIO objects after tests: ${AFTER_COUNT}"
echo ""

# Generate combined report
echo "Generating report..."
{
  echo "# Nexus-on-MinIO S3 Overhead Test Report"
  echo ""
  echo "**Date:** $(date -u '+%Y-%m-%d %H:%M UTC')"
  echo "**Nexus version:** 3.93.2"
  echo "**MinIO image:** minio/minio:latest"
  echo ""
  echo "**MinIO object count:** before=${BEFORE_COUNT}, after=${AFTER_COUNT}"
  echo ""
  echo "---"
  echo ""

  for scenario in "${SCENARIOS[@]}"; do
    scenario_dir="${RESULTS_DIR}/${scenario}"
    if [ -d "$scenario_dir" ]; then
      echo "## ${scenario}"
      echo ""
      for md_file in "${scenario_dir}"/*.md; do
        [ -f "$md_file" ] && cat "$md_file"
      done
      echo "---"
      echo ""
    fi
  done
} > "$REPORT"

echo "Report written to: ${REPORT}"
echo ""
echo "============================================="
echo " All tests complete."
echo "============================================="
