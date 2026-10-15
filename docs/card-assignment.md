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
