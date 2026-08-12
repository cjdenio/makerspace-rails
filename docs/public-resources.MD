# Public Resources

This document is the source-of-truth inventory for public, deep-linkable Rails
resources owned by this repository. Add a row whenever a server-rendered page or
API endpoint is intentionally usable without a member session, and link a feature
document that follows the structure below.

| Route pattern | HTTP method | Intended audience/device | Authentication or token behavior | Supported formats | Required parameters | Optional parameters | Owning controller | Feature document |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `/reservations/agenda` | `GET` | Shop displays, kiosks, and direct browser/API consumers | No member session; optionally requires `token` when a reservation token is configured | HTML, JSON | `shop` (query) | `tool`, `token` (query); `.json` extension or JSON `Accept` header | `ReservationAgendasController#index` | [Shop and tool reservations](reservations.MD#public-reservation-agenda) |
| `/api/rental_spots/:id/public` | `GET` | QR/deep-link visitors and Member Portal pre-login landing pages | No member session or token | JSON | `id` (path; MongoDB ID or spot number) | None | `RentalSpotsController#public_show` | [Public rental spots](rental-spots.MD) |
| `/volunteer/bounties` | `GET` | Public displays, integrations, and prospective volunteers | No member session; shared `token` required only when volunteer token gating is enabled | HTML, JSON, XML | None | `shop`, `token` (query); `.json`/`.xml` extension or matching `Accept` header | `Volunteer::BountiesController#index` | [Public volunteer resources](volunteer-public-resources.MD#bounties) |
| `/volunteer/leaderboard` | `GET` | Public displays, browsers, and integrations | No member session; shared `token` required only when volunteer token gating is enabled | HTML, JSON | None | `token` (query); `.json` extension or JSON `Accept` header | `Volunteer::LeaderboardController#index` | [Public volunteer resources](volunteer-public-resources.MD#leaderboard) |

## Repository boundary

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
