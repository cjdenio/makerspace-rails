# Card assignment

`POST /api/admin/cards` requires an active, unexpired administrator or board
member for every assignment, including legacy reader imports. The optional
`source` field is audit-only; it cannot change authorization or identifier
validation. The existing NFC client sends `source: "nfc"`, recorded in the
persisted assignment audit message as `Card UID source: NFC scan (client-reported)`.
`import` records `Reader import (client-reported)`; missing or unknown values
record `Unspecified`. Only these fixed labels are logged, never arbitrary source
text. Source identifies the reported client workflow, not verified hardware.

New identifiers must be uppercase hexadecimal ASCII byte pairs, preserving
leading zeroes (for example, `001B1A4D2F`). Legacy identifiers are accepted only
when they exactly match a server-side `RejectionCard` with no holder and a
`timeOf` later than yesterday's start, matching the existing Import New Key
candidate window. Stale, claimed, and unobserved noncanonical identifiers return
422. No API route accepts an arbitrary noncanonical UID based on `source`.

Assignment, old-card invalidation, pending-member activation, rejection-card
claiming, and the finalized audit snapshot share one MongoDB transaction.
Invoice and provisioning effects run only after commit.

`GET /api/admin/cards/lookup?uid=...` accepts an exact UID already assigned to a
card, including noncanonical legacy identifiers. It performs no normalization or
case folding. Unknown canonical UIDs return 404; unknown noncanonical or nonstring
values return 422. Ambiguous duplicate records still return 409. The same active
admin/board policy applies. Legacy results include the card ID and version needed
to release an eligible assignment.

Release creates a `card_released` audit in the same transaction as deletion,
including the actor, former member when available, card ID, full pre-release
snapshot (including UID), and an empty post-release snapshot. The audit remains
after the card is deleted, including for orphaned lost cards. If audit storage
fails, release rolls back; if deletion fails, the audit also rolls back.

## Fob issuers (volunteers)

Open house volunteers can register a member's **first** key fob without being admin
or board. The ability is a safety checkout, not a permission: exactly one tool has
`grants_fob_issuance` set (admin/board only; `Tool` validation allows a single
flagged tool, and resource managers cannot set the flag). A member is a fob issuer
(`Member#fob_issuer?`) while they are fully active and unexpired and hold a current,
unexpired checkout on that tool. Its prerequisites (orientation, tour guide) are
ordinary tool prerequisites enforced by the normal checkout flow; revoking or letting
the checkout expire removes the ability at once.

`FobIssuanceController` (separate from `Admin::CardsController`, which stays admin
and board only) serves these routes, all returning 403 to anyone who is not a fob
issuer, including admins who are not also issuers:

| Route | Purpose |
| --- | --- |
| `GET /api/fob_issuance/members?search=` | Members matching name or email (at least 2 characters, 25 at most) who have no usable card (lost and stolen cards do not count), are not revoked, and are not the caller. Identity fields only: name, email, phone, address, status, expiration, contract on file. No billing, notes, or provisioning data. |
| `GET /api/fob_issuance/members/:id` | The same fields for one eligible member; 404 otherwise. |
| `GET /api/fob_issuance/cards/new` | The most recent unclaimed reader rejection UID, as for the admin form. |
| `POST /api/fob_issuance/cards` | `member_id`, `uid`, optional `source`. Same UID rules as the admin route. Calls `CardManagement.assign!` with `initial_only: true`, so the assignment fails with 409 inside the transaction if the member already has a usable card (a fob issuer can never replace or invalidate a fob). The caller cannot be the recipient. Activation of a pending member, invoice settlement, provisioning and the `card_assigned` audit (actor = the issuer) are the same as for staff. |

The member payload (`GET /api/members/:id` and the sign-in and session responses) carries
`isFobIssuer`, which tells the portal to show the Issue Fob screen.

After a successful issue, `FobIssuanceNotifier` sends the member a Slack direct
message (when their Slack account is linked) and posts to the members relations
channel. Failures there are logged and do not undo the card.
