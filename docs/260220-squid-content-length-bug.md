# Squid Content-Length Bug Analysis

## Problem Summary

When Squid proxies APT repositories (specifically NVIDIA CUDA repos), cached responses after revalidation have `Content-Length: 0` headers but send the full payload data. This causes HTTP parsing errors in clients.

Example symptom:

```text
Content-Length header: 0
Actual payload size: 96629 bytes
⚠️  MALFORMED RESPONSE DETECTED!
```

## Root Cause

Critical bug in Squid's 304 Not Modified response handling that affects cached entries after revalidation.

### Bug Sequence

1. **Initial cache**: Request fetches `Packages.gz`, cached with correct `Content-Length: 96629`
   - Log: `TCP_MISS/200 97153`

2. **Cache hits**: Multiple requests served from memory cache successfully
   - Log: `TCP_MEM_HIT/200 97164`

3. **Revalidation**: After max-age=300 expires, Squid sends conditional request
   - Server responds with `304 Not Modified` (no body, no Content-Length per HTTP spec)
   - Log: `TCP_REFRESH_UNMODIFIED/200 97191`

4. **Bug triggers during 304 processing**:
   - `HttpReply::recreateOnNotModified()` called (src/HttpReply.cc:265-278)
   - Calls `header.update(&reply304.header)` which deletes Content-Length from cached entry
   - Calls `hdrCacheInit()` which sets `content_length = 0` (default when header missing)
   - Cached entry now has `content_length = 0` but body data remains intact

5. **Subsequent requests serve malformed response**:
   - Headers show `Content-Length: 0`
   - Full 96629 bytes of body sent
   - Log: `TCP_MEM_HIT/200 97192` or `TCP_MEM_HIT_ABORTED/200 37427` after client abort

### Critical Code: HttpHeader::update() (src/HttpHeader.cc:400-431)

```cpp
void HttpHeader::update(HttpHeader const *fresh)
{
    // First pass: Delete all headers that exist in 304 response
    while ((e = fresh->getEntry(&pos))) {
        delById(e->id);  // Deletes header even if just to check it
    }

    // Second pass: Add all headers from 304 response
    while ((e = fresh->getEntry(&pos))) {
        addEntry(e->clone());
    }
}
```

Issue: Headers present in cached response but absent in 304 (like Content-Length) get deleted and not restored.

### 2019 Commit Context

A 2019 commit (#485) introduced a split-brain architecture to prevent crashes from concurrent access:

```cpp
// MemObject has TWO replies:
HttpReplyPointer reply_;         // baseReply() - keeps original sizes
HttpReplyPointer updatedReply_;  // updatedReply() - has 304-updated headers
```

- `baseReply()` - Used for size calculations, never updated (prevents corruption)
- `updatedReply_` - Used for serving headers to clients (contains 304-updated metadata)
- `freshestReply()` - Returns `updatedReply_` if exists, otherwise `baseReply()`

**Design flaw**: This separates size calculation from header serving, breaking HTTP semantics. When `updatedReply_` has `Content-Length: 0` but body size is calculated from `baseReply()` (96KB), the response becomes malformed.

## Why NVIDIA Repos Trigger This

NVIDIA's Akamai CDN characteristics:

- **Short TTL**: `Cache-Control: max-age=300` (5 minutes) → frequent 304 revalidations
- **Large files**: Packages.gz ~97KB → obvious Content-Length mismatch
- **HTTP/2**: Different connection handling

Comparison:

- Debian: max-age=120 but uses Varnish
- Ubuntu: max-age=0, s-maxage=3300 (55 min for proxies)

## Recommended Fix

Preserve Content-Length from original cached response when creating `updatedReply_`:

```cpp
HttpReply::Pointer
HttpReply::recreateOnNotModified(const HttpReply &reply304) const
{
    const Pointer cloned = clone();
    const int64_t originalContentLength = content_length;  // Save original

    cloned->header.update(&reply304.header);
    cloned->hdrCacheClean();
    cloned->header.compact();

    // Preserve Content-Length: 304 has no body so no Content-Length,
    // but cached body hasn't changed
    if (!reply304.header.has(Http::HdrType::CONTENT_LENGTH) && originalContentLength >= 0) {
        cloned->header.putInt64(Http::HdrType::CONTENT_LENGTH, originalContentLength);
    }

    cloned->hdrCacheInit();
    return cloned;
}
```

Rationale:

- 304 responses must not have message body (RFC 7232 Section 4.1)
- Cached body hasn't changed during revalidation
- Content-Length must match actual body being sent

## Workarounds

### Purge affected entries (temporary)

```bash
squid-purge https://developer.download.nvidia.com/compute/cuda/repos/debian13/x86_64/Packages.gz
```

### Disable revalidation (not recommended)

```conf
refresh_pattern developer.download.nvidia.com 0 20% 4320 reload-into-ims override-expire
```

Downside: May serve stale content, doesn't fix root cause.

## Testing the Fix

After applying patch:

1. Clear cache and restart:

   ```bash
   rm -rf /var/cache/squid/*
   squid -z
   systemctl restart squid
   ```

2. Test sequence:

   ```bash
   # Initial fetch (should cache)
   curl -x proxy:3128 https://developer.download.nvidia.com/.../Packages.gz

   # Wait 6 minutes (beyond max-age=300)
   sleep 360

   # Trigger revalidation (should get 304)
   curl -x proxy:3128 https://developer.download.nvidia.com/.../Packages.gz

   # Verify Content-Length is correct
   curl -x proxy:3128 -I https://developer.download.nvidia.com/.../Packages.gz
   ```

3. Expected: Content-Length matches actual payload size

## References

- HTTP/1.1 RFC 7232 Section 4.1: "304 response MUST NOT contain a message-body"
- Squid source: src/HttpReply.cc:265-278, src/HttpHeader.cc:400-431
- Squid commit #485 (2019): Re-enabled updates of stored headers on HTTP 304 responses
