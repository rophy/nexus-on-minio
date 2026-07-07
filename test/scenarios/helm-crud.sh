#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib.sh"

init_nexus_password

SCENARIO="helm-crud"
TRACE_DIR="${RESULTS_DIR}/${SCENARIO}"
mkdir -p "$TRACE_DIR"

echo "=== Scenario: Helm Chart CRUD (OCI) ==="

NEXUS_IP=$(echo "$NEXUS_URL" | grep -oP '//\K[^:]+')
DOCKER_REPO="${NEXUS_IP}:8082"
CHART_NAME="test/mychart"
CHART_VERSION="0.1.0"

DOCKER_AUTH=$(echo -n "${NEXUS_USER}:${NEXUS_PASS}" | base64)

oci_curl() {
  curl -sf -H "Authorization: Basic ${DOCKER_AUTH}" "$@"
}

TMP_DIR=$(mktemp -d)

# Build a minimal Helm chart tarball
mkdir -p "${TMP_DIR}/mychart/templates"
cat > "${TMP_DIR}/mychart/Chart.yaml" << EOF
apiVersion: v2
name: mychart
version: ${CHART_VERSION}
description: A minimal test chart
type: application
EOF

cat > "${TMP_DIR}/mychart/templates/configmap.yaml" << 'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ .Release.Name }}-config
data:
  key: value
EOF

# Package chart as .tar.gz (the OCI chart layer)
tar czf "${TMP_DIR}/chart.tar.gz" -C "${TMP_DIR}" mychart/
CHART_DIGEST="sha256:$(sha256sum "${TMP_DIR}/chart.tar.gz" | cut -d' ' -f1)"
CHART_SIZE=$(stat -c%s "${TMP_DIR}/chart.tar.gz")

# Create Helm config blob (chart metadata in OCI format)
cat > "${TMP_DIR}/config.json" << EOF
{"name":"mychart","version":"${CHART_VERSION}","description":"A minimal test chart","type":"application","apiVersion":"v2"}
EOF
CONFIG_DIGEST="sha256:$(sha256sum "${TMP_DIR}/config.json" | cut -d' ' -f1)"
CONFIG_SIZE=$(stat -c%s "${TMP_DIR}/config.json")

# Create OCI manifest with Helm media types
cat > "${TMP_DIR}/manifest.json" << EOF
{
  "schemaVersion": 2,
  "mediaType": "application/vnd.oci.image.manifest.v1+json",
  "config": {
    "mediaType": "application/vnd.cncf.helm.config.v1+json",
    "size": ${CONFIG_SIZE},
    "digest": "${CONFIG_DIGEST}"
  },
  "layers": [{
    "mediaType": "application/vnd.cncf.helm.chart.content.v1.tar.gz",
    "size": ${CHART_SIZE},
    "digest": "${CHART_DIGEST}"
  }]
}
EOF

# --- Upload (push) ---
echo "Pushing Helm chart as OCI artifact..."
start_trace "${TRACE_DIR}/upload.json"

# Upload chart layer blob
UPLOAD_PATH=$(oci_curl -D - -X POST \
  "http://${DOCKER_REPO}/v2/${CHART_NAME}/blobs/uploads/" 2>/dev/null \
  | grep -i '^location:' | tr -d '\r' | awk '{print $2}')
oci_curl -X PUT \
  "http://${DOCKER_REPO}${UPLOAD_PATH}?digest=${CHART_DIGEST}" \
  -H 'Content-Type: application/octet-stream' \
  --data-binary @"${TMP_DIR}/chart.tar.gz" >/dev/null

# Upload config blob
UPLOAD_PATH=$(oci_curl -D - -X POST \
  "http://${DOCKER_REPO}/v2/${CHART_NAME}/blobs/uploads/" 2>/dev/null \
  | grep -i '^location:' | tr -d '\r' | awk '{print $2}')
oci_curl -X PUT \
  "http://${DOCKER_REPO}${UPLOAD_PATH}?digest=${CONFIG_DIGEST}" \
  -H 'Content-Type: application/vnd.cncf.helm.config.v1+json' \
  --data-binary @"${TMP_DIR}/config.json" >/dev/null

# Upload manifest
oci_curl -X PUT \
  "http://${DOCKER_REPO}/v2/${CHART_NAME}/manifests/${CHART_VERSION}" \
  -H 'Content-Type: application/vnd.oci.image.manifest.v1+json' \
  --data-binary @"${TMP_DIR}/manifest.json" >/dev/null

stop_trace "${TRACE_DIR}/upload.json"
summarize_trace "${TRACE_DIR}/upload.json" "Helm Push (OCI, 1 chart)" | tee "${TRACE_DIR}/upload.md"

# --- Download (pull manifest + blobs) ---
echo "Pulling Helm chart..."
start_trace "${TRACE_DIR}/download.json"

oci_curl -o /dev/null \
  -H 'Accept: application/vnd.oci.image.manifest.v1+json' \
  "http://${DOCKER_REPO}/v2/${CHART_NAME}/manifests/${CHART_VERSION}"
oci_curl -o /dev/null \
  "http://${DOCKER_REPO}/v2/${CHART_NAME}/blobs/${CHART_DIGEST}"
oci_curl -o /dev/null \
  "http://${DOCKER_REPO}/v2/${CHART_NAME}/blobs/${CONFIG_DIGEST}"

stop_trace "${TRACE_DIR}/download.json"
summarize_trace "${TRACE_DIR}/download.json" "Helm Pull (manifest + blobs)" | tee "${TRACE_DIR}/download.md"

# --- Re-download ---
echo "Re-pulling Helm chart..."
start_trace "${TRACE_DIR}/redownload.json"

oci_curl -o /dev/null \
  -H 'Accept: application/vnd.oci.image.manifest.v1+json' \
  "http://${DOCKER_REPO}/v2/${CHART_NAME}/manifests/${CHART_VERSION}"
oci_curl -o /dev/null \
  "http://${DOCKER_REPO}/v2/${CHART_NAME}/blobs/${CHART_DIGEST}"
oci_curl -o /dev/null \
  "http://${DOCKER_REPO}/v2/${CHART_NAME}/blobs/${CONFIG_DIGEST}"

stop_trace "${TRACE_DIR}/redownload.json"
summarize_trace "${TRACE_DIR}/redownload.json" "Helm Re-pull (manifest + blobs)" | tee "${TRACE_DIR}/redownload.md"

rm -rf "$TMP_DIR"
echo "=== Scenario complete ==="
