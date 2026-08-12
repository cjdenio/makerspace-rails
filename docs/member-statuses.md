# Member Statuses

`Member#status` is a case-sensitive string. The supported values are defined by
the validation in `app/models/member.rb`.

| Value | Meaning |
| --- | --- |
| `activeMember` | A fully activated member. This is the normal status after a card has been issued. |
| `pending` | A member who completed signup but has not yet been fully activated. Creating their card changes this status to `activeMember`. |
| `nonMember` | An account retained in the portal without active member privileges. |
| `revoked` | Membership access has been revoked. Existing revocation workflows handle related deprovisioning and reservation cancellation. |
| `inactive` | An inactive account without active member privileges. |
| `suspended` | A recognized suspended account state. It is not treated as an active membership status unless a feature explicitly defines otherwise. |

## Active membership checks

`Member#active_membership_status?` treats `activeMember` and `pending` as active
membership statuses. General membership checks should use this method instead
of comparing `status` directly.

`Member#active_unexpired?` additionally requires `expirationTime` to be present
and in the future. Expiration is therefore independent of `status`:
`activeMember` and `pending` records may still be expired.

`Member#fully_active_unexpired?` accepts only an unexpired `activeMember`. Use it
only where full activation, rather than general membership eligibility, is
required.

## Pending-member exceptions

Reservations and member-initiated Safety Checkout requests apply narrower
rules to pending members:

- A pending member may reserve only tools with `allow_pending: true`; pending
  onboarding access does not require `expirationTime` to be set.
- Pending members cannot create shop-wide reservations.
- A pending member may request a Safety Checkout only for a tool with
  `allow_pending: true`.
- Staff may directly issue any Safety Checkout to a pending member. The staff
  UI warns that the selected member is still pending but does not block the
  checkout.
- Issuing a card promotes the member from `pending` to `activeMember`.

When missing from a legacy Tool document, `allow_pending` is treated as
`false`.

## Related states

`expired` is not a supported `Member#status` value. It is a derived condition
based on `expirationTime`.

Card validity and reservation status are separate state machines. Values such
as card `lost`/`stolen` and reservation `approved`/`denied` must not be stored
in `Member#status`.
