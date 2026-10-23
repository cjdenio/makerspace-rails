# Public Resources

This document is the source-of-truth inventory for public, deep-linkable Rails
resources owned by this repository. Add a row whenever a server-rendered page or
API endpoint is intentionally usable without a member session, and link a feature
document that follows the structure below.

| Route pattern | HTTP method | Intended audience/device | Authentication or token behavior | Supported formats | Required parameters | Optional parameters | Owning controller | Feature document |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `/api/members/sign_in` | `POST` | Portal browser/PWA/native clients | Password authentication or existing session/remember cookie; CSRF protected; TOTP may be required | JSON | `member.email`, `member.password` for credential login; empty body for restoration | `member.rememberMe` (default false, phones only) | `SessionsController#create` | [Authentication](authentication.md) |
| `/api/auth/firebase_login` | `POST` | Portal provider-login clients | Verified Firebase credential; CSRF protected; TOTP may be required | JSON | `id_token` | `rememberMe` (default false, phones only) | `FirebaseAuthController#login` | [Authentication](authentication.md) |
| `/manifest.webmanifest`, `/service-worker.js`, `/offline.html`, `/pwa-icon.png`, `/pwa-icon-192.png`, `/pwa-icon-512.png` | `GET` | Installable member portal | Public static files; manifest references 192×192 and 512×512 PNG icons; offline page contains no member data | Manifest JSON, JS, HTML, PNG | None | None | Static public file server | [NFC/mobile deployment](../../makerspace-react-2026/docs/nfc-mobile.md) |
| `/api/shortcodes/:code` | `GET` | MMS Portal QR scanner and public API consumers | No session; destination retains its authorization | JSON | `code` (path) | None | `ShortcodeResolutionsController#show` | [Shortcode resolution](shortcode-resolution.MD) |
| `/reservations/agenda` | `GET` | Shop displays, kiosks, and direct browser/API consumers | No member session; optionally requires `token` when a reservation token is configured | HTML, JSON | `shop` (query) | `tool`, `token` (query); `.json` extension or JSON `Accept` header | `ReservationAgendasController#index` | [Shop and tool reservations](reservations.MD#public-reservation-agenda) |
| `/api/rental_spots/:id/public` | `GET` | QR/deep-link visitors and Member Portal pre-login landing pages | No member session or token | JSON | `id` (path; MongoDB ID or spot number) | None | `RentalSpotsController#public_show` | [Public rental spots](rental-spots.MD) |
| `/volunteer/bounties` | `GET` | Public displays, integrations, and prospective volunteers | No member session; shared `token` required only when volunteer token gating is enabled | HTML, JSON, XML | None | `shop`, `token` (query); `.json`/`.xml` extension or matching `Accept` header | `Volunteer::BountiesController#index` | [Public volunteer resources](volunteer-public-resources.MD#bounties) |
| `/volunteer/leaderboard` | `GET` | Public displays, browsers, and integrations | No member session; shared `token` required only when volunteer token gating is enabled | HTML, JSON | None | `token` (query); `.json` extension or JSON `Accept` header | `Volunteer::LeaderboardController#index` | [Public volunteer resources](volunteer-public-resources.MD#leaderboard) |

## Repository boundary

Checkout Required sheet generation uses authenticated POST endpoints at
`/api/shops/:id/checkout_required_sheet` and
`/api/tools/:id/checkout_required_sheet`, with optional `copies` (1 or 2, default
2), SVG success and JSON errors. After authentication, hidden and missing
resources return the same generic 404 before resource-scoped authorization.
These are not public download URLs. Their printed shortcode QRs resolve to the
existing public shop/tool HTML pages;
public visibility and destination authentication remain unchanged. See
[printable sheets](checkout.MD#printable-checkout-required-sheets) for permissions,
formats, errors and printing behavior.

Rails API and server-rendered routes are inventoried here. Member Portal routes
resolved by the catch-all `get '*path'` belong to `makerspace-react-2026` and
must be inventoried in that repository instead. Once the frontend inventory has
a stable location, link this inventory to it and add a reciprocal link there.

## Standard feature-document structure

Every linked feature document must use these sections, in this order:

1. **Purpose** — what the resource provides and why it is public.
2. **Canonical URL** — route pattern and preferred link form.
3. **Audience** — people, displays, scanners, or integrations it supports.
4. **Authentication and token handling** — session requirements, token source,
   precedence, comparison, and failure behavior.
5. **Identifiers and query parameters** — required and optional inputs,
   matching rules, defaults, and encoding.
6. **Formats** — representations and content negotiation.
7. **Response and error behavior** — payload/display contract and status codes.
8. **Examples** — safe, copyable requests and representative responses.
9. **Privacy considerations** — data exposed and safe deployment/link handling.
10. **Operational configuration** — settings, environment variables, caches,
    jobs, or dependencies needed to operate the resource.

Keep feature-document filenames and links consistent with the established names in this inventory.

## Repair-ticket availability and authenticated links

Public tool JSON/HTML and public shop tool lists include tool out_of_service. Public shop JSON and the nested shop in tool JSON also include the shop out_of_service flag. Shop pages, tool pages, and the fallback workshop directory show shop outage warnings. Outage notes and Slack receipts remain excluded from public projections, as do ticket data and reporter identity. Hidden restrictions are unchanged. Tool/shop HTML and JSON use public, max-age=0, s-maxage=0, must-revalidate; QR SVGs retain stable-image caching. Both shop and tool availability participate in ETags/render-cache digests.

Reservation agenda JSON reports `shopOutOfService` and `toolOutOfService`
separately, with `outOfService` true if either is true. Without a tool filter,
`toolOutOfService` is false. HTML displays the applicable shop/tool warnings while
retaining existing reservations.

`/fix-tickets`, `/fix-tickets/:id`, and `/volunteer/tasks/:id` are authenticated portal routes. Public (read-only) tickets require an active unexpired member, not an anonymous browser. Existing shortcode mappings may target the authenticated bounty detail route; resolving a shortcode does not bypass target authorization. Unauthenticated bounty feeds do not include source-ticket content.

`/tools/:id/request-checkout` and `/tools/:id/check-out-member` are authenticated app-shell routes linked from the public tool page. A signed-out visitor is redirected to `/login?return_to=` the same path, and nothing is created by visiting either. `check-out-member` is for approvers: after sign-in the app opens that tool's Workshops entry with the Check Out Member dialog. The public tool page shows its link only for tools that require a checkout.

The proposed volunteer review notification rollout uses authenticated React
links `/volunteer?task=:id` and `/volunteer?event=:id`. They select the exact task
claim (including a child claim) or event for staff review; login and existing
shop-scoped review authorization still apply. They are handled by the portal
catch-all, add no public Rails endpoint, and do not allocate shortcode records.
Background reviewer DMs build their absolute origin from `APP_DOMAIN` and require
deploying the matching Rails notification service and React selection handling.
See [the volunteer handbook](../../makerspace-react-2026/docs/VolunteerCredit.MD#notification-matrix)
and [the job inventory](jobs-tasks-services.MD#volunteer-approval-reminders).

The authenticated `DELETE /api/admin/volunteer_tasks/:id` requires an admin or
board member. It returns 204 after finalizing outstanding Slack reminders, 422
for linked ticket bounties, and 503 (`error: service_unavailable`) when final
reminder delivery cannot complete. A 503 preserves the cancelled task and
retryable receipt; retry deletion after delivery recovers. See the executable
[task response contracts](../spec/api/volunteer_task_responses_spec.rb) and
[generated API specification](../swagger/v1/swagger.json). No anonymous route is
added by this workflow.

## Authenticated checkout expiration contracts

Existing tool/group writes accept checkout_training_plan_url (blank clears);
tool writes additionally accept checkout_expiration_years (null or 1–5).
Existing serializers expose camelCase fields. Checkout responses include
expiresOn (ISO date/null), expirationRevision, expirationStatus
(active/expired/revoked/history), checkoutTrainingPlanUrl, renewedFromId,
supersededById, canManageExpiration, and canRenew. Request responses include
the requested resource's checkoutTrainingPlanUrl.

PATCH /api/admin/tool_checkouts/:id/expiration accepts expires_on (ISO date or
null) and expiration_revision, returning the updated checkout.
POST /api/admin/tools/:id/checkout_expirations accepts expires_on (future ISO
date), returning { affectedCount }. Both require a signed-in admin/board or
shop-scoped RM. Invalid input is 422, missing resources 404, unauthorized scope
403, and stale/historical individual targets 409; unauthenticated access is 401.
List status=expired/history exposes explicit views. active=true means valid
current checkouts; active=false retains its revoked-only meaning.

GET /api/admin/system_configs adds checkout.checkout_expiration_notice_days
and checkout.can_manage. PUT /api/admin/system_configs/update_setting accepts
key=checkout_expiration_notice_days and a whole-number string >=4 (admin-only).
POST /api/admin/system_configs/run_job accepts key=checkout_expiration_notice
(admin-only), returning the existing queued acknowledgment. No anonymous route
or public configuration secret is added. Portal renewal links use the existing
/tool-checkouts?mode=self-service route.
