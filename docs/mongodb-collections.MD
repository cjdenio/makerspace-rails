# MongoDB Collections

## Member remember-cookie lifecycle

The existing top-level `members` collection's `remember_created_at` supports
Devise's two-week renewable phone remember cookies. No new field or index is
introduced. Logout clears this timestamp under the existing global invalidation
policy. Remember credentials also use `authenticatable_salt`, which incorporates
the encrypted password and existing `session_token`; changing either invalidates
old credentials. Persistence is requested per login/device, not stored as a
member-wide preference. Temporary TOTP/persistence state lives in the encrypted
session cookie. See [authentication](authentication.md).

## Tool groups

`tool_groups` stores shop-scoped physical-tool sets, disjoint prerequisites,
description, requestable/reservable/announce flags, announcement channel,
archive state, and revision. Its `(shop_id, name)` index is unique with English
case-insensitive collation; member/prerequisite indexes support reference guards.
`CatalogMutationLock` coordinates groups and physical tools because a unique
index cannot span both collections. Shop deletion destroys all of its active and
archived groups before cascading tool deletion; direct tool deletion still rejects
references from either kind of group.
Before a group is destroyed, its open checkout requests become `deleted` and its
open volunteer requests become `revoked`, using the same cleanup as archival.
Terminal request history remains stored.
Group destruction captures announcement names/channels before target removal and
retires open-request Slack posts after destruction, including during shop cascades.
Included-tool membership edits reconcile satisfied checkout requests for that group
inside the catalog transaction: status becomes `closed` with `checked_out_id`
pointing to an existing active checkout. Unsatisfied and unrelated requests remain
open; archival instead marks requests `deleted`. These changes add no fields or
indexes and require no backfill.

`tool_checkouts` remains physical-tool-only. Optional `group_id`, `group_name`,
`group_revision`, and `approval_batch_id` record provenance. Newly created
checkouts in one group batch share an approver credit ID. Checkout and approver
requests target exactly one of `tool_id` and `tool_group_id`.

`reservations` stores expanded `tool_ids`, `selected_tool_ids`, `tool_group_ids`,
and `group_snapshots`. Snapshots contain the group name, revision, tool IDs and
prerequisite IDs at selection time. `checkout_approvers.group_granted_tool_ids`
retains individual grants when a group assignment is removed.

Before updated clients are released, run `bundle exec rake data:ensure_unique_indexes`.
This also replaces the old open volunteer-request key with
`(member_id, tool_id, tool_group_id, status)`. No checkout backfill is needed.
Also run `RAILS_ENV=production bundle exec rake data:ensure_checkout_indexes` to
install the nonunique `(tool_group_id, status)` checkout-request lookup index used
by group lists, duplicate checks, reconciliation and archival. Model declarations
alone do not install indexes in an existing database.
MongoDB transactions require a replica set.

This is the source-of-truth inventory of MongoDB collections owned by the
Rails application. Collection names are Mongoid's default pluralized model
name unless the model declares `store_in` explicitly.

## Recent collection changes (August 29–September 12, 2026)

This inventory was reconciled against the preceding two weeks of model and
index-task changes:

- `shortcodes` was added for permanent short URL mappings. Both the code and
  target URL are protected by full unique indexes.
- `slack_identity_conflicts` was added to persist unresolved or administratively
  resolved Slack/member identity conflicts.
- `invoices` gained a sparse reservation lookup index, and its transaction ID
  uniqueness contract was made explicit.
- `reservations` gained a sparse invoice lookup index.
- tool-name uniqueness changed from global uniqueness to case-insensitive
  uniqueness within a shop; the catalog query index was also added.
- `locations` was added: a self-referential tree for placing a shop's
  cabinets/shelves/drawers on its floor-plan map, or nesting them under each
  other. Foundational data model only so far -- no controller/route/UI yet.

The table includes collections accessed without a Mongoid model: `checkins` is
queried directly by the administrative space-usage interface, and `notes` is
created/indexed by `data:ensure_unique_indexes` for legacy member notes.

Every collection has MongoDB's implicit unique `_id` index. The **Expected
indexes** column lists additional indexes declared by the application; “None”
means that only `_id` is expected. Direction `1` means ascending. Partial
conditions are included where they are part of the index contract.

| Collection | Model | Purpose | Expected indexes (in addition to `_id`) |
| --- | --- | --- | --- |
| `audit_logs` | `AuditLog` | Immutable audit events for member, billing, rental, reservation, and administrative actions. | `{ log_type: 1 }`; `{ event_type: 1 }`; `{ actor_id: 1 }`; `{ subject_id: 1 }`; `{ resource_type: 1, resource_id: 1 }`; `{ created_at: 1 }` |
| `braintree__notifications` | `BraintreeService::Notification` | Stored Braintree webhook kind, timestamp, and payload data. | None |
| `cards` | `Card` | Member access-card identifiers, holder details, expiration, and validity. | Unique `{ uid: 1 }`, partial when `uid` is a string; `{ member_id: 1 }` (deployment task) |
| `checkins` | None (direct collection access) | Facility check-in events used by administrative check-in and space-usage reporting. | None beyond `_id` is declared by this repository |
| `counter` | `Counter` | Atomic `seq` values for named client sequences, with one document per sequence (for example, `_id: "tickets"`). | None |
| `checkout_approvers` | `CheckoutApprover` | Members authorized to approve Safety Checkouts, optionally scoped to shops or tools. | None |
| `checkout_approver_requests` | `CheckoutApproverRequest` | Open, approved, declined, or revoked requests from checked-out members volunteering to approve checkouts for a tool or group. | Unique `{ member_id: 1, tool_id: 1, tool_group_id: 1, status: 1 }`, partial when `status` is `open` |
| `default_permissions` | `DefaultPermission` | Default enabled/disabled values applied to member permissions. | None |
| `earned_memberships` | `EarnedMembership` | A member's earned-membership program and its requirement/report relationships. | `{ member_id: 1 }` (deployment task) |
| `earned_membership__report` | `EarnedMembership::Report` | Periodic earned-membership reports; report-requirement snapshots are embedded in these documents. | None |
| `earned_membership__requirement` | `EarnedMembership::Requirement` | Earned-membership targets, rollover limits, and term configuration. | None |
| `earned_membership_terms` | `EarnedMembership::Term` | Progress and satisfaction state for individual earned-membership terms. | None |
| `groups` | `Group` | Household/group memberships, their primary member, subscription, and shared expiration. | Unique `{ groupName: 1 }`, partial when `groupName` is a string |
| `invoice_options` | `InvoiceOption` | Purchasable billing choices, prices, plans, promotions, and renewal operations. | None |
| `invoices` | `Invoice` | Amounts due and billing-operation state for members and other invoiceable resources. | Sparse `{ reservation_id: 1 }`; unique `{ transaction_id: 1 }`, partial when `transaction_id` is a string; `{ member_id: 1 }` (deployment task) |
| `locations` | `Location` | Self-referential tree for shop map placement (cabinets/shelves/drawers) and named references into a shop's floor-plan SVG. | `{ shop_id: 1 }`; `{ parent_id: 1 }` |
| `mailtrap` | `MailtrapEvent` | Delivery events received from Mailtrap webhooks and linked back to members/messages. | `{ member_id: 1 }`; unique sparse `{ event_id: 1 }`; `{ message_id: 1 }`; `{ occurred_at: 1 }`; sparse `{ mailtrap_message_id: 1 }` |
| `mailtrap_messages` | `MailtrapMessage` | Outbound email metadata used to correlate messages with later delivery events. | Unique sparse `{ message_id: 1 }`; `{ member_id: 1 }`; `{ email: 1 }`; `{ created_at: 1 }` (the deployment task also enforces the existing member index as non-unique) |
| `members` | `Member` | Member identity, authentication, membership status, expiration, billing links, and provisioning state. | Unique `{ email: 1 }`, partial when `email` is a string; unique `{ customer_id: 1 }`, partial when `customer_id` is a string; `{ status: 1, startDate: 1, expirationTime: 1 }` |
| `membership_snapshots` | `MembershipSnapshot` | Date-stamped snapshots of members considered active for volunteer accounting. | None |
| `payments` | `Payment` | Legacy PayPal/IPN payment and subscription-event records. | `{ member_id: 1 }` (deployment task) |
| `permissions` | `Permission` | Per-member enabled/disabled permission values. | `{ member_id: 1 }` (deployment task) |
| `notes` | None (legacy/direct collection) | Legacy member notes retained and indexed by the deployment task. | `{ member_id: 1 }` (deployment task) |
| `registration_tokens` | `RegistrationToken` | One-time signup invitations carrying email, duration, and role. | None |
| `rejections` | `RejectionCard` | Rejected/unassigned access-card scans available for later assignment. | None |
| `rental_spots` | `RentalSpot` | Physical rentable locations or storage units and their rental-type configuration. | None |
| `rental_types` | `RentalType` | Rental product categories and links to invoice options. | Unique `{ display_name: 1 }`, partial when `display_name` is a string |
| `rentals` | `Rental` | A member's rental assignment, agreement, subscription, expiration, and lifecycle status. | `{ member_id: 1 }` (deployment task) |
| `reservation_blackouts` | `ReservationBlackout` | One-time or recurring periods when a shop cannot be reserved. | `{ shop_id: 1, recurrence: 1, start_date: 1, end_date: 1 }` |
| `reservations` | `Reservation` | Shop/tool reservation intervals, approval state, invoicing, and external-calendar synchronization. | Sparse `{ invoice: 1 }`; `{ shop_id: 1, status: 1, start_at: 1, end_at: 1 }`; `{ member_id: 1, status: 1, start_at: 1, end_at: 1 }`; `{ tool_ids: 1, status: 1, start_at: 1, end_at: 1 }` |
| `shortcodes` | `Shortcode` | Permanent mappings from generated short codes to deep-link target URLs. | Full unique `{ code: 1 }`; full unique `{ target_url: 1 }` |
| `shops` | `Shop` | Shop catalog, reservation rules, communication channels, and resource integrations. | Unique case-insensitive `{ name: 1 }` with `en` strength-2 collation, partial when `name` is a string |
| `slack_identity_conflicts` | `SlackIdentityConflict` | Unresolved and resolved conflicts between Slack identities and member records. | `{ slack_id: 1 }`; `{ member_id: 1 }`; `{ resolved_at: 1 }` |
| `slack_users` | `SlackUser` | Current and historical mappings between members and Slack identities. | Unique `{ member_id: 1 }`, partial for object IDs with `invalidated_at: nil`; unique `{ slack_email: 1 }`, partial for strings with `invalidated_at: nil`; unique `{ slack_id: 1 }`, partial when `slack_id` is a string |
| `system_configs` | `SystemConfig` | Runtime feature flags, settings, and tracked job-run results. | Unique `{ key: 1 }` |
| `tool_checkout_requests` | `ToolCheckoutRequest` | Member requests for a tool or group Safety Checkout and their open/closed/deleted/declined lifecycle, including the decline decision (`decided_by_id`, `decided_at`, `decision_reason`; no `decided_by_id` means the system timed the request out) and and the Slack delivery receipts for Resource Managers channel reminders (`reminders`, `reminder_open`). | `{ member_id: 1, status: 1, request_date: 1, _id: 1 }`; `{ tool_id: 1, status: 1, request_date: 1, _id: 1 }`; `{ tool_group_id: 1, status: 1 }` (all installed by `data:ensure_checkout_indexes`) |
| `tool_checkouts` | `ToolCheckout` | Granted or revoked member Safety Checkouts for tools. | `{ member_id: 1 }` (deployment task) |
| `tools` | `Tool` | Tool catalog, shop ownership, Safety Checkout prerequisites, and reservation rules. | Unique case-insensitive `{ shop_id: 1, name: 1 }` with `en` strength-2 collation, partial when `name` is a string; `{ shop_id: 1, name: 1, _id: 1, disabled: 1 }` with the same collation |
| `volunteer_credits` | `VolunteerCredit` | Volunteer credit awards, approvals, discounts, and reversals. | `{ member_id: 1 }` (also enforced as non-unique by the deployment task); `{ status: 1 }`; `{ created_at: 1 }`; unique `{ tool_checkout_id: 1 }`, partial when `tool_checkout_id` is an object ID |
| `volunteer_events` | `VolunteerEvent` | Volunteer events, attendees, eligibility prerequisites, and open/closed state. | `{ status: 1 }`; `{ status: 1, event_date: 1 }` (deployment task); unique `{ event_number: 1 }`; `{ shop_id: 1 }` |
| `volunteer_tasks` | `VolunteerTask` | Volunteer bounties/tasks, claims, verification, recurrence, and credit values. | `{ status: 1 }`; `{ status: 1, completed_at: 1 }` (deployment task); `{ claimed_by_id: 1 }`; `{ parent_task_id: 1 }`; `{ shop_id: 1 }`; unique `{ task_number: 1 }` |

`EarnedMembership::ReportRequirement` is not listed as a collection because it
is embedded inside `earned_membership__report` documents.

## Volunteer approval reminder receipts

Existing `volunteer_tasks` and `volunteer_events` documents store private
`approval_notification` hashes and `approval_notification_history` arrays;
there is no separate claim or notification collection. The current state stores
wait start (`started_at`), subject, and unique intent `generation_id` before
posting, and adds Slack's message `ts`, returned channel, and `destination_mode` (`production` or `test`)
after a successful acknowledgment. It also stores final `outcome` and `closed_at`.
`finalized: false` marks a closed outcome awaiting final-delivery processing.
Closure fields and this flag are persisted in the same MongoDB write as the
lifecycle transition, using dotted updates that preserve concurrent Slack
receipt fields. Sync finalizes closed snapshots without a posted message;
late receipt registration reopens final delivery. Review clocks use native UTC
timestamps. These fields are not included
in task/event API serialization.

The reminder job posts after more than five days, then updates the saved message
in place. Final outcomes are persisted before their Slack update so future runs
can retry delivery. A closed snapshot without a `ts` does not create a new final
post. For a task that returns to available and is claimed again, the preceding
intent or receipt moves to `approval_notification_history`; a late post receipt
or final update does not overwrite the later claim's state. Conditional writes
retain a competing post's first registered receipt and duplicate messages are
removed best effort. Saved conversation IDs remain tied to their original
production/test destination mode; mismatched-mode updates are refused and
retained for the intended environment.

Changing an open event's date archives its live channel reminder with a
`Rescheduled from ... to ...` outcome, `rescheduled: true`, closure time, and
`finalized: false`; the same guarded MongoDB write saves the new date and clears
`approval_notification`. It appends history rather than replacing it, and
retries if a concurrent post adds its Slack receipt before that write. A
concurrent schedule/status change aborts the reschedule instead of reporting
success. Normal model validation and callbacks still run. The old Slack message
is updated immediately to retire the previous schedule's reminder; failed
delivery remains in the existing history retry scan even when the new date is
in the future or absent. If the new schedule becomes overdue, it creates a fresh
intent, timestamp, and wait clock. Generation IDs distinguish separate intents
even when the date is later changed back to its original value; legacy receipts
without an ID remain supported. A late post attaches to its archived intent and
reopens final delivery, leaving the current schedule's reminder untouched. Date
changes without a channel intent do not create reminder history.

A task approval initially stores `Credit award not confirmed` with the completed
status, then replaces it with an approved outcome after credit creation succeeds
or a `Credit award failed` outcome if creation raises. If that later metadata
write fails, the initial warning remains available for final-message retry and
manual verification. For a posted reminder, a
finalized warning means its Slack update was delivered, not that the credit
problem was resolved. Failed
warning delivery uses the same retry fields; the reminder job does not retry
creating credits. A successful lifecycle write always includes its initial
closure metadata; confirmation of the credit outcome can still fail separately.

Event closure uses the same provisional unconfirmed warning before processing
attendee awards. The final outcome reports any member lookup, credit creation,
award notification, or discount-processing failures with the affected member IDs
and processing stages, counting each affected attendee once. Award notification
failures do not skip discount processing for the saved credit. Deleted or inactive members are skipped. Other attendees
still receive their awards. Event closure requests error propagation from the
credit notification and discount helpers; other callers retain their existing
rescued-error behavior. In propagation mode, event closure owns the single
error report and discount error notice rather than repeating them at each helper
layer. The job retries warning delivery rather than creating
credits again. Failed outcome persistence leaves the unconfirmed warning in place.

Unlinked task destruction runs a model callback before removing its receipts.
It withdraws pending review with cancelled status and a deletion-requested
outcome in one write, closes open historical reminders, and requires successful
final delivery for every known posted message before destruction proceeds.
Slack failures retain the cancelled task and retryable receipt for the daily job;
the authenticated task DELETE endpoint returns structured HTTP 503
(`error: service_unavailable`) rather than an unhandled exception. Successful
deletion still returns 204; deleting a linked bounty remains forbidden with 422.
retry deletion after delivery recovers. Already closed review outcomes remain
unchanged. A reminder worker whose post or update outlives task deletion removes
that message best effort only after confirming the task/event document is absent
on the MongoDB primary. Missing claimant records use `Unknown member` during
subject generation, allowing reminder updates and task deletion even without a
saved subject. Failed existence checks retain the message and report the error.
Cleanup failures are reported. Low-level `delete` and
`delete_all` bypass callbacks; event deletion remains outside this cleanup.

The compound `{ status: 1, completed_at: 1 }` task index supports the
pending-completion scan; `{ status: 1, event_date: 1 }` supports the dated open
event scan. These indexed age scans run separately from final-delivery retries,
whose private receipt predicates have no declared indexes.
The [Procfile release command](../Procfile) runs
`data:ensure_unique_indexes` to install both nonunique reminder indexes on existing
databases. Deployments that bypass that release command must run
`RAILS_ENV=production bundle exec rake data:ensure_unique_indexes` before enabling
the updated reminder job. This step creates only these volunteer lookup indexes;
it does not attempt to install the task/event number unique indexes or require a
number backfill. Repeating it retains compatible indexes. Model declarations
alone do not install indexes on existing collections.
See [the job inventory](jobs-tasks-services.MD#volunteer-approval-reminders) for
age thresholds, channel routing, and recovery behavior.

The proposed shop RM notification rollout adds a separate private
`approver_notifications` hash on those same documents. Task delivery paths are
keyed by completion-submission timestamp and manager ID; event paths are keyed
by scheduled date (`event_YYYYMMDD`) and manager ID. Existing date buckets remain
as notification history. Legacy `event` buckets are atomically renamed to the
existing date on the first scan or before a normal model update reschedules the
event; a missing old date uses `event_undated`. Renames guard the stored date and
refuse collisions with an existing date bucket, preserving both sets of receipts
and blocking that date update on conflict. Deployment must drain or stop workers
using the legacy path before renaming buckets; their in-flight acknowledgments
otherwise target a removed path and can lead to a duplicate on lease recovery.
Each recipient stores `state` (`sending`, `sent`,
`failed`, or `obsolete`), a sending-lease token and `attempted_at`; successful
posts additionally store `ts`, returned channel, `sent_at`, and
`destination_mode`. Failed or stale sending attempts can be retried without
repeating a recipient with a durable successful receipt. If the manager's Slack
identity is unavailable or no longer belongs to them at the post-lease check,
delivery remains `failed` without posting and can retry after relinking. An open
event rescheduled to today or later, or made undated after leasing, also keeps a
`failed` receipt until its scheduled/restored date has passed. Reversible
manager eligibility changes (role/shop removal, suspension/revocation or becoming
the task claimant) and a moved/cleared activity shop also leave `failed` receipts;
they can retry once eligibility is restored for the same pending submission.
Deleted managers, terminal tasks/events, and superseded task submissions become
`obsolete`; successful `sent` receipts remain unchanged by eligibility changes.
A different event date uses a new bucket and can notify the same manager again
after that date passes; returning to a previous date reuses its saved receipts.
An accepted post with
failed receipt persistence keeps its sending lease and reports uncertainty;
lease expiry after that failure or a worker crash can permit a duplicate DM.
These fields remain excluded from
task/event API serialization, require no new collection or index, and do not
replace the five-day escalation receipt/history.

## Keeping indexes in sync

The table describes the indexes expected from model declarations, not a live
database inspection. After changing an index declaration, update this file and
use the repository's Mongoid index deployment process for each environment.

## Repair tickets

- `fix_tickets`: new `_id` values are integers allocated by `Ticket.pull` from the `counter` collection's `tickets` sequence; legacy ObjectIds remain supported. Reporter identity (restricted), report fields, current/submitted priority, status/confirmation, member ObjectId assignments/provenance, visibility, bounty/reward references, revision and business timestamps. Slack root ts/channel/team and delivery_job_id/delivery_job_until (the queued/retrying chain reservation) are operational fields and do not advance updated_at.
- `fix_ticket_events`: append-only redacted-output event history and transactional notification outbox. actor_id and recipients are restricted; field_changes contains publishable changes. Delivery receipts/errors are internal.
- `fix_ticket_reveals`: admin-only privacy access audit; intentionally separate from board-readable audit_logs.

Ticket references in events, reveals, volunteer tasks and credits accept integer
IDs and legacy ObjectIds. `audit_logs.resource_id` likewise preserves integer
IDs for FixTicket records, while other resources retain ObjectIds. API resource
IDs remain strings. Never reset the `tickets` counter against existing tickets.

Existing tools gain out_of_service (false for legacy documents), independent of disabled/Hidden. volunteer_tasks gain optional ticket_id. volunteer_credits gain restricted ticket_id for reporter rewards. members gain an internal fix_ticket_write_revision used to serialize concurrent cap/priority writes. Run `bundle exec rake data:ensure_unique_indexes` before enabling tickets. MongoDB replica-set transactions are required; unsupported deployments fail closed.

FixTicketEvent `note_role` is private submission-time attribution (`reporter`, `assignee`, or absent for legacy/staff notes). It is not exposed as reporter metadata.
