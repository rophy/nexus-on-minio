#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib.sh"

init_nexus_password

SCENARIO="docker-crud"
TRACE_DIR="${RESULTS_DIR}/${SCENARIO}"
mkdir -p "$TRACE_DIR"

echo "=== Scenario: Docker CRUD ==="

NEXUS_IP=$(echo "$NEXUS_URL" | grep -oP '//\K[^:]+')
DOCKER_REPO="${NEXUS_IP}:8082"
IMAGE_NAME="test/hello"
IMAGE_TAG="1.0.0"

# Docker V2 registry auth
DOCKER_AUTH=$(echo -n "${NEXUS_USER}:${NEXUS_PASS}" | base64)

docker_curl() {
  curl -sf -H "Authorization: Basic ${DOCKER_AUTH}" "$@"
}

# Build a minimal OCI image layer (just random data)
TMP_DIR=$(mktemp -d)
dd if=/dev/urandom of="${TMP_DIR}/data.bin" bs=1K count=50 2>/dev/null
tar czf "${TMP_DIR}/layer.tar.gz" -C "${TMP_DIR}" data.bin
LAYER_DIGEST="sha256:$(sha256sum "${TMP_DIR}/layer.tar.gz" | cut -d' ' -f1)"
LAYER_SIZE=$(stat -c%s "${TMP_DIR}/layer.tar.gz")

# Create image config
cat > "${TMP_DIR}/config.json" << EOF
{"architecture":"amd64","os":"linux","rootfs":{"type":"layers","diff_ids":["${LAYER_DIGEST}"]}}
EOF
CONFIG_DIGEST="sha256:$(sha256sum "${TMP_DIR}/config.json" | cut -d' ' -f1)"
CONFIG_SIZE=$(stat -c%s "${TMP_DIR}/config.json")

# Create manifest
cat > "${TMP_DIR}/manifest.json" << EOF
{
  "schemaVersion": 2,
  "mediaType": "application/vnd.docker.distribution.manifest.v2+json",
  "config": {
    "mediaType": "application/vnd.docker.container.image.v1+json",
    "size": ${CONFIG_SIZE},
    "digest": "${CONFIG_DIGEST}"
  },
  "layers": [{
    "mediaType": "application/vnd.docker.image.rootfs.diff.tar.gzip",
    "size": ${LAYER_SIZE},
    "digest": "${LAYER_DIGEST}"
  }]
}
EOF

# --- Upload (push) ---
echo "Pushing Docker image..."
start_trace "${TRACE_DIR}/upload.json"

# Upload layer blob
UPLOAD_PATH=$(docker_curl -D - -X POST \
  "http://${DOCKER_REPO}/v2/${IMAGE_NAME}/blobs/uploads/" 2>/dev/null \
  | grep -i '^location:' | tr -d '\r' | awk '{print $2}')
docker_curl -X PUT \
  "http://${DOCKER_REPO}${UPLOAD_PATH}?digest=${LAYER_DIGEST}" \
  -H 'Content-Type: application/octet-stream' \
  --data-binary @"${TMP_DIR}/layer.tar.gz" >/dev/null

# Upload config blob
UPLOAD_PATH=$(docker_curl -D - -X POST \
  "http://${DOCKER_REPO}/v2/${IMAGE_NAME}/blobs/uploads/" 2>/dev/null \
  | grep -i '^location:' | tr -d '\r' | awk '{print $2}')
docker_curl -X PUT \
  "http://${DOCKER_REPO}${UPLOAD_PATH}?digest=${CONFIG_DIGEST}" \
  -H 'Content-Type: application/vnd.docker.container.image.v1+json' \
  --data-binary @"${TMP_DIR}/config.json" >/dev/null

# Upload manifest
docker_curl -X PUT \
  "http://${DOCKER_REPO}/v2/${IMAGE_NAME}/manifests/${IMAGE_TAG}" \
  -H 'Content-Type: application/vnd.docker.distribution.manifest.v2+json' \
  --data-binary @"${TMP_DIR}/manifest.json" >/dev/null

stop_trace "${TRACE_DIR}/upload.json"
summarize_trace "${TRACE_DIR}/upload.json" "Docker Push (1 layer)" | tee "${TRACE_DIR}/upload.md"

# --- Download (pull manifest + layer) ---
echo "Pulling Docker image..."
start_trace "${TRACE_DIR}/download.json"

docker_curl -o /dev/null \
  -H 'Accept: application/vnd.docker.distribution.manifest.v2+json' \
  "http://${DOCKER_REPO}/v2/${IMAGE_NAME}/manifests/${IMAGE_TAG}"
docker_curl -o /dev/null \
  "http://${DOCKER_REPO}/v2/${IMAGE_NAME}/blobs/${LAYER_DIGEST}"
docker_curl -o /dev/null \
  "http://${DOCKER_REPO}/v2/${IMAGE_NAME}/blobs/${CONFIG_DIGEST}"

stop_trace "${TRACE_DIR}/download.json"
summarize_trace "${TRACE_DIR}/download.json" "Docker Pull (manifest + blobs)" | tee "${TRACE_DIR}/download.md"

# --- Re-download ---
echo "Re-pulling Docker image..."
start_trace "${TRACE_DIR}/redownload.json"

docker_curl -o /dev/null \
  -H 'Accept: application/vnd.docker.distribution.manifest.v2+json' \
  "http://${DOCKER_REPO}/v2/${IMAGE_NAME}/manifests/${IMAGE_TAG}"
docker_curl -o /dev/null \
  "http://${DOCKER_REPO}/v2/${IMAGE_NAME}/blobs/${LAYER_DIGEST}"
docker_curl -o /dev/null \
  "http://${DOCKER_REPO}/v2/${IMAGE_NAME}/blobs/${CONFIG_DIGEST}"

stop_trace "${TRACE_DIR}/redownload.json"
summarize_trace "${TRACE_DIR}/redownload.json" "Docker Re-pull (manifest + blobs)" | tee "${TRACE_DIR}/redownload.md"

rm -rf "$TMP_DIR"
echo "=== Scenario complete ==="
