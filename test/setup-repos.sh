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

echo "=== Repository setup complete ==="
