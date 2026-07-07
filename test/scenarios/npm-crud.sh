#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib.sh"

init_nexus_password

SCENARIO="npm-crud"
TRACE_DIR="${RESULTS_DIR}/${SCENARIO}"
mkdir -p "$TRACE_DIR"

echo "=== Scenario: npm CRUD ==="

TMP_DIR=$(mktemp -d)

# Build a minimal npm package tarball
# npm expects: package/<files> inside the tarball
mkdir -p "${TMP_DIR}/package"
cat > "${TMP_DIR}/package/package.json" << 'EOF'
{
  "name": "@test/npm-pkg",
  "version": "1.0.0",
  "description": "test package for S3 overhead measurement"
}
EOF
dd if=/dev/urandom of="${TMP_DIR}/package/index.js" bs=1K count=10 2>/dev/null
tar czf "${TMP_DIR}/npm-pkg-1.0.0.tgz" -C "${TMP_DIR}" package

TARBALL=$(base64 -w0 "${TMP_DIR}/npm-pkg-1.0.0.tgz")
TARBALL_SIZE=$(stat -c%s "${TMP_DIR}/npm-pkg-1.0.0.tgz")

# npm publish payload
cat > "${TMP_DIR}/publish.json" << PUBEOF
{
  "_id": "@test/npm-pkg",
  "name": "@test/npm-pkg",
  "versions": {
    "1.0.0": {
      "name": "@test/npm-pkg",
      "version": "1.0.0",
      "description": "test package",
      "dist": {
        "tarball": "http://localhost:8081/repository/npm-hosted-test/@test/npm-pkg/-/npm-pkg-1.0.0.tgz"
      }
    }
  },
  "_attachments": {
    "npm-pkg-1.0.0.tgz": {
      "content_type": "application/octet-stream",
      "data": "${TARBALL}",
      "length": ${TARBALL_SIZE}
    }
  }
}
PUBEOF

# --- Upload ---
echo "Publishing npm package..."
start_trace "${TRACE_DIR}/upload.json"

nexus_curl -X PUT \
  "${NEXUS_URL}/repository/npm-hosted-test/@test/npm-pkg" \
  -H 'Content-Type: application/json' \
  -d @"${TMP_DIR}/publish.json" >/dev/null

stop_trace "${TRACE_DIR}/upload.json"
summarize_trace "${TRACE_DIR}/upload.json" "npm Publish" | tee "${TRACE_DIR}/upload.md"

# --- Download tarball ---
echo "Downloading npm tarball..."
start_trace "${TRACE_DIR}/download.json"

nexus_curl -o /dev/null \
  "${NEXUS_URL}/repository/npm-hosted-test/@test/npm-pkg/-/npm-pkg-1.0.0.tgz"

stop_trace "${TRACE_DIR}/download.json"
summarize_trace "${TRACE_DIR}/download.json" "npm Download (tarball)" | tee "${TRACE_DIR}/download.md"

# --- Re-download ---
echo "Re-downloading npm tarball..."
start_trace "${TRACE_DIR}/redownload.json"

nexus_curl -o /dev/null \
  "${NEXUS_URL}/repository/npm-hosted-test/@test/npm-pkg/-/npm-pkg-1.0.0.tgz"

stop_trace "${TRACE_DIR}/redownload.json"
summarize_trace "${TRACE_DIR}/redownload.json" "npm Re-download (tarball)" | tee "${TRACE_DIR}/redownload.md"

rm -rf "$TMP_DIR"
echo "=== Scenario complete ==="
