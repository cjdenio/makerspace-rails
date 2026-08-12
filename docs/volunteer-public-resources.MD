# Public Volunteer Resources

The volunteer bounty and leaderboard routes are accessible without a member
session. They share optional token protection but expose different formats and
data.

## Shared token protection

Both routes use these settings:

| Purpose | Portal setting | Environment fallback |
| --- | --- | --- |
| Enable protection | `volunteer_bounty_token_enabled` | `VOLUNTEER_BOUNTY_TOKEN_ENABLED` (defaults to `false`) |
| Shared secret | `volunteer_bounty_token` | `VOLUNTEER_BOUNTY_TOKEN` (defaults to empty) |

A portal setting takes precedence over its environment fallback when the portal
setting is present. Protection is enabled only when the resulting enabled value
is exactly `true`. When enabled, append `token` as a query parameter. The token
must be present, nonempty, and exactly match the configured secret. A missing,
empty, or incorrect token—or enabling protection without a nonempty configured
secret—returns `403 Forbidden`.

Use one `?` followed by `&` between parameters, and URL encode every query value:

```text
?shop=Metal%20Shop&token=REDACTED
```

Never embed real secrets in documentation, QR artwork, screenshots, or public
URLs. URLs can leak through browser history, logs, analytics, referrer headers,
and screen-sharing. Prefer device-side protected configuration and rotate the
shared token if exposure is suspected.

## Bounties

### Route and formats

The canonical route is `GET /volunteer/bounties`. It supports:

- HTML at `/volunteer/bounties`;
- JSON at `/volunteer/bounties.json`; and
- XML at `/volunteer/bounties.xml`.

Clients can also negotiate the matching representation with an `Accept` header.
HTML is intended for browsers and display screens; JSON and XML are public feed
representations.

### Filtering and contents

`shop` is optional. After URL decoding and trimming, it performs a
case-insensitive **substring** match against the shop name. Thus `wood` can
match `Wood Shop`; this is not an exact-name filter. Encode spaces and reserved
characters, such as `shop=Metal%20Shop`.

Only currently claimable, parent-level tasks are returned. Child tasks spawned
from multi-use claims and recurring tasks that are cooling down are excluded.
Results are ordered by task number. JSON and XML expose these public task
fields:

- `id`
- `task_number`
- `title`
- `description`
- `credit_value`
- `status`
- `shop_name`
- `prerequisite_tools`
- `claimed_at`
- `next_available`

An empty set is a successful response, not a not-found error. Task descriptions
and shop/tool associations are public through these feeds, so private volunteer
instructions must not be stored in the exposed fields.

### Examples

An unprotected display screen:

```text
https://portal.example.org/volunteer/bounties?shop=Wood%20Shop
```

A protected JSON consumer with both filtering and token protection:

```sh
curl 'https://portal.example.org/volunteer/bounties.json?shop=Wood%20Shop&token=REDACTED'
```

An XML feed:

```sh
curl -H 'Accept: application/xml' \
  'https://portal.example.org/volunteer/bounties?shop=wood'
```

## Leaderboard

### Route and formats

The canonical route is `GET /volunteer/leaderboard`. HTML is available at that
path for browsers and display screens. JSON is available with the `.json`
suffix or `Accept: application/json`. XML is not supported.

### Ranking and contents

The leaderboard aggregates **lifetime** credit values for credit records whose
status is `approved` or `reversal`, sorts totals from highest to lowest, omits
members whose member record has been deleted, and then assigns the remaining
entries sequential ranks. Each public entry contains:

- `rank`
- `name` (the member's full name)
- `lifetime_credits` (rounded to one decimal place)

The `volunteer_leaderboard_top` portal setting controls the maximum number of
entries and defaults to `10` when unset. The caller cannot override this count.
An empty leaderboard is a successful response.

### Examples

A display screen:

```text
https://portal.example.org/volunteer/leaderboard
```

A protected JSON consumer:

```sh
curl 'https://portal.example.org/volunteer/leaderboard.json?token=REDACTED'
```

### Privacy

Publishing the leaderboard discloses member full names and lifetime credit
totals to anyone who can reach the route (or anyone who has the shared token
when protection is enabled). Operators should obtain appropriate consent,
consider whether names and rankings are suitable for the display's location and
audience, restrict access when appropriate, and establish a process for removal
requests. Token protection reduces casual access but does not make a publicly
visible screen private.
