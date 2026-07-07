# Nexus-on-MinIO S3 Overhead Test Results

**Date:** 2026-07-07  
**Nexus version:** 3.93.2 (Community Edition)  
**MinIO image:** minio/minio:latest  
**MinIO object count:** 0 before tests, 53 after tests

## Summary

| Scenario | Total S3 Calls | Breakdown |
|---|---|---|
| Raw Upload (1MB) | 5 | 3 PutObject, 1 HeadObject, 1 GetObject |
| Raw Download (first) | 5 | 4 GetObject, 1 PutObject |
| Raw Re-download | 1 | 1 GetObject |
| Maven Upload (jar + pom) | 12 | 6 PutObject, 3 GetObject, 2 HeadObject, 1 HeadBucket |
| Proxy Cache Miss | 7 | 3 PutObject, 3 GetObject, 1 HeadObject |
| Proxy Cache Hit | 1 | 1 GetObject |
| Browse Components | 0 | — |
| Browse Assets | 0 | — |
| Search by keyword | 0 | — |
| Delete Component | 0 | — |
| Compact Blobstore | 0 | See note below |

## Analysis

### Upload (raw, 1 artifact = 5 S3 calls)

A single 1MB raw artifact upload produces:
- **3 PutObject** — the `.bytes` content, the `.properties` metadata, and likely a temporary blob
- **1 HeadObject** — checking if the blob already exists
- **1 GetObject** — reading back the `.properties` to verify/update

This confirms the **2-objects-per-blob** design. The extra calls are overhead from Nexus verifying the write.

### Upload (Maven, jar + pom = 12 S3 calls)

Uploading a jar and a pom (2 logical files) produces 12 S3 calls:
- **6 PutObject** — `.bytes` + `.properties` for each artifact, plus maven-metadata.xml updates
- **3 GetObject** — reading back properties and existing metadata
- **2 HeadObject** — existence checks
- **1 HeadBucket** — bucket validation

Roughly **5-6 S3 calls per file** uploaded, consistent with the raw upload pattern.

### Download (first = 5 calls, subsequent = 1 call)

The first download of a raw artifact:
- **4 GetObject** — content + properties reads (multiple, possibly due to attribute refresh)
- **1 PutObject** — updating the `.properties` file (last-accessed timestamp or similar)

Subsequent downloads produce only **1 GetObject** — Nexus caches the blob location and attributes, so it goes straight to the content.

### Proxy Cache Miss (7 S3 calls)

Fetching a single POM file from Maven Central through a proxy repository triggers **7 S3 calls**:
- **3 PutObject** — the cached artifact content (`.bytes`), its metadata (`.properties`), and associated upstream metadata
- **3 GetObject** — reading back written properties and checking existing cached content
- **1 HeadObject** — existence check

This is consistent with the per-artifact overhead seen in direct uploads (~5-7 calls per blob).

**Note on first-ever proxy fetch:** The very first fetch from a proxy repository triggers an additional one-time **ListObjectsV2** on `content/directpath/health-check/<repo-name>`. This is a blobstore health check, not part of the cache miss flow. It does not repeat on subsequent cache misses. The test scenario performs a warmup fetch before measurement to isolate this one-time cost.

### Proxy Cache Hit (1 S3 call)

Once cached, re-fetching the same artifact produces only **1 GetObject** — Nexus serves directly from MinIO without rechecking upstream.

### Browse / Search (0 S3 calls)

Browsing components, browsing assets, and keyword search produce **zero S3 calls**. These operations are served entirely from the Nexus database (H2/PostgreSQL), confirming that S3 is not on the hot path for metadata queries.

### Delete + Compact (0 S3 calls in test window)

Deleting a component via the REST API produces **zero S3 calls**. Nexus removes the database references but leaves the S3 objects (`.bytes` + `.properties`) orphaned in the bucket.

The S3 object cleanup is a **two-stage process**:
1. **`assetBlob.cleanup` task** — runs every 30 minutes per format (e.g., "Cleanup unused raw blobs"). Scans the database for orphaned blob references with a grace period of 60 minutes (`nexus.assetBlobCleanupTask.blobCreatedDelayMinute`, default 60). Moves qualifying entries to the `SoftDeletedBlobIndex`.
2. **`blobstore.compact` task** — reads the `SoftDeletedBlobIndex` and issues S3 `DeleteObject` calls to remove the actual `.bytes` and `.properties` files.

In our test, both tasks ran successfully but found zero blobs to process — the 60-minute grace period had not elapsed. The compact task's `blobsOlderThan` parameter (default 0 days) only applies to blobs already in the `SoftDeletedBlobIndex`; it cannot bypass the `assetBlob.cleanup` grace period.

**Triggering compact programmatically:** The REST API `POST /v1/tasks` returns 405 (cannot create tasks). However:
- The **ExtDirect API** (`POST /service/extdirect` with `coreui_Task.create`) can create a compact task with `schedule: "manual"`.
- Existing tasks can be triggered via `POST /v1/tasks/{id}/run` (returns 204).
- The compact task requires `notificationCondition` field (e.g., `"FAILURE"`) or creation fails.

**Why S3 TTL/lifecycle rules cannot replace compact:** The compact task does more than delete S3 objects — it also cleans up `SoftDeletedBlobIndex` database records and updates blob store size/count metrics via `recordDeletion()`. External S3 lifecycle rules would bypass these steps, causing orphaned database records and corrupted usage metrics. Nexus previously had a built-in "Expiration Days" S3 lifecycle feature but **removed it in 3.80.0**, replacing it with the `blobsOlderThan` parameter on the compact task.

## Key Takeaways

1. **Nexus is not S3-chatty for reads.** After the first access, downloads are a single GetObject. Browse and search never touch S3.

2. **Writes are moderately expensive.** Each artifact stored costs ~5-7 S3 calls (2 PutObject for content/properties + verification reads). This is inherent to the 2-objects-per-blob design.

3. **Proxy cache misses are cheap per artifact.** A single cache miss costs ~7 S3 calls, comparable to a direct upload.

4. **No ListObjects on the hot path.** The only ListObjectsV2 observed was a one-time blobstore health check on first use of a repository. Normal read/write operations use direct key-based access (Get/Put/Head).

5. **Deletes are deferred with a grace period.** No S3 cost at delete time. Orphaned blobs are cleaned up by the `assetBlob.cleanup` task (grace period 60 min, runs every 30 min) followed by the `blobstore.compact` task (issues DeleteObject). Worst-case latency from delete to S3 removal is ~90 minutes. S3 TTL/lifecycle rules cannot substitute for this — the compact task maintains database consistency and metrics.

6. **MinIO compatibility with Nexus 3.93.2 works** with two prerequisites:
   - `nexus.blobstore.s3.ownership.check.disabled=true` (available since 3.89.0)
   - EULA acceptance via REST API before any repository operations
