# Nexus-on-MinIO Test Harness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a shell-based test harness that exercises common Nexus operations against a MinIO-backed S3 blobstore, captures every S3 API call via `mc admin trace`, and produces a summary report.

**Architecture:** A main `test.sh` orchestrator calls per-scenario functions. Each scenario starts an `mc admin trace --json` capture in the background, performs a Nexus operation via curl, stops the trace, and parses the JSON to count S3 calls by API type. A `lib.sh` provides shared helpers (trace start/stop, Nexus API calls, report formatting). Results are written to `results/` as both raw JSON traces and a markdown summary.

**Tech Stack:** Bash, curl, `mc` CLI (inside minio container), `jq` (for JSON parsing), docker compose exec.

---

### Task 1: Create shared library `lib.sh`

**Files:**
- Create: `test/lib.sh`

- [ ] **Step 1: Create `test/lib.sh` with configuration and Nexus API helpers**

```bash
#!/usr/bin/env bash
set -euo pipefail

# --- Configuration ---
NEXUS_URL="http://localhost:8081"
NEXUS_USER="admin"
NEXUS_PASS="" # set by init_nexus_password
MINIO_ALIAS="local"
RESULTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/results"
TRACE_PID_FILE="/tmp/trace.pid"

DC="docker compose"

init_nexus_password() {
  NEXUS_PASS=$($DC exec -T nexus cat /nexus-data/admin.password 2>/dev/null) || {
    echo "ERROR: Could not read admin password. Has Nexus started?" >&2
    exit 1
  }
}

nexus_curl() {
  $DC exec -T nexus curl -sf -u "${NEXUS_USER}:${NEXUS_PASS}" "$@"
}

wait_for_nexus() {
  echo "Waiting for Nexus to start..."
  until $DC logs nexus 2>&1 | grep -q "Started Sonatype Nexus"; do
    sleep 5
  done
  echo "Nexus is ready."
}
```

- [ ] **Step 2: Add trace capture helpers to `lib.sh`**

```bash
# --- Trace capture ---
start_trace() {
  local trace_file="$1"
  # Ensure mc alias is configured
  $DC exec -T minio mc alias set "$MINIO_ALIAS" http://localhost:9000 minioadmin minioadmin >/dev/null 2>&1
  # Start trace in background inside the container, writing to a known path
  $DC exec -T -d minio sh -c "mc admin trace --call s3 --json ${MINIO_ALIAS} > /tmp/trace.json 2>/dev/null"
  # Give trace a moment to attach
  sleep 2
}

stop_trace() {
  local trace_file="$1"
  # mc admin trace has no clean stop mechanism in MinIO container (no pkill).
  # We kill all mc processes inside the container.
  $DC exec -T minio sh -c 'kill $(pidof mc) 2>/dev/null' || true
  sleep 1
  # Copy trace out of container
  mkdir -p "$(dirname "$trace_file")"
  $DC cp minio:/tmp/trace.json "$trace_file"
  # Clean up inside container
  $DC exec -T minio rm -f /tmp/trace.json
}

summarize_trace() {
  local trace_file="$1"
  local label="$2"
  echo ""
  echo "### ${label}"
  echo ""
  echo "| S3 API Call | Count | Total Bytes (RX) | Total Bytes (TX) |"
  echo "|---|---|---|---|"
  jq -r '
    .api as $api |
    .callStats.rx as $rx |
    .callStats.tx as $tx |
    [$api, $rx, $tx] | @tsv
  ' "$trace_file" \
    | sort \
    | awk -F'\t' '
      { count[$1]++; rx[$1]+=$2; tx[$1]+=$3 }
      END {
        for (api in count)
          printf "| %s | %d | %d | %d |\n", api, count[api], rx[api], tx[api]
      }
    ' \
    | sort -t'|' -k3 -rn
  echo ""
  local total
  total=$(jq -s 'length' "$trace_file")
  echo "**Total S3 calls: ${total}**"
  echo ""
}
```

- [ ] **Step 3: Verify `lib.sh` is sourceable**

Run:
```bash
cd /home/rophy/projects/nexus-on-minio
bash -n test/lib.sh && echo "Syntax OK"
```
Expected: `Syntax OK`

- [ ] **Step 4: Commit**

```bash
git add test/lib.sh
git commit -m "feat: add test/lib.sh with trace capture and Nexus API helpers"
```

---

### Task 2: Create repository setup script

**Files:**
- Create: `test/setup-repos.sh`

This script creates test repositories on the `minio` blobstore. We need:
- A raw hosted repo (simplest for upload/download tests)
- A maven hosted repo (multi-file artifact tests)
- A maven proxy repo pointing to Maven Central (cache miss tests)

- [ ] **Step 1: Create `test/setup-repos.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

init_nexus_password

echo "=== Setting up test repositories on minio blobstore ==="

# Allow minio hostname through SSRF protection (idempotent)
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
  echo "S3 blobstore created."
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
      "writePolicy": "ALLOW_ONCE"
    },
    "maven": {
      "versionPolicy": "RELEASE",
      "layoutPolicy": "STRICT"
    }
  }' >/dev/null 2>&1 && echo "  Created." || echo "  Already exists."

# Maven proxy repo (proxying Maven Central, stored in minio)
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
```

- [ ] **Step 2: Run the setup script and verify**

Run:
```bash
chmod +x test/setup-repos.sh
bash test/setup-repos.sh
```
Expected: Three repos created (or "Already exists" if re-run).

Verify:
```bash
docker compose exec nexus curl -s -u admin:<password> http://localhost:8081/service/rest/v1/repositories | python3 -c "
import sys, json
for r in json.load(sys.stdin):
    if 'test' in r['name']:
        print(r['name'], r['format'], r['type'])
"
```
Expected output:
```
raw-hosted-test raw hosted
maven-hosted-test maven2 hosted
maven-proxy-test maven2 proxy
```

- [ ] **Step 3: Commit**

```bash
git add test/setup-repos.sh
git commit -m "feat: add test/setup-repos.sh for creating test repos on minio blobstore"
```

---

### Task 3: Scenario — Upload and download a single raw artifact

**Files:**
- Create: `test/scenarios/raw-upload-download.sh`

- [ ] **Step 1: Create the scenario script**

```bash
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib.sh"

init_nexus_password

SCENARIO="raw-upload-download"
TRACE_DIR="${RESULTS_DIR}/${SCENARIO}"
mkdir -p "$TRACE_DIR"

echo "=== Scenario: Raw Upload + Download ==="

# Generate a test file (1MB of random data)
TEST_FILE="/tmp/test-artifact.bin"
dd if=/dev/urandom of="$TEST_FILE" bs=1K count=1024 2>/dev/null

# --- Upload ---
echo "Uploading 1MB raw artifact..."
start_trace "${TRACE_DIR}/upload.json"

nexus_curl -X PUT \
  "${NEXUS_URL}/repository/raw-hosted-test/test/artifact-1.bin" \
  --upload-file "$TEST_FILE" \
  -H 'Content-Type: application/octet-stream' >/dev/null

stop_trace "${TRACE_DIR}/upload.json"
summarize_trace "${TRACE_DIR}/upload.json" "Raw Upload (1MB)" | tee "${TRACE_DIR}/upload.md"

# --- Download ---
echo "Downloading raw artifact..."
start_trace "${TRACE_DIR}/download.json"

nexus_curl -o /dev/null \
  "${NEXUS_URL}/repository/raw-hosted-test/test/artifact-1.bin"

stop_trace "${TRACE_DIR}/download.json"
summarize_trace "${TRACE_DIR}/download.json" "Raw Download (1MB)" | tee "${TRACE_DIR}/download.md"

# --- Re-download (cached) ---
echo "Re-downloading raw artifact (should be cached)..."
start_trace "${TRACE_DIR}/redownload.json"

nexus_curl -o /dev/null \
  "${NEXUS_URL}/repository/raw-hosted-test/test/artifact-1.bin"

stop_trace "${TRACE_DIR}/redownload.json"
summarize_trace "${TRACE_DIR}/redownload.json" "Raw Re-download (cached, 1MB)" | tee "${TRACE_DIR}/redownload.md"

rm -f "$TEST_FILE"
echo "=== Scenario complete ==="
```

- [ ] **Step 2: Run and verify output**

Run:
```bash
chmod +x test/scenarios/raw-upload-download.sh
bash test/scenarios/raw-upload-download.sh
```
Expected: Markdown tables showing S3 call counts for upload, download, and re-download.

- [ ] **Step 3: Commit**

```bash
git add test/scenarios/raw-upload-download.sh
git commit -m "feat: add raw upload/download scenario"
```

---

### Task 4: Scenario — Maven multi-file artifact upload

**Files:**
- Create: `test/scenarios/maven-upload.sh`

A Maven artifact deploy uploads multiple files: the jar, the pom, checksums (md5, sha1), and maven-metadata.xml updates. We simulate this with curl.

- [ ] **Step 1: Create the scenario script**

```bash
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib.sh"

init_nexus_password

SCENARIO="maven-upload"
TRACE_DIR="${RESULTS_DIR}/${SCENARIO}"
mkdir -p "$TRACE_DIR"

echo "=== Scenario: Maven Multi-file Artifact Upload ==="

GAV_PATH="com/example/test-lib/1.0.0"
BASE_URL="${NEXUS_URL}/repository/maven-hosted-test/${GAV_PATH}"

# Generate fake artifact files
TMP_DIR=$(mktemp -d)
dd if=/dev/urandom of="${TMP_DIR}/test-lib-1.0.0.jar" bs=1K count=512 2>/dev/null

cat > "${TMP_DIR}/test-lib-1.0.0.pom" << 'POMEOF'
<?xml version="1.0" encoding="UTF-8"?>
<project>
  <modelVersion>4.0.0</modelVersion>
  <groupId>com.example</groupId>
  <artifactId>test-lib</artifactId>
  <version>1.0.0</version>
  <packaging>jar</packaging>
</project>
POMEOF

echo "Uploading Maven artifact (jar + pom)..."
start_trace "${TRACE_DIR}/upload.json"

# Upload jar
nexus_curl -X PUT "${BASE_URL}/test-lib-1.0.0.jar" \
  --upload-file "${TMP_DIR}/test-lib-1.0.0.jar" \
  -H 'Content-Type: application/java-archive' >/dev/null

# Upload pom
nexus_curl -X PUT "${BASE_URL}/test-lib-1.0.0.pom" \
  --upload-file "${TMP_DIR}/test-lib-1.0.0.pom" \
  -H 'Content-Type: application/xml' >/dev/null

stop_trace "${TRACE_DIR}/upload.json"
summarize_trace "${TRACE_DIR}/upload.json" "Maven Upload (jar + pom)" | tee "${TRACE_DIR}/upload.md"

rm -rf "$TMP_DIR"
echo "=== Scenario complete ==="
```

- [ ] **Step 2: Run and verify**

Run:
```bash
chmod +x test/scenarios/maven-upload.sh
bash test/scenarios/maven-upload.sh
```
Expected: Markdown table showing S3 calls. Expect at least 4 PutObject calls (jar.bytes, jar.properties, pom.bytes, pom.properties) plus any metadata updates.

- [ ] **Step 3: Commit**

```bash
git add test/scenarios/maven-upload.sh
git commit -m "feat: add maven multi-file upload scenario"
```

---

### Task 5: Scenario — Proxy cache miss (fetch from Maven Central)

**Files:**
- Create: `test/scenarios/proxy-cache-miss.sh`

- [ ] **Step 1: Create the scenario script**

```bash
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib.sh"

init_nexus_password

SCENARIO="proxy-cache-miss"
TRACE_DIR="${RESULTS_DIR}/${SCENARIO}"
mkdir -p "$TRACE_DIR"

echo "=== Scenario: Proxy Cache Miss (Maven Central) ==="

# Fetch a small, well-known artifact that won't already be cached
# commons-lang3 3.17.0 pom is ~30KB
ARTIFACT_PATH="org/apache/commons/commons-lang3/3.17.0/commons-lang3-3.17.0.pom"

echo "Fetching artifact via proxy (cache miss)..."
start_trace "${TRACE_DIR}/cache-miss.json"

nexus_curl -o /dev/null \
  "${NEXUS_URL}/repository/maven-proxy-test/${ARTIFACT_PATH}"

stop_trace "${TRACE_DIR}/cache-miss.json"
summarize_trace "${TRACE_DIR}/cache-miss.json" "Proxy Cache Miss" | tee "${TRACE_DIR}/cache-miss.md"

# Second fetch — should be cached
echo "Fetching same artifact again (cache hit)..."
start_trace "${TRACE_DIR}/cache-hit.json"

nexus_curl -o /dev/null \
  "${NEXUS_URL}/repository/maven-proxy-test/${ARTIFACT_PATH}"

stop_trace "${TRACE_DIR}/cache-hit.json"
summarize_trace "${TRACE_DIR}/cache-hit.json" "Proxy Cache Hit" | tee "${TRACE_DIR}/cache-hit.md"

echo "=== Scenario complete ==="
```

- [ ] **Step 2: Run and verify**

Run:
```bash
chmod +x test/scenarios/proxy-cache-miss.sh
bash test/scenarios/proxy-cache-miss.sh
```
Expected: Cache miss shows PutObject calls (Nexus caching the upstream artifact to MinIO). Cache hit should show GetObject calls (or possibly zero if served from Nexus's internal cache).

- [ ] **Step 3: Commit**

```bash
git add test/scenarios/proxy-cache-miss.sh
git commit -m "feat: add proxy cache miss/hit scenario"
```

---

### Task 6: Scenario — Browse/search repository

**Files:**
- Create: `test/scenarios/browse-search.sh`

- [ ] **Step 1: Create the scenario script**

```bash
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib.sh"

init_nexus_password

SCENARIO="browse-search"
TRACE_DIR="${RESULTS_DIR}/${SCENARIO}"
mkdir -p "$TRACE_DIR"

echo "=== Scenario: Browse & Search ==="

# Browse the raw repo's component list via REST API
echo "Browsing components via REST API..."
start_trace "${TRACE_DIR}/browse-components.json"

nexus_curl "${NEXUS_URL}/service/rest/v1/components?repository=raw-hosted-test" >/dev/null

stop_trace "${TRACE_DIR}/browse-components.json"
summarize_trace "${TRACE_DIR}/browse-components.json" "Browse Components (REST API)" | tee "${TRACE_DIR}/browse-components.md"

# Browse assets
echo "Browsing assets via REST API..."
start_trace "${TRACE_DIR}/browse-assets.json"

nexus_curl "${NEXUS_URL}/service/rest/v1/assets?repository=raw-hosted-test" >/dev/null

stop_trace "${TRACE_DIR}/browse-assets.json"
summarize_trace "${TRACE_DIR}/browse-assets.json" "Browse Assets (REST API)" | tee "${TRACE_DIR}/browse-assets.md"

# Search by keyword
echo "Searching for artifact by keyword..."
start_trace "${TRACE_DIR}/search.json"

nexus_curl "${NEXUS_URL}/service/rest/v1/search?q=artifact-1&repository=raw-hosted-test" >/dev/null

stop_trace "${TRACE_DIR}/search.json"
summarize_trace "${TRACE_DIR}/search.json" "Search by keyword" | tee "${TRACE_DIR}/search.md"

echo "=== Scenario complete ==="
```

- [ ] **Step 2: Run and verify**

Run:
```bash
chmod +x test/scenarios/browse-search.sh
bash test/scenarios/browse-search.sh
```
Expected: Zero or near-zero S3 calls — browsing/searching should be served entirely from the database.

- [ ] **Step 3: Commit**

```bash
git add test/scenarios/browse-search.sh
git commit -m "feat: add browse/search scenario"
```

---

### Task 7: Scenario — Delete and compact

**Files:**
- Create: `test/scenarios/delete-compact.sh`

- [ ] **Step 1: Create the scenario script**

```bash
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib.sh"

init_nexus_password

SCENARIO="delete-compact"
TRACE_DIR="${RESULTS_DIR}/${SCENARIO}"
mkdir -p "$TRACE_DIR"

echo "=== Scenario: Delete + Compact ==="

# First, upload an artifact to delete
TEST_FILE="/tmp/delete-test.bin"
dd if=/dev/urandom of="$TEST_FILE" bs=1K count=100 2>/dev/null

nexus_curl -X PUT \
  "${NEXUS_URL}/repository/raw-hosted-test/test/to-delete.bin" \
  --upload-file "$TEST_FILE" \
  -H 'Content-Type: application/octet-stream' >/dev/null
rm -f "$TEST_FILE"

# Find the component ID
COMPONENT_ID=$(nexus_curl "${NEXUS_URL}/service/rest/v1/search?q=to-delete&repository=raw-hosted-test" \
  | jq -r '.items[0].id')

echo "Deleting component ${COMPONENT_ID}..."
start_trace "${TRACE_DIR}/delete.json"

nexus_curl -X DELETE "${NEXUS_URL}/service/rest/v1/components/${COMPONENT_ID}" >/dev/null

stop_trace "${TRACE_DIR}/delete.json"
summarize_trace "${TRACE_DIR}/delete.json" "Delete Component" | tee "${TRACE_DIR}/delete.md"

# Trigger compact blobstore task
echo "Running compact blobstore task..."
start_trace "${TRACE_DIR}/compact.json"

# Create and run the compact task
TASK_JSON=$(nexus_curl -X POST "${NEXUS_URL}/service/rest/v1/tasks" \
  -H 'Content-Type: application/json' \
  -d '{
    "action": "blobstore.compact",
    "type": "blobstore.compact",
    "name": "compact-minio-test",
    "typeId": "blobstore.compact",
    "properties": {"blobstoreName": "minio"}
  }' 2>&1) || true

# Alternative: trigger via the existing task list
TASK_ID=$(nexus_curl "${NEXUS_URL}/service/rest/v1/tasks?type=blobstore.compact" \
  | jq -r '.items[] | select(.name == "compact-minio-test") | .id' 2>/dev/null) || true

if [ -n "$TASK_ID" ] && [ "$TASK_ID" != "null" ]; then
  nexus_curl -X POST "${NEXUS_URL}/service/rest/v1/tasks/${TASK_ID}/run" >/dev/null 2>&1 || true
  echo "Compact task triggered. Waiting 10s for completion..."
  sleep 10
else
  echo "Could not find compact task. Compact may need manual trigger."
  echo "Waiting 10s in case Nexus runs internal cleanup..."
  sleep 10
fi

stop_trace "${TRACE_DIR}/compact.json"
summarize_trace "${TRACE_DIR}/compact.json" "Compact Blobstore" | tee "${TRACE_DIR}/compact.md"

echo "=== Scenario complete ==="
```

- [ ] **Step 2: Run and verify**

Run:
```bash
chmod +x test/scenarios/delete-compact.sh
bash test/scenarios/delete-compact.sh
```
Expected: Delete should show `PutObjectTagging` (soft-delete tag) and/or `PutObject` (.properties update). Compact should show `ListObjectsV2` and possibly `DeleteObject`.

- [ ] **Step 3: Commit**

```bash
git add test/scenarios/delete-compact.sh
git commit -m "feat: add delete and compact scenario"
```

---

### Task 8: Main test runner and report generator

**Files:**
- Create: `test/run-all.sh`

- [ ] **Step 1: Create `test/run-all.sh`**

```bash
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
$DC ps --format '{{.Service}}\t{{.State}}' | while read -r svc state; do
  echo "  ${svc}: ${state}"
done

wait_for_nexus
init_nexus_password
echo "Admin password: ${NEXUS_PASS}"
echo ""

# Setup
echo "--- Setting up test repositories ---"
bash "${SCRIPT_DIR}/setup-repos.sh"
echo ""

# Count objects before
BEFORE_COUNT=$($DC exec -T minio mc ls --recursive --summarize local/nexus-blobstore 2>/dev/null | grep "Total Objects:" | awk '{print $3}')
echo "MinIO objects before tests: ${BEFORE_COUNT:-0}"
echo ""

# Run scenarios
SCENARIOS=(
  "raw-upload-download"
  "maven-upload"
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
AFTER_COUNT=$($DC exec -T minio mc ls --recursive --summarize local/nexus-blobstore 2>/dev/null | grep "Total Objects:" | awk '{print $3}')
echo "MinIO objects after tests: ${AFTER_COUNT:-0}"
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
  echo "**MinIO object count:** before=${BEFORE_COUNT:-0}, after=${AFTER_COUNT:-0}"
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
```

- [ ] **Step 2: Make all scripts executable**

```bash
chmod +x test/run-all.sh test/setup-repos.sh test/lib.sh
chmod +x test/scenarios/*.sh
```

- [ ] **Step 3: Dry-run the full suite**

Run:
```bash
bash test/run-all.sh
```
Expected: All scenarios run, report generated at `results/report.md`.

- [ ] **Step 4: Commit**

```bash
git add test/run-all.sh
git commit -m "feat: add main test runner with combined report generation"
```

---

### Task 9: Add `.gitignore` for results

**Files:**
- Create: `.gitignore`

- [ ] **Step 1: Create `.gitignore`**

```
results/
```

- [ ] **Step 2: Commit**

```bash
git add .gitignore
git commit -m "chore: gitignore test results directory"
```

---

### Task 10: End-to-end run and fix issues

**Files:**
- Modify: any scripts that need fixing based on actual run output

- [ ] **Step 1: Clean slate run**

```bash
# Reset the environment
docker compose down -v
docker compose up -d
bash test/run-all.sh 2>&1 | tee /tmp/test-run.log
```

- [ ] **Step 2: Review the generated report**

```bash
cat results/report.md
```

Verify each scenario has meaningful data (non-zero S3 call counts where expected, zero where expected).

- [ ] **Step 3: Fix any issues found and re-run**

Iterate until all scenarios produce clean output.

- [ ] **Step 4: Commit final fixes**

```bash
git add -A
git commit -m "fix: address issues found during end-to-end test run"
```
