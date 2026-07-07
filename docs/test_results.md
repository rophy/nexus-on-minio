# Nexus-on-MinIO S3 Overhead Test Results

**Date:** 2026-07-07  
**Nexus version:** 3.93.2 (Community Edition)  
**MinIO image:** minio/minio:latest

## Summary

| Scenario | Upload | Download (1st) | Download (cached) |
|---|---|---|---|
| Raw (1MB) | 8 | 4 | 2 |
| Maven (jar + pom) | 11 | 5 | 1 |
| npm (scoped package) | 14 | 5 | 1 |
| PyPI (sdist) | 12 | 4 | 1 |
| Helm (OCI, 1 chart) | 59 | 14 | 4 |

| Scenario | Total S3 Calls | Notes |
|---|---|---|
| Proxy Cache Miss | 8 | Single POM from Maven Central |
| Proxy Cache Hit | 1 | 1 GetObject |
| Browse / Search | 0 | DB-only |
| Delete Component | 0 | DB-only soft-delete |
| Delete + Cleanup + Compact | ~7 per blob | See analysis below |

## Analysis by Format

### Raw (1MB artifact)

| Operation | Calls | Breakdown |
|---|---|---|
| Upload | 8 | 3 PutObject, 2 HeadBucket, 2 GetObject, 1 HeadObject |
| Download (1st) | 4 | 3 GetObject, 1 PutObject |
| Re-download | 2 | 1 GetObject, 1 HeadBucket |

The 2-objects-per-blob design means each artifact creates a `.bytes` (content) and `.properties` (metadata) file. First download updates the `.properties` (last-accessed timestamp). Subsequent downloads go straight to content.

### Maven (jar + pom = 2 files)

| Operation | Calls | Breakdown |
|---|---|---|
| Upload (jar + pom) | 11 | 6 PutObject, 3 GetObject, 2 HeadObject |
| Download (jar) | 5 | 3 GetObject, 1 PutObject, 1 HeadBucket |
| Re-download (jar) | 1 | 1 GetObject |
| Download (pom) | 5 | 3 GetObject, 1 PutObject, 1 HeadBucket |

~5-6 S3 calls per file uploaded. Maven also generates `maven-metadata.xml` which adds PutObject/GetObject overhead.

### npm (scoped package)

| Operation | Calls | Breakdown |
|---|---|---|
| Publish | 14 | 8 PutObject, 3 GetObject, 2 HeadObject, 1 DeleteMultipleObjects |
| Download (tarball) | 5 | 3 GetObject, 1 PutObject, 1 HeadBucket |
| Re-download | 1 | 1 GetObject |

npm publish is more expensive than raw/maven because Nexus stores the tarball, the package metadata JSON, and possibly the extracted `package.json` as separate blobs. The `DeleteMultipleObjects` during publish suggests Nexus replaces a temporary blob.

### PyPI (sdist)

| Operation | Calls | Breakdown |
|---|---|---|
| Upload (sdist) | 12 | 6 PutObject, 3 GetObject, 2 HeadObject, 1 HeadBucket |
| Download | 4 | 3 GetObject, 1 PutObject |
| Re-download | 1 | 1 GetObject |

Similar to Maven. PyPI stores the tarball and metadata, generating ~6 S3 calls per file.

### Helm (OCI chart)

| Operation | Calls | Breakdown |
|---|---|---|
| Push (1 chart) | 59 | 24 PutObject, 25 GetObject, 6 ListObjectsV2, 4 HeadObject |
| Pull (manifest + blobs) | 14 | 10 GetObject, 3 PutObject, 1 HeadBucket |
| Re-pull | 4 | 4 GetObject |

Helm OCI charts use the Docker V2 registry API with Helm-specific media types:
- Config: `application/vnd.cncf.helm.config.v1+json` (chart metadata)
- Layer: `application/vnd.cncf.helm.chart.content.v1.tar.gz` (chart tarball)
- Manifest: `application/vnd.oci.image.manifest.v1+json`

The S3 call count matches Docker images exactly (59 push / 14 pull / 4 re-pull) because both go through the same Nexus Docker registry code path. The blob upload two-step process (POST initiate, PUT complete), manifest storage (by tag and by digest), and layer verification are identical regardless of media type.

### Proxy Cache Miss / Hit

| Operation | Calls | Breakdown |
|---|---|---|
| Cache miss | 8 | 3 PutObject, 3 GetObject, 1 HeadObject, 1 HeadBucket |
| Cache hit | 1 | 1 GetObject |

Cache miss is comparable to a direct upload (~8 calls). Cache hit is a single GetObject — Nexus serves directly from MinIO without rechecking upstream.

**Note on first-ever proxy fetch:** The very first fetch from a proxy repository triggers an additional one-time **ListObjectsV2** on `content/directpath/health-check/<repo-name>`. This is a blobstore health check, not part of the cache miss flow.

### Browse / Search (0 S3 calls)

Browsing components, browsing assets, and keyword search produce **zero S3 calls**. These operations are served entirely from the Nexus database.

### Delete + Cleanup + Compact

Delete is a DB-only soft-delete (0 S3 calls). The cleanup + compact cycle costs approximately **7 S3 calls per blob** deleted:
- **GetObject** — reading `.properties` for verification
- **PutObject** — writing soft-delete markers
- **DeleteMultipleObjects** — batch removal of `.bytes` + `.properties` pairs
- **DeleteObject** — removal of soft-delete attribute copies

Compact does **not** use ListObjectsV2 to scan the bucket. It reads blob IDs from the `SoftDeletedBlobIndex` database table via `getRecordsBefore()`. This was confirmed by bytecode analysis of `S3BlobStore.doCompactWithDeletedBlobIndex()` and by verifying client IPs in the trace.

**Test configuration:** Grace period set to 0 via `nexus.assetBlobCleanupTask.blobCreatedDelayMinute=0` and cron disabled via `nexus.assetBlobCleanupTask.cronSchedule=0 0 0 31 12 ?` (Dec 31 only) to allow manual triggering.

**Why S3 TTL/lifecycle rules cannot replace compact:** The compact task also cleans up `SoftDeletedBlobIndex` database records and updates blob store size/count metrics. External S3 lifecycle rules would bypass these steps, causing orphaned database records and corrupted usage metrics. Nexus removed its built-in S3 lifecycle feature in 3.80.0. No version through 3.95.0 has re-introduced it.

## Key Takeaways

1. **Reads are cheap after first access.** Cached downloads cost 1 GetObject across all formats. Browse and search never touch S3.

2. **Writes cost 5-14 S3 calls per artifact** depending on format. Raw and Maven are cheapest (~5-6 per file). npm and PyPI are moderate (~12-14 per package). OCI-based formats (Helm charts) are more expensive due to the multi-blob registry protocol.

3. **OCI registry formats are heavier.** Helm OCI charts use the Docker V2 registry API, which stores config, layers, and manifests as separate blobs — each requiring its own upload/verification cycle. Multi-layer artifacts scale linearly.

4. **No ListObjects during normal operations or compact.** The only ListObjectsV2 observed during non-OCI operations was a one-time blobstore health check. OCI pushes may use ListObjectsV2 to check existing layers/tags. Compact reads blob IDs from the database, not S3.

5. **Deletes are deferred.** No S3 cost at delete time. The full cycle costs ~7 S3 calls per blob (cleanup + compact). Default grace period is 60 minutes.

6. **MinIO compatibility with Nexus 3.93.2 works** with one prerequisite:
   - SSRF protection must be disabled or MinIO's IP allowlisted (`/v1/security/ssrf-protection`) — Nexus 3.93.2 blocks connections to private/local IPs by default
   - EULA acceptance via REST API before any repository operations
   - `nexus.blobstore.s3.ownership.check.disabled=true` is **NOT required** — [sonatype/nexus-public#200](https://github.com/sonatype/nexus-public/issues/200) reported that MinIO failed the ownership check because Nexus used `GetBucketAcl`, which MinIO doesn't support. The fix in 3.89.0 ([commit 51396c2](https://github.com/sonatype/nexus-public/commit/51396c2d32d3704a8c94b477a633ed8553c510cf)) changed the check from `GetBucketAcl` to `GetBucketPolicy` and added the disable flag as an extra escape hatch. Since MinIO supports `GetBucketPolicy` (returning `NoSuchBucketPolicy` when no policy is set, which Nexus treats as "ownership confirmed"), the flag is unnecessary on 3.89.0+
