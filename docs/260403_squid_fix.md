# Squid Content-Length 304 Revalidation Bug — Final Report

**Date:** 2026-04-03
**Squid version affected:** 8.0.0-VCS (fork at `ZJUSCT/squid`)
**Fix commits:** `74adf10` (initial fix), `3e0bba1` (duplication fix)
**Component:** `src/HttpReply.cc:265-291`, `src/HttpHeader.cc:399-430`

## Problem Statement

When Squid proxies APT repositories through ssl_bump (HTTPS interception) — specifically NVIDIA CUDA repos served by Akamai CDN — cached responses after 304 Not Modified revalidation accumulate duplicate `Content-Length` headers. This violates HTTP/1.1 semantics and causes client-side parsing failures (ABORTED connections).

### Observed Symptoms

```
# After 1st revalidation: 2 Content-Length headers
Content-Length: 184745
Content-Length: 184745

# After 2nd revalidation: 3 Content-Length headers
Content-Length: 184745
Content-Length: 184745
Content-Length: 184745
```

Access log shows `TCP_REFRESH_UNMODIFIED_ABORTED/200` when clients reject the malformed response.

### NVIDIA/Akamai CDN 304 Response

Verified via direct conditional request:
```
HTTP/2 304
content-type: application/x-gzip
last-modified: Mon, 30 Mar 2026 19:14:03 GMT
etag: "2a271b559b750cc718f71a635150a2d1:1774899759.403784"
cache-control: max-age=300
expires: ...
date: ...
x-cache-status: Hit from child
x-cdn-version: v44
x-cdn: akam
```

**No Content-Length header in the 304.** The CDN correctly omits it per RFC 7232.

## Root Cause Analysis

### Bug Location: `HttpReply::recreateOnNotModified()` (src/HttpReply.cc:265)

When a cached entry is revalidated with a 304 response, `recreateOnNotModified()` is called to merge the 304 headers into the cached reply. The original fix (commit `74adf10`) attempted to preserve Content-Length:

```cpp
// Commit 74adf10 (buggy - causes duplicates)
const int64_t originalContentLength = content_length;
cloned->header.update(&reply304.header);  // may preserve or replace CL
cloned->hdrCacheClean();
cloned->header.compact();

if (!reply304.header.has(Http::HdrType::CONTENT_LENGTH) && originalContentLength >= 0) {
    cloned->header.putInt64(Http::HdrType::CONTENT_LENGTH, originalContentLength);
}
```

### Why Duplicates Occur

`HttpHeader::putInt64()` (src/HttpHeader.cc:1110-1116) calls `addEntry()`, which **adds** a new header entry without removing the existing one:

```cpp
void HttpHeader::putInt64(Http::HdrType id, int64_t number) {
    addEntry(new HttpHeaderEntry(id, SBuf(), xint64toa(number)));
}
```

Two paths lead to duplicates:

1. **304 omits Content-Length** (NVIDIA/Akamai case): `header.update()` doesn't touch Content-Length in the cloned reply (nothing to delete/add). The original CL survives. Then `putInt64()` adds a **second** Content-Length. Result: 2 headers.

2. **304 includes Content-Length: 0** (some CDNs): `header.update()` first deletes the original CL, then adds CL:0 from the 304. Then the `!reply304.header.has()` check fails (304 HAS CL), so the original value is NOT restored. CL stays at 0.

After a second revalidation, the reply cloned from `freshestReply()` already has 2 CL headers. The fix adds a third. The count grows with each revalidation.

### `HttpHeader::update()` Behavior (src/HttpHeader.cc:399-430)

```cpp
void HttpHeader::update(HttpHeader const *fresh) {
    // Pass 1: Delete all headers in "this" that also exist in "fresh"
    while ((e = fresh->getEntry(&pos))) {
        delById(e->id);   // deletes ALL entries with this ID
    }
    // Pass 2: Add all headers from "fresh" to "this"
    while ((e = fresh->getEntry(&pos))) {
        addEntry(e->clone());
    }
}
```

When the 304 has no Content-Length: Pass 1 and Pass 2 both skip it. The original Content-Length survives unchanged in the cloned reply.

## Fix (commit `3e0bba1`)

```cpp
// src/HttpReply.cc:279-287
// Preserve Content-Length: 304 responses must not have a body (RFC 7232),
// so their Content-Length (if any) is irrelevant to the cached body.
// Always restore the original Content-Length to avoid both deletion (when
// 304 omits it and update() removes it) and duplication (when 304 omits it
// and update() preserves the original).
cloned->header.delById(Http::HdrType::CONTENT_LENGTH);
if (originalContentLength >= 0) {
    cloned->header.putInt64(Http::HdrType::CONTENT_LENGTH, originalContentLength);
}
```

**Key changes from commit `74adf10`:**
1. Added `delById()` before `putInt64()` to remove any existing Content-Length (prevents duplicates)
2. Removed the `!reply304.header.has()` condition (handles both cases: 304 with and without Content-Length)

## Verification

### Environment
- Docker container built from `ZJUSCT/squid` fork (commit `3e0bba1`)
- ssl_bump enabled with self-signed CA
- Production-style config with `refresh_pattern \/(Packages|Sources)(|\.bz2|\.gz|\.xz)$ 0 0% 0 refresh-ims`

### Test Target
`https://developer.download.nvidia.com/compute/cuda/repos/debian13/x86_64/Packages.gz`
(~184KB, `Cache-Control: max-age=300`, served by Akamai CDN)

### Test Results

| Cycle | Access Log | Content-Length Headers | Status |
|-------|-----------|----------------------|--------|
| Initial fetch | `TCP_MISS/200 185283` | 1 header (184745) | Pass |
| Cache hit | `TCP_MEM_HIT/200 185283` | 1 header (184745) | Pass |
| 1st revalidation | `TCP_REFRESH_UNMODIFIED/200 185283` | 1 header (184745) | Pass |
| 2nd revalidation | `TCP_REFRESH_UNMODIFIED/200 185265` | 1 header (184745) | Pass |
| 3rd revalidation | `TCP_REFRESH_UNMODIFIED/200 185297` | 1 header (184745) | Pass |

No ABORTED status. No duplicate headers across 3 consecutive revalidation cycles.

### Response Headers (after 3 revalidations)

```
HTTP/1.1 200 OK
Accept-Ranges: bytes
Content-Type: application/x-gzip
Last-Modified: Mon, 30 Mar 2026 19:14:03 GMT
ETag: "2a271b559b750cc718f71a635150a2d1:1774899759.403784"
Server: AkamaiGHost
Cache-Control: max-age=300
Expires: ...
Date: ...
x-cache-status: Miss from child, Miss from parent
x-cdn-version: v44
x-cdn: akam
Content-Length: 184745
Age: 5
Cache-Status: <container_id>;hit;detail=match
Via: 1.1 <container_id> (squid/8.0.0-VCS)
Connection: keep-alive
```

Exactly one `Content-Length: 184745`. Correct.

## Squid Architecture Notes

### Split-Reply Architecture (commit #485, 2019)

MemObject maintains two reply objects to prevent corruption from concurrent access:
- `reply_` (baseReply) — original 200 OK with body metadata, never updated
- `updatedReply_` — 304-updated metadata, used for serving
- `freshestReply()` — returns `updatedReply_` if set, else `baseReply()`

### Response Flow for ssl_bump Revalidation

1. `cacheHit()` detects stale entry → `processExpired()`
2. `processExpired()` saves state, creates new IMS request entry, starts `FwdState`
3. Origin returns 304 → `HandleIMSReply` → `handleIMSReply()`
4. `handleIMSReply()` calls `StoreEntry::updateOnNotModified()` → `recreateOnNotModified()`
5. Updated reply stored as `updatedReply_` via `mem_obj->updateReply()`
6. `sendClientOldEntry()` → `restoreState()` → `sendMoreData(lastStreamBufferedBytes)`
7. `sendMoreData()` → `cloneReply()` (clones `freshestReply()`) → `buildReplyHeader()` → sends to client

### Key Files

| File | Role |
|------|------|
| `src/HttpReply.cc:265-291` | Fix location: `recreateOnNotModified()` |
| `src/HttpHeader.cc:399-430` | `update()` — merges 304 headers into cached reply |
| `src/HttpHeader.cc:1110-1116` | `putInt64()` — adds (not replaces) header entries |
| `src/store.cc:1452-1478` | `updateOnNotModified()` — orchestrates the update |
| `src/client_side_reply.cc:1449` | `cloneReply()` — clones `freshestReply()` for client |
| `src/client_side_reply.cc:1220-1442` | `buildReplyHeader()` — final header processing |

## References

- RFC 7232 Section 4.1: 304 Not Modified
- Squid fork: `https://github.com/ZJUSCT/squid`
- Production deployment: `report/reference/deployment.yaml`, `report/reference/configmap.yaml`
- Docker build: `report/reference/Dockerfile.dev` (builds from commit `3e0bba1`)
