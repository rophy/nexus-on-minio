#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib.sh"

init_nexus_password

SCENARIO="pypi-crud"
TRACE_DIR="${RESULTS_DIR}/${SCENARIO}"
mkdir -p "$TRACE_DIR"

echo "=== Scenario: PyPI CRUD ==="

TMP_DIR=$(mktemp -d)

# Build a minimal Python sdist tarball
PKG_NAME="test-pypkg"
PKG_VERSION="1.0.0"
SDIST_DIR="${TMP_DIR}/${PKG_NAME}-${PKG_VERSION}"
mkdir -p "${SDIST_DIR}"
cat > "${SDIST_DIR}/setup.py" << 'EOF'
from setuptools import setup
setup(name="test-pypkg", version="1.0.0")
EOF
cat > "${SDIST_DIR}/PKG-INFO" << 'EOF'
Metadata-Version: 1.0
Name: test-pypkg
Version: 1.0.0
Summary: test package for S3 overhead measurement
EOF
dd if=/dev/urandom of="${SDIST_DIR}/data.bin" bs=1K count=10 2>/dev/null
tar czf "${TMP_DIR}/${PKG_NAME}-${PKG_VERSION}.tar.gz" -C "${TMP_DIR}" "${PKG_NAME}-${PKG_VERSION}"

# --- Upload ---
echo "Uploading PyPI sdist..."
start_trace "${TRACE_DIR}/upload.json"

nexus_curl -X POST \
  "${NEXUS_URL}/repository/pypi-hosted-test/" \
  -F ":action=file_upload" \
  -F "name=${PKG_NAME}" \
  -F "version=${PKG_VERSION}" \
  -F "filetype=sdist" \
  -F "content=@${TMP_DIR}/${PKG_NAME}-${PKG_VERSION}.tar.gz;type=application/gzip" >/dev/null

stop_trace "${TRACE_DIR}/upload.json"
summarize_trace "${TRACE_DIR}/upload.json" "PyPI Upload (sdist)" | tee "${TRACE_DIR}/upload.md"

# --- Download ---
# PyPI download path: /packages/<name>/<version>/<filename>
echo "Downloading PyPI package..."
start_trace "${TRACE_DIR}/download.json"

nexus_curl -o /dev/null \
  "${NEXUS_URL}/repository/pypi-hosted-test/packages/${PKG_NAME}/${PKG_VERSION}/${PKG_NAME}-${PKG_VERSION}.tar.gz"

stop_trace "${TRACE_DIR}/download.json"
summarize_trace "${TRACE_DIR}/download.json" "PyPI Download" | tee "${TRACE_DIR}/download.md"

# --- Re-download ---
echo "Re-downloading PyPI package..."
start_trace "${TRACE_DIR}/redownload.json"

nexus_curl -o /dev/null \
  "${NEXUS_URL}/repository/pypi-hosted-test/packages/${PKG_NAME}/${PKG_VERSION}/${PKG_NAME}-${PKG_VERSION}.tar.gz"

stop_trace "${TRACE_DIR}/redownload.json"
summarize_trace "${TRACE_DIR}/redownload.json" "PyPI Re-download" | tee "${TRACE_DIR}/redownload.md"

rm -rf "$TMP_DIR"
echo "=== Scenario complete ==="
