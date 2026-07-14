#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib.sh"

init_nexus_password

SCENARIO="cargo-crud"
TRACE_DIR="${RESULTS_DIR}/${SCENARIO}"
mkdir -p "$TRACE_DIR"

echo "=== Scenario: Cargo CRUD ==="

TMP_DIR=$(mktemp -d)

CRATE_NAME="test-crate"
CRATE_VERSION="0.1.0"

# Build a minimal .crate file (gzipped tarball with Cargo.toml + src/lib.rs)
mkdir -p "${TMP_DIR}/${CRATE_NAME}-${CRATE_VERSION}/src"
cat > "${TMP_DIR}/${CRATE_NAME}-${CRATE_VERSION}/Cargo.toml" << EOF
[package]
name = "${CRATE_NAME}"
version = "${CRATE_VERSION}"
edition = "2021"
description = "A test crate for S3 overhead measurement"
license = "MIT"
EOF

cat > "${TMP_DIR}/${CRATE_NAME}-${CRATE_VERSION}/src/lib.rs" << 'EOF'
pub fn hello() -> &'static str {
    "hello"
}
EOF

tar czf "${TMP_DIR}/crate.tgz" -C "${TMP_DIR}" "${CRATE_NAME}-${CRATE_VERSION}/"

# Build the Cargo publish wire format:
# u32le(json_len) + json + u32le(crate_len) + crate_bytes
PUBLISH_JSON=$(cat << EOF
{"name":"${CRATE_NAME}","vers":"${CRATE_VERSION}","deps":[],"features":{},"authors":[],"description":"A test crate","license":"MIT","keywords":[],"categories":[]}
EOF
)

CRATE_FILE="${TMP_DIR}/crate.tgz"
CRATE_SIZE=$(stat -c%s "$CRATE_FILE")
JSON_SIZE=${#PUBLISH_JSON}

# Construct binary payload using python3
python3 -c "
import struct, sys
json_data = sys.argv[1].encode()
with open(sys.argv[2], 'rb') as f:
    crate_data = f.read()
payload = struct.pack('<I', len(json_data)) + json_data + struct.pack('<I', len(crate_data)) + crate_data
sys.stdout.buffer.write(payload)
" "$PUBLISH_JSON" "$CRATE_FILE" > "${TMP_DIR}/payload.bin"

# --- Upload (publish) ---
echo "Publishing Cargo crate..."
start_trace "${TRACE_DIR}/upload.json"

nexus_curl -X PUT \
  "${NEXUS_URL}/repository/cargo-hosted-test/api/v1/crates/new" \
  -H 'Content-Type: application/octet-stream' \
  --data-binary @"${TMP_DIR}/payload.bin" >/dev/null

stop_trace "${TRACE_DIR}/upload.json"
summarize_trace "${TRACE_DIR}/upload.json" "Cargo Publish" | tee "${TRACE_DIR}/upload.md"

# --- Download crate ---
echo "Downloading Cargo crate..."
start_trace "${TRACE_DIR}/download.json"

nexus_curl -o /dev/null \
  "${NEXUS_URL}/repository/cargo-hosted-test/crates/${CRATE_NAME}/${CRATE_VERSION}/download"

stop_trace "${TRACE_DIR}/download.json"
summarize_trace "${TRACE_DIR}/download.json" "Cargo Download" | tee "${TRACE_DIR}/download.md"

# --- Re-download ---
echo "Re-downloading Cargo crate..."
start_trace "${TRACE_DIR}/redownload.json"

nexus_curl -o /dev/null \
  "${NEXUS_URL}/repository/cargo-hosted-test/crates/${CRATE_NAME}/${CRATE_VERSION}/download"

stop_trace "${TRACE_DIR}/redownload.json"
summarize_trace "${TRACE_DIR}/redownload.json" "Cargo Re-download" | tee "${TRACE_DIR}/redownload.md"

rm -rf "$TMP_DIR"
echo "=== Scenario complete ==="
