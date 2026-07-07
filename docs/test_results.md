# Nexus-on-MinIO S3 Overhead Test Results

**Date:** 2026-07-07  
**Nexus version:** 3.93.2 (Community Edition)  
**MinIO image:** minio/minio:latest  
**MinIO object count:** 0 before tests, 51 after tests

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
| Delete Component | 0 | DB-only soft-delete |
| Delete + Cleanup + Compact | 11 | See analysis below |

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

### Delete + Cleanup + Compact (11 S3 calls for 1 component)

Deleting a component and running the full cleanup cycle produces **11 S3 calls** across three phases:

**Phase 1 — Delete component (0 S3 calls):**
Nexus removes the database references but leaves the S3 objects orphaned. Object count stays the same (53).

**Phase 2 — assetBlob.cleanup (1 GetObject, 2 PutObject):**
The cleanup task scans the database for orphaned blob references and moves them to `SoftDeletedBlobIndex`. It reads and writes `.properties` files marking blobs as soft-deleted. Object count increased by 1 (53→54) due to a copied soft-deleted attributes file.

**Phase 3 — Compact blobstore (1 HeadBucket, 5 GetObject, 1 DeleteMultipleObjects, 1 DeleteObject):**
The compact task reads blob IDs from `SoftDeletedBlobIndex` (database query — **no S3 LIST**), fetches `.properties` to verify deletion metadata, then batch-deletes the S3 objects:
- **1 HeadBucket** — bucket check
- **5 GetObject** — reading properties files for verification
- **1 DeleteMultipleObjects** — batch removal of `.bytes` + `.properties` pairs
- **1 DeleteObject** — removal of the soft-deleted attributes copy

Objects removed: 3 (54→51), matching the uploaded artifact's `.bytes`, `.properties`, and the soft-delete attributes copy.

**Key finding:** Compact does **not** use ListObjectsV2 to scan the bucket. It reads blob IDs from the `SoftDeletedBlobIndex` database table via `getRecordsBefore()`. This was confirmed by bytecode analysis of `S3BlobStore.doCompactWithDeletedBlobIndex()` and by verifying client IPs in the trace — all ListObjectsV2 calls originated from `[::1]` (the test script's `mc ls`), while Nexus calls came from `172.22.0.3`.

**Test configuration:** Grace period set to 0 via `nexus.assetBlobCleanupTask.blobCreatedDelayMinute=0` and cron disabled via `nexus.assetBlobCleanupTask.cronSchedule=0 0 0 31 12 ?` (Dec 31 only) to allow manual triggering.

**Triggering compact programmatically:** The REST API `POST /v1/tasks` returns 405 (cannot create tasks). However:
- The **ExtDirect API** (`POST /service/extdirect` with `coreui_Task.create`) can create a compact task with `schedule: "manual"`.
- Existing tasks can be triggered via `POST /v1/tasks/{id}/run` (returns 204).
- The compact task requires `notificationCondition` field (e.g., `"FAILURE"`) or creation fails.

**Why S3 TTL/lifecycle rules cannot replace compact:** The compact task does more than delete S3 objects — it also cleans up `SoftDeletedBlobIndex` database records and updates blob store size/count metrics via `recordDeletion()`. External S3 lifecycle rules would bypass these steps, causing orphaned database records and corrupted usage metrics. Nexus previously had a built-in "Expiration Days" S3 lifecycle feature but **removed it in 3.80.0**, replacing it with the `blobsOlderThan` parameter on the compact task. No version since (through 3.95.0) has re-introduced S3-native TTL.

## Key Takeaways

1. **Nexus is not S3-chatty for reads.** After the first access, downloads are a single GetObject. Browse and search never touch S3.

2. **Writes are moderately expensive.** Each artifact stored costs ~5-7 S3 calls (2 PutObject for content/properties + verification reads). This is inherent to the 2-objects-per-blob design.

3. **Proxy cache misses are cheap per artifact.** A single cache miss costs ~7 S3 calls, comparable to a direct upload.

4. **No ListObjects at all during normal operations or compact.** The only ListObjectsV2 observed was a one-time blobstore health check on first use of a proxy repository. Compact reads blob IDs from the database (`SoftDeletedBlobIndex`), not from S3 — it does not scan the bucket. ListObjectsV2 would only be used during a `rebuildDeletedBlobIndex` recovery (fallback path via `doCompactWithoutDeletedBlobIndex`).

5. **Deletes are deferred with a grace period.** No S3 cost at delete time. The full delete-to-S3-removal cycle costs ~11 S3 calls per component (cleanup + compact). Default grace period is 60 minutes (`nexus.assetBlobCleanupTask.blobCreatedDelayMinute`), cleanup runs every 30 minutes. S3 TTL/lifecycle rules cannot substitute — compact maintains database consistency and metrics.

6. **MinIO compatibility with Nexus 3.93.2 works** with one prerequisite:
   - SSRF protection must be disabled or MinIO's IP allowlisted (`/v1/security/ssrf-protection`) — Nexus 3.93.2 blocks connections to private/local IPs by default
   - EULA acceptance via REST API before any repository operations
   - `nexus.blobstore.s3.ownership.check.disabled=true` is **NOT required** — [sonatype/nexus-public#200](https://github.com/sonatype/nexus-public/issues/200) reported that MinIO failed the ownership check because Nexus used `GetBucketAcl`, which MinIO doesn't support. The fix in 3.89.0 ([commit 51396c2](https://github.com/sonatype/nexus-public/commit/51396c2d32d3704a8c94b477a633ed8553c510cf)) changed the check from `GetBucketAcl` to `GetBucketPolicy` and added the disable flag as an extra escape hatch. Since MinIO supports `GetBucketPolicy` (returning `NoSuchBucketPolicy` when no policy is set, which Nexus treats as "ownership confirmed"), the flag is unnecessary on 3.89.0+
