#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

init_nexus_password

echo "=== Setting up test repositories on minio blobstore ==="

# Allow minio hostname through SSRF protection
nexus_curl -X PUT "${NEXUS_URL}/service/rest/v1/security/ssrf-protection" \
  -H 'Content-Type: application/json' \
  -d '{"enabled": true, "allowedIPs": [], "allowedDomains": ["minio"]}' >/dev/null

# Create S3 blobstore if it doesn't exist
if ! nexus_curl "${NEXUS_URL}/service/rest/v1/blobstores/s3/minio" >/dev/null 2>&1; then
  echo "Creating S3 blobstore 'minio'..."
  nexus_curl "${NEXUS_URL}/service/rest/v1/blobstores/s3" \
    -H 'Content-Type: application/json' \
    -d '{
      "name": "minio",
      "bucketConfiguration": {
        "bucket": {"region": "us-east-1", "name": "nexus-blobstore", "prefix": "", "expiration": -1},
        "bucketSecurity": {"accessKeyId": "minioadmin", "secretAccessKey": "minioadmin"},
        "advancedBucketConnection": {"endpoint": "http://minio:9000", "forcePathStyle": true}
      }
    }' >/dev/null
  echo "  Created."
else
  echo "S3 blobstore 'minio' already exists."
fi

# Raw hosted repo
echo "Creating raw-hosted-test repo..."
nexus_curl -X POST "${NEXUS_URL}/service/rest/v1/repositories/raw/hosted" \
  -H 'Content-Type: application/json' \
  -d '{
    "name": "raw-hosted-test",
    "online": true,
    "storage": {
      "blobStoreName": "minio",
      "strictContentTypeValidation": false,
      "writePolicy": "ALLOW"
    }
  }' >/dev/null 2>&1 && echo "  Created." || echo "  Already exists."

# Maven hosted repo
echo "Creating maven-hosted-test repo..."
nexus_curl -X POST "${NEXUS_URL}/service/rest/v1/repositories/maven/hosted" \
  -H 'Content-Type: application/json' \
  -d '{
    "name": "maven-hosted-test",
    "online": true,
    "storage": {
      "blobStoreName": "minio",
      "strictContentTypeValidation": true,
      "writePolicy": "ALLOW"
    },
    "maven": {
      "versionPolicy": "RELEASE",
      "layoutPolicy": "STRICT"
    }
  }' >/dev/null 2>&1 && echo "  Created." || echo "  Already exists."

# Maven proxy repo
echo "Creating maven-proxy-test repo..."
nexus_curl -X POST "${NEXUS_URL}/service/rest/v1/repositories/maven/proxy" \
  -H 'Content-Type: application/json' \
  -d '{
    "name": "maven-proxy-test",
    "online": true,
    "storage": {
      "blobStoreName": "minio",
      "strictContentTypeValidation": false
    },
    "proxy": {
      "remoteUrl": "https://repo1.maven.org/maven2/",
      "contentMaxAge": 1440,
      "metadataMaxAge": 1440
    },
    "httpClient": {
      "blocked": false,
      "autoBlock": true
    },
    "maven": {
      "versionPolicy": "RELEASE",
      "layoutPolicy": "STRICT"
    },
    "negativeCache": {
      "enabled": true,
      "timeToLive": 1440
    }
  }' >/dev/null 2>&1 && echo "  Created." || echo "  Already exists."

# npm hosted repo
echo "Creating npm-hosted-test repo..."
nexus_curl -X POST "${NEXUS_URL}/service/rest/v1/repositories/npm/hosted" \
  -H 'Content-Type: application/json' \
  -d '{
    "name": "npm-hosted-test",
    "online": true,
    "storage": {
      "blobStoreName": "minio",
      "strictContentTypeValidation": true,
      "writePolicy": "ALLOW"
    }
  }' >/dev/null 2>&1 && echo "  Created." || echo "  Already exists."

# PyPI hosted repo
echo "Creating pypi-hosted-test repo..."
nexus_curl -X POST "${NEXUS_URL}/service/rest/v1/repositories/pypi/hosted" \
  -H 'Content-Type: application/json' \
  -d '{
    "name": "pypi-hosted-test",
    "online": true,
    "storage": {
      "blobStoreName": "minio",
      "strictContentTypeValidation": true,
      "writePolicy": "ALLOW"
    }
  }' >/dev/null 2>&1 && echo "  Created." || echo "  Already exists."

# Docker hosted repo (used for Helm OCI charts)
echo "Creating docker-hosted-test repo..."
nexus_curl -X POST "${NEXUS_URL}/service/rest/v1/repositories/docker/hosted" \
  -H 'Content-Type: application/json' \
  -d '{
    "name": "docker-hosted-test",
    "online": true,
    "storage": {
      "blobStoreName": "minio",
      "strictContentTypeValidation": true,
      "writePolicy": "ALLOW"
    },
    "docker": {
      "v1Enabled": false,
      "forceBasicAuth": true,
      "httpPort": 8082
    }
  }' >/dev/null 2>&1 && echo "  Created." || echo "  Already exists."

echo "=== Repository setup complete ==="
