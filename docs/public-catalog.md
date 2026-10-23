# Public shop and tool pages

Authenticated [Checkout Required sheets](checkout.MD#printable-checkout-required-sheets)
encode the same shop/tool public HTML shortcodes as the existing QR labels.
Their generation endpoints require resource-scoped authorization; the resulting
printable SVG does not expose private tool notes or membership data. Hidden
resources and open tools cannot generate these signs. Existing public QR and
HTML response caching is unchanged.

`/shops/:id/public` and `/tools/:id/public` return public JSON. Append `.html`
for Rails pages. URLs use MongoDB IDs. Hidden tools and tools with hidden or
missing shops, malformed IDs, and missing IDs return 404. HTML requests display
an alphabetically sorted **Workshops** directory with `Cache-Control: no-store`;
JSON and SVG requests retain the generic `Not Found` body.

Canonical HTML URLs are `/shop/:id/public.html` and `/tool/:id/public.html`.
The plural URLs remain supported. Their `/api/shop/...` and `/api/tool/...`
aliases are also unauthenticated.

`/shop/:id/public.svg` and `/tool/:id/public.svg` produce RQRCode SVGs encoding
uppercase [short URLs](shortcodes.md) resolving internally to
`/api/shop/:id/public.html` or the corresponding tool URL. `APP_DOMAIN` accepts a hostname, host:port, or scheme-prefixed value.
The shared helper uses HTTPS in production and for .com/.net/.org hosts, and HTTP
for other development/test hosts. QR rendering uses
the existing Redis-backed `Rails.cache`, a 30-minute lifetime, visibility checks
before cache access/304, and the same three-day browser/shared-cache policy.
Changing the hostname changes the cache key and ETag. Redis failure falls back
to generating the SVG.

Tool headings link to the wiki. Public shop and tool HTML embeds configured
resource calendars using their synchronized `resource_email` addresses, with
`google_resource_id` conversion retained for legacy records without an email.
A tool page includes its tool and parent-shop calendars,
deduplicating identical resources. Calendar IDs are not added to public JSON.
All public HTML pages include the member portal's footer icons and destinations,
without accessing or changing authentication state. The portal's `(QR)` links
open the corresponding public tool HTML page.

Public HTML reads the current public projection on every origin request, then
uses a content digest plus `PublicCatalogController::TEMPLATE_VERSION` to cache
rendered HTML in `Rails.cache` for 30 minutes. Production's existing Redis cache
store is used. Cache errors fall back to rendering. Increment the template
version whenever changing the templates or their shared styling. Successful
responses permit browser/shared caching for three days; those copies can remain
visible after an origin edit or disabling. Visibility is checked before ETags.

Create the declared Mongoid indexes as part of normal deployment (`bundle exec
rake db:mongoid:create_indexes`). The tool list index orders by shop and name,
with ID as a stable tie breaker and disabled available for filtering. No record
backfill is needed: absent and null `open` values read as false.

The public tool page also links approvers to `/tools/:id/check-out-member` (not shown for tools
that need no checkout). It uses the same authentication, visibility and login-return handling as
`/tools/:id/request-checkout`, serves the app shell, and creates nothing; the app then opens that
tool's Workshops entry with the Check Out Member dialog for viewers who may approve it.

`/tools/:id/request-checkout` authenticates before checking visibility and
serving the SPA shell. Its React form fetches only `/api/tools/:id/coreq.html`
(JSON context despite the historical-style suffix) and submits through the
existing checkout request POST. GET never creates requests. Login return paths
are restricted to stable tool URLs and retained through Firebase and TOTP.
Member-specific responses are private and not stored.

An open tool remains visible with “No checkout required”. New requests are
blocked in the API, Slack and model validation. Existing requests/checkouts and
administrative grants remain intact. Reservations omit only the automatic
self-checkout requirement; explicit prerequisites remain required.

Focused verification:

```sh
bundle exec rspec spec/requests/public_catalog_spec.rb spec/requests/public_catalog_qr_spec.rb spec/requests/checkout_links_spec.rb spec/models/tool_open_spec.rb spec/requests/pending_tool_checkout_requests_spec.rb spec/jobs/slack_checkout_request_job_spec.rb spec/controllers/sessions_controller_spec.rb spec/models/reservation_spec.rb
```

Build the React assets before Rails HTML request tests. The suite requires an
explicitly configured test `MLAB_URI` and clears that test database.

React verification (from the React repository):

```sh
npm run typecheck
npm test -- --runInBand tests/unit/checkoutDestination.spec.ts
npm run build
node tests/browser/checkout-links.cjs
```

The browser check uses mocked APIs, verifies password/TOTP return navigation,
keyboard submission, and form states at 320, 600, 900 and 1440px. It uses Edge
on Windows or Playwright Chromium elsewhere; `BROWSER_CHANNEL` overrides this.
