# Nexus-on-MinIO S3 Overhead Test Results

**Date:** 2026-07-07  
**Nexus version:** 3.93.2 (Community Edition)  
**MinIO image:** minio/minio:latest  
**MinIO object count:** 0 before tests, 51 after tests

## Summary

| Scenario | Total S3 Calls | Breakdown |
|---|---|---|
| Raw Upload (1MB) | 5 | 3 PutObject, 1 HeadObject, 1 GetObject |
| Raw Download (first) | 7 | 4 GetObject, 2 HeadBucket, 1 PutObject |
| Raw Re-download | 1 | 1 GetObject |
| Maven Upload (jar + pom) | 11 | 6 PutObject, 3 GetObject, 2 HeadObject |
| Proxy Cache Miss | ~8 | 3 PutObject, 3 GetObject, 1 HeadObject, 0-1 HeadBucket |
| Proxy Cache Hit | 1 | 1 GetObject |
| Browse Components | 0 | — |
| Browse Assets | 0 | — |
| Search by keyword | 0 | — |
| Delete Component | 0 | — |

## Analysis

### Upload (raw, 1 artifact = 5 S3 calls)

A single 1MB raw artifact upload produces:
- **3 PutObject** — the `.bytes` content, the `.properties` metadata, and likely a temporary blob
- **1 HeadObject** — checking if the blob already exists
- **1 GetObject** — reading back the `.properties` to verify/update

This confirms the **2-objects-per-blob** design. The extra calls are overhead from Nexus verifying the write.

### Upload (Maven, jar + pom = 11 S3 calls)

Uploading a jar and a pom (2 logical files) produces 11 S3 calls:
- **6 PutObject** — `.bytes` + `.properties` for each artifact, plus maven-metadata.xml updates
- **3 GetObject** — reading back properties and existing metadata
- **2 HeadObject** — existence checks

Roughly **5-6 S3 calls per file** uploaded, consistent with the raw upload pattern.

### Download (first = 7 calls, subsequent = 1 call)

The first download of a raw artifact:
- **4 GetObject** — content + properties reads (multiple, possibly due to attribute refresh)
- **2 HeadBucket** — bucket existence validation
- **1 PutObject** — updating the `.properties` file (last-accessed timestamp or similar)

Subsequent downloads produce only **1 GetObject** — Nexus caches the blob location and attributes, so it goes straight to the content.

### Proxy Cache Miss (~8 S3 calls)

Fetching a single POM file from Maven Central through a proxy repository triggers approximately **8 S3 calls**:
- **3 PutObject** — the cached artifact content (`.bytes`), its metadata (`.properties`), and associated upstream metadata
- **3 GetObject** — reading back written properties and checking existing cached content
- **1 HeadObject** — existence check
- **0-1 HeadBucket** — bucket validation (intermittent)

This is consistent with the per-artifact overhead seen in direct uploads (~5-8 calls per blob).

**Note on first-ever proxy fetch:** The very first fetch from a proxy repository triggers an additional one-time **ListObjectsV2** on `content/directpath/health-check/<repo-name>`. This is a blobstore health check, not part of the cache miss flow. It does not repeat on subsequent cache misses. The original test run captured this along with eager metadata fetching (checksums, parent POMs, maven-metadata.xml at each path level), inflating the count to 72 calls. After isolating the health check warmup, steady-state cache miss cost is ~8 S3 calls per artifact.

### Proxy Cache Hit (1 S3 call)

Once cached, re-fetching the same artifact produces only **1 GetObject** — Nexus serves directly from MinIO without rechecking upstream.

### Browse / Search (0 S3 calls)

Browsing components, browsing assets, and keyword search produce **zero S3 calls**. These operations are served entirely from the Nexus database (H2/PostgreSQL), confirming that S3 is not on the hot path for metadata queries.

### Delete (0 S3 calls)

Deleting a component via the REST API produces **zero S3 calls**. The soft-delete is recorded in the database only. The actual S3 object cleanup happens later when the "Compact Blobstore" task runs (which cannot be created via REST API in Nexus 3.93.2 — it requires the admin UI).

## Key Takeaways

1. **Nexus is not S3-chatty for reads.** After the first access, downloads are a single GetObject. Browse and search never touch S3.

2. **Writes are moderately expensive.** Each artifact stored costs ~5-8 S3 calls (2 PutObject for content/properties + verification reads). This is inherent to the 2-objects-per-blob design.

3. **Proxy cache misses are cheap per artifact.** A single cache miss costs ~8 S3 calls, comparable to a direct upload. The first-ever fetch from a proxy repo incurs additional one-time overhead (health check + eager metadata caching), but subsequent misses are steady-state.

4. **No ListObjects on the hot path.** The only ListObjectsV2 observed was a one-time blobstore health check on first use of a repository. Normal read/write operations use direct key-based access (Get/Put/Head).

5. **Deletes are deferred.** No S3 cost at delete time. The cost is paid later during compaction, which scans `.properties` files for `deleted=true` markers.

6. **MinIO compatibility with Nexus 3.93.2 works** with two prerequisites:
   - `nexus.blobstore.s3.ownership.check.disabled=true` (available since 3.89.0)
   - EULA acceptance via REST API before any repository operations
