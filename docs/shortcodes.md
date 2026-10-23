# Internal short URLs

Short URLs use the configured APP_DOMAIN and AppDomainUrl protocol rules,
uppercased, followed by `/L` and ten characters from
`23456789ABCDEFGHIJKLMNOPQRSTUVWXYZ`. Only the short URL is uppercased; target
paths keep their case. SHA-256 of the normalized absolute target URL supplies
the base-34 candidate; collisions increment with carry and wraparound.
If APP_DOMAIN is missing or blank, HTTP callers use a validated request
host_with_port with the same protocol rules and log a warning. A configured
APP_DOMAIN always takes precedence. Invalid authorities, localhost and loopback
addresses cannot produce short URLs or QR labels; allocation returns an uncached
503 when no usable origin is available. Non-HTTP callers need APP_DOMAIN.
The resolved origin is passed explicitly through allocation and resolution;
request hosts are never stored globally or in the path-only mappings.

## Deployment

Before enabling allocation on a deployment, run:

```
bundle exec rake db:mongoid:create_indexes
```

The Mongoid index job runs `shortcodes:ensure_indexes` as a prerequisite,
before normal index creation can encounter incompatible same-named indexes.
The standalone shortcode task checks for duplicate values, replaces incompatible
partial/sparse/non-unique indexes, creates full unique indexes, and verifies
them again even if this process previously verified the collection.
It creates and verifies the separate unique `code` and `target_url` indexes
in `shortcodes`. The release task `data:ensure_unique_indexes` also creates full unique indexes
and replaces older partial or sparse shortcode indexes.
On first use of an absent collection, allocation creates both indexes before
persisting any mapping. An existing collection with incompatible indexes still
requires the repair task; allocation refuses to proceed without full uniqueness.
No resource backfill is
required; mappings are created when requested. Preserve and back up this
collection: mappings are permanent, immutable, and never recycled. Retain the
public hostname for printed links (or keep it routing to the application).
New Mongo mappings and Redis writes store only the validated internal path.
Resolution rebuilds the absolute URL with the current AppDomainUrl base URL;
changing APP_DOMAIN reuses these path mappings and their codes. Hashing for a
new allocation still uses the normalized absolute URL. Legacy absolute Mongo
mappings remain immutable and are reused when they match the current origin;
cache refills store their paths. Legacy absolute cache entries remain readable.
No historical migration is performed. Absolute Mongo entries tied to an old
origin need an explicit migration strategy before that origin is changed.

## API and routing

Authenticated `POST /api/shortcodes` takes `{ "target_url": "/api/tool/<id>/public.html" }`
and returns `{ "code": "...", "short_url": "HTTPS://.../L..." }`.
Normal session authentication, TOTP, CSRF, and target visibility apply.
The response is private/no-store. Unavailable resources return 404, unsupported
targets 422, and unavailable storage 503. Supported paths are singular public
shop/tool HTML routes (including `/api` aliases), plural public HTML routes,
`/tools/<id>/request-checkout`, and `/rentals/spots/<id>`. IDs are stable Mongo IDs.
External origins, credentials, query strings, fragments, and shortcode targets
are rejected. Existing long and rental-number URLs remain functional.

GET/HEAD shortcode requests are rewritten internally before Rails routing.
No HTTP redirect expands the short URL; ordinary authentication redirects are
preserved. Incoming query strings are discarded. Existing controllers enforce
permissions and visibility. Public HTML keeps existing caching and cookie rules.
React shells receive an escaped target metadata field. An inline Rails-owned
script replaces browser history before the external JavaScript bundle loads,
so shortcode routing does not depend on a particular React bundle version. Unknown codes return uncached generic 404s;
storage failure without a cache hit returns an uncached 503.

## Cache and QR behavior

Checkout Required sheets allocate/reuse the existing singular shop/tool public
HTML target through `ShortUrl` after authorizing the viewer. Both copies on a
sheet encode the same uppercase short URL; selecting one copy reuses that code.
Unlike the older QR dialog, this flow never falls back to a long URL. Invalid
origins, localhost, missing unique indexes, or storage failures prevent sheet
creation with an uncached 503. SVG sheets are private/no-store and do not use
the public SVG render cache. See [sheet contracts](checkout.MD#printable-checkout-required-sheets).

`shortcodes:v1:<code>` stores the target in Redis for exactly 86,400 seconds.
Mongo is authoritative; Redis failure or eviction falls back to an indexed
lookup. New mappings are persisted before cache publication. Cache hits do not
read Mongo. No negative cache is used. Do not change the shared Redis eviction
policy: other application keys include operational locks.

Public SVGs and shop/tool/rental QR dialogs encode the exact uppercase short URL,
using alphanumeric QR encoding where supported. Existing error-correction
settings remain. SVGs retain their separate 30-minute render cache and three-day
HTTP lifetime. Old browser-cached SVGs can retain long links for three days.
Rental Copy Link uses the same allocation service as its QR dialog. The React rental spot **Label** button (printable PNG
labels) allocates the same `/rentals/spots/<id>` short URL but, unlike the QR dialog, never falls back to the full URL: if
allocation fails it produces no label. QR allocation failures show a warning and render a usable full-URL QR label,
including PNG download and image copy. Shop/tool fallback URLs use the configured
HTTPS application domain, never the browser origin. If configuration is unavailable,
the dialog reports an error instead of printing an internal hostname. Admin, board,
and resource-manager users can generate shop labels from Tool Checkouts or Workshop
Details; tool checkout approvers can generate labels for their permitted tools. Rental
Copy Link falls back to a full URL and displays it for manual copying if needed;
recovery feedback sits beside the Copy Link action. The action is disabled
while its selected spot’s URL is preloading or copying. Clipboard writes run
directly during the click, with no preceding network wait, and changed selections
ignore stale preload results. Email/Slack link generation,
password tokens, and TOTP QR payloads are outside this feature.

Allocation collisions, missing indexes, and backend failures use `[ShortUrl]`
log messages. Errors log classes rather than database credentials or URLs.
