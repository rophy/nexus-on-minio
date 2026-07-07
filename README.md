# nexus-on-minio

Exploring Sonatype Nexus Repository OSS with MinIO as an S3-compatible blobstore.

Nexus supports S3 blobstores in both Community and Pro editions (since 3.12.0), but only AWS S3 is officially supported. This project tests MinIO compatibility and measures the S3 operation overhead of common Nexus workflows.

## Background

Nexus stores each blob as **two S3 objects**:
- `<uuid>.bytes` — artifact content
- `<uuid>.properties` — metadata (name, content-type, sha1, size, etc.)

Objects are sharded across `content/vol-XX/chap-YY/` prefixes (43 volumes x 47 chapters = 2,021 buckets). Normal read/write uses direct `GetObject`/`PutObject` by computed key — no `ListObjects` on the hot path. `ListObjects` is only used by maintenance tasks (reconcile, compact).

## What we're testing

### 1. MinIO RBAC policy compatibility

Nexus calls `GetBucketAcl` to verify bucket ownership. MinIO uses policy-based access control instead of ACLs, so this check fails. Nexus 3.89.0 added a system property to bypass it:

```
-Dnexus.blobstore.s3.ownership.check.disabled=true
```

We verify that Nexus can create and use an S3 blobstore on MinIO with only IAM policies (no ACL support required).

### 2. AWS SDK v2 compatibility

Nexus 3.87.0 upgraded the AWS SDK from v1 to v2, which introduced new request checksums, headers, and stricter behavior. This is known to break some S3-compatible backends. We test against a current MinIO release to confirm basic operations work under SDK v2.

### 3. S3 operation overhead

We measure how many MinIO/S3 API calls Nexus makes for common operations, using `mc admin trace` to capture every request.

| Scenario | What we measure |
|---|---|
| Upload a single artifact | Number of `PutObject` and other S3 calls |
| Download an artifact | Number of `GetObject` calls |
| Upload a multi-file artifact (e.g. Maven jar + pom + checksums) | Total S3 writes per logical artifact |
| Browse / search a repository | Whether S3 is hit or only the database |
| Delete + compact | S3 calls for soft-delete and cleanup |
| Proxy cache miss | S3 writes when caching an upstream artifact |

## Setup

```bash
docker compose up -d
```

This starts:
- **MinIO** — S3-compatible object storage
- **Nexus 3.93.2** — with `nexus.blobstore.s3.ownership.check.disabled=true`

The `minio-init` service pre-creates the `nexus-blobstore` bucket. After Nexus starts, create the S3 blobstore via the REST API:

```bash
# Wait for Nexus to be ready
until docker compose logs nexus 2>&1 | grep -q "Started Sonatype Nexus"; do sleep 5; done

# Get admin password
docker compose exec nexus cat /nexus-data/admin.password

# Allow internal MinIO hostname through SSRF protection
curl -u admin:<password> -X PUT http://localhost:8081/service/rest/v1/security/ssrf-protection \
  -H 'Content-Type: application/json' \
  -d '{"enabled": true, "allowedIPs": [], "allowedDomains": ["minio"]}'

# Create the S3 blobstore
curl -u admin:<password> http://localhost:8081/service/rest/v1/blobstores/s3 \
  -H 'Content-Type: application/json' \
  -d '{
    "name": "minio",
    "bucketConfiguration": {
      "bucket": {"region": "us-east-1", "name": "nexus-blobstore", "prefix": "", "expiration": -1},
      "bucketSecurity": {"accessKeyId": "minioadmin", "secretAccessKey": "minioadmin"},
      "advancedBucketConnection": {"endpoint": "http://minio:9000", "forcePathStyle": true}
    }
  }'
```

## Measuring S3 overhead

Use `mc admin trace` to capture all S3 API calls in real-time:

```bash
# Configure mc to talk to MinIO
docker compose exec minio mc alias set local http://localhost:9000 minioadmin minioadmin

# Stream all S3 calls (run in a separate terminal)
docker compose exec minio mc admin trace --call s3 --verbose local
```

Then perform a Nexus operation and observe the S3 calls generated.
