# Shortcode resolution

## Purpose
Allow the MMS Portal Android scanner to resolve printed short URLs without
scraping the server-rendered destination. Existing `/L{code}` links still work.

## Canonical URL
`GET /api/shortcodes/:code`

## Audience
Mobile scanners and public API consumers.

## Authentication and token handling
No login or token is required. Resolution grants no access to the destination;
checkout requests retain their session, role, eligibility, and TOTP checks.

## Identifiers and query parameters
`code` is the ten-character uppercase code after `/L`, using `2-9A-Z`.
No query parameters are used.

## Formats
JSON only. Success returns `{ "target_path": "/tools/<id>/request-checkout" }`.
Only paths supported by `ShortUrl` can be returned.

## Response and error behavior
200 for a visible supported resource; 404 for malformed/missing codes or
disabled/deleted resources; 503 for resolution infrastructure failure.
Every response uses `Cache-Control: no-store`. Visibility is checked even when
the mapping is cached. This endpoint does not establish a session or redirect.

## Examples
`GET /api/shortcodes/23456789AB` resolves the matching printed `/L23456789AB`.
Consumers validate the returned path and retain their own normal authentication.

## Privacy considerations
Only the existing public destination path is exposed, without member data,
credentials, or private resource details. Knowing a code is not authorization.

## Operational configuration
Uses the existing `APP_DOMAIN`, MongoDB shortcodes, and advisory Redis cache.
No new environment variables, collections, jobs, or email triggers. Deploy
this endpoint before distributing APKs that support shortened QR codes.
