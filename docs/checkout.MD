# Safety checkouts

## Printable Checkout Required sheets

The member portal offers **Checkout Required Sheet** from shop details and tools
on `/workshops`, and selected shops/tools on `/tool-checkouts`. The preview defaults
to two identical signs stacked on an 11 × 8.5 inch landscape US Letter sheet.
**Signs per sheet** can select one centered sign of the same size. Download SVG
saves the exact preview. Print on US Letter, landscape, at 100% / actual size.
The file uses 0.25-inch outer margins (a 10.5 × 8-inch printable area) and a
0.25-inch gap between two signs. Each sign embeds the round red-and-white vector
logo at 2.4 inches and a 2.3-inch QR including its four-module quiet zone, captioned
“Scan QR to” / “Request Checkout”. The shop/tool name is centered at the top and
the parent shop's Slack channel at the bottom, both in regular 26-unit type.
“Operation & Safety” is centered below the name in 36-unit type, above the large
burgundy “Checkout” / “Required” heading. Long names wrap to two centered lines;
unusually long names/channels fit horizontally without truncation.
Missing channels leave the footer blank and produce a warning in the preview.
Tool users/announcement channels are never substituted.

Authenticated `POST /api/shops/:id/checkout_required_sheet` and
`POST /api/tools/:id/checkout_required_sheet` accept an optional JSON `copies`
of 1 or 2 (default 2). Admin/Board may print any eligible resource, RMs only
assigned shops and their tools, and eligible checkout approvers only their
permitted physical tools. Effective shop-wide and materialized group tool grants
apply. Ordinary approvers retain `valid_for_checkout_request?` eligibility.
Hidden resources, tools in hidden shops, and open/no-checkout-required tools
cannot be printed; temporary outages do not block printing. Tool-group sheets
are unsupported. Catalogs expose `canGenerateCheckoutRequiredSheet`; the POST
independently rechecks authority and availability before allocating a short URL.

Success is `200 image/svg+xml`, with attachment filename
`checkout-required-{shop|tool}-{id}.svg`, `Cache-Control: private, no-store`, and
`X-Checkout-Sheet-Warning: missing_shop_channel` when applicable. Normal session,
TOTP and CSRF checks apply. Errors are JSON: 401 authentication/CSRF, 403 scope,
404 missing/hidden resource, 422 invalid copies or open tool, and 503 shortcode
origin/storage failure. After session checks, hidden resources (including tools
in hidden shops) return the same 404 body as missing resources before checking
resource-scoped authority, including for ordinary members. There is no full-URL
fallback. QR destinations reuse
the permanent shortcodes for `/api/shop/:id/public.html` or
`/api/tool/:id/public.html`; scanning grants no additional access.

The service stores only ordinary shortcode mappings; sheets are rendered per
request and are not persisted or publicly cached. No emails, background jobs,
new collections/indexes, or member status changes are introduced. Deploy Rails
before React. Local UI wrappers require no API-client package publication.

Validation: run the sheet service/request/API specs and related catalog specs,
then regenerate Swagger. To produce real renderer fixtures for the companion
browser check, run `bundle exec rails runner scripts/ci/checkout-sheet-fixtures.rb`
with a configured test environment. The script only writes ignored
`tmp/checkout-sheets/` SVG files; it does not allocate shortcodes or change data.

`GET /api/tools` accepts optional `shop_id`. A selected shop narrows the existing
eligible catalog; hidden shops/tools, open tools, held checkouts and pending-member
restrictions still apply. Omitted or blank `shop_id` preserves the all-shops
response. Unknown or unavailable shops return an empty array. The member's
Available Tools shop selector applies this scope to tools and groups together.

## Tool groups

Authenticated `/api/tool_groups` provides catalog, create, show, edit and archive
operations. Admin/Board or the shop RM may manage a group. PUT and DELETE require
the current `revision`; stale revisions return 409. Groups have no public page,
QR code, shortcode, or independent checkout entitlement. All flags default off.

Checkout requests accept exactly one `tool_id` or `tool_group_id`. Existing list
contracts stay tool-only unless `include_groups=true`. Group requests are one
record and use current membership. The group's Requestable flag governs member
requests, independently of manual signoff.
Archiving or destroying a group, including through shop deletion, marks its open
checkout requests `deleted` and open volunteer requests `revoked`. Terminal request
history is retained.
After an included-tool membership edit, the catalog save also closes requests for
that group whose remaining included tools all have active checkouts. It links each
closed request to an existing checkout, creates no checkout or volunteer credit,
and leaves unsatisfied and unrelated requests open. Archival takes precedence over
this reconciliation. Existing Slack posts are updated after commit using the edited
group details and the channel from before the edit.
Group destruction captures the name and announcement channel before removing the
target, then retires each announced open request after destruction. Shop cascades
use this same cleanup; a Slack failure is reported without aborting deletion or
preventing updates to other request posts.

GET `/api/tool_groups/:id/review?member_id=...` returns current membership,
held/new checkout IDs and external prerequisites. POST `:id/approve` accepts
`member_id` and the reviewed `revision`, and returns `checkouts`, `skipped` and
`approvalBatchId`. Individual approvals retain their existing response shape.
Internal prerequisites can be granted together; external prerequisites need
active checkouts. Open tools may receive a group grant. Revoked child records
block the whole group until the member is reinstated on that tool (see
[Reinstating a revoked checkout](#reinstating-a-revoked-checkout)), and fully held groups create neither records nor credit.
When an open request is supplied, the portal offers Resolve request and submits
its ID to reconcile the request even when no new checkouts are needed.

Group approval authority is Admin/Board, shop RM, shop-wide assignment or an
explicit group assignment. Separate tool assignments alone do not qualify.
Group assignments also persist individual grants, including subsequently added
tools. Removing a group assignment retains these grants. Revoking an individual
checkout removes affected group authority. Eligible volunteers must hold every
included checkout; existing shop reviewer permissions apply at decision time.
Direct group assignment also rejects revoked constituent checkouts rather than
restoring the removed authority. Volunteer review and notification dates use the
latest active checkout among all current constituent tools, when all are held.
See [member permissions](member-permissions.md#checkout-approver-assignments) for
scope mutation paths and consumers.

`ToolGroupCheckout` acquires the catalog lock, approver lock and ordered physical
checkout locks, then commits grants, request reconciliation and the group credit
in one MongoDB transaction. Slack delivery follows commit. For Slack-sourced group approvals, all notification
work is queued after commit so the modal can acknowledge without waiting for Slack
API calls; portal approvals keep their existing delivery behavior. An ordinary approver
receives one 0.25 credit for a batch with new checkouts; the first revocation
reverses that shared credit. Groups never retroactively grant previous trainees
newly added tools.
Queued all-held request resolution uses the approval-time group name, constituent
tool names and announcement channel to update the existing Slack message, even
after the group is edited or destroyed. Reconciled requests for other targets
continue using their own announcement details.

Slack `/checkout request <name>` resolves shop-scoped groups as well as tools.
Textual `/checkout MEMBER GROUP` resolves a linked target and opens the signed
review during the command request, without queueing the short-lived trigger.
Unlinked targets receive an instruction to use their Member Portal email.
The signed checkout modal carries the reviewed group revision. Group selectors
follow physical tools and use `:linked_paperclips:` where supported. Group batch
announcements use the group override or shop channel and preserve deduplicated
individual users-channel invitations.
An approval batch reuses a Slack timestamp only from a same-group request that
the current approval reconciled. Batches without such a request send a fresh
group announcement, preserving historical request posts.

## Member Portal lists

“My Active Tool Checkouts” displays an accessible note tooltip beside tools with
nonblank notes. Active checkout holders can see notes for their hidden tools;
revoked checkouts alone do not grant note access.

The roster's “Check Out Member” search sends `fully_active_unexpired=true` to
`GET /api/members`. Mongo filters to `status: activeMember` and an expiration
strictly later than the current Unix time in milliseconds before search paging.
This opt-in filter does not change checkout creation or Slack eligibility.

The Tool Checkouts roster hides checkouts held by expired, revoked, inactive or suspended members by default. It sends `active_members_only=true` to `GET /api/admin/tool_checkouts`, which keeps only members whose status is `activeMember` or `pending` and whose expiration is later than the current Unix time in milliseconds (`Member#active_unexpired?`). A checkbox, “Include expired, revoked and inactive members”, omits the parameter. The parameter is opt-in, so other callers still receive every checkout, and a single member's own checkout list (member profile) never sends it.

Shop, tool, approver, and checkout responses use request-scoped batched lookups.
Shop tool counts and prerequisite labels share a Mongo `$facet` aggregation.
The page shares lazy catalog reads across tabs and refreshes loaded catalogs on
mutations and window focus. Public and management catalogs remain separate.
No persistent cache stores tool notes or authorization decisions.

## Mongo queries and deployment indexes

`CheckoutInteractionQuery` scopes requestable tools in Mongo by `shop_id`,
`disabled != true`, and `open != true`, then orders by `name` and `_id` with
`{ locale: "en", strength: 2 }` collation. Enabled shops use the same
case-insensitive alphabetical ordering. Existing checkout IDs, active
prerequisite checkout IDs, and open-request tool IDs are fetched in bulk and
passed to `ToolCheckoutRequestEligibility`; there is no per-candidate `exists?`
or `pluck`. The policy remains the final validator immediately before insertion.

Open-request queries constrain `status: "open"` and authorized member/tool IDs
in Mongo. Eligible member IDs come from status/expiration filters, without
loading every member. Pending IDs are paired only with tools allowing pending
members. Visible requests are oldest first (`request_date: 1, _id: 1`), with the
ID providing a stable tie-breaker. Bulk checkout data also removes requests with
unmet prerequisites or an existing disqualifying checkout.

Deploy all seven declared nonunique indexes from the application root with:

```sh
RAILS_ENV=production bundle exec rake data:ensure_checkout_indexes
```

| Collection | Index fields, in order (all ascending) |
| --- | --- |
| `members` | `status, expirationTime` |
| `tool_checkouts` | `member_id, revoked_at, tool_id` |
| `checkout_approvers` | `member_id` |
| `tool_checkout_requests` | `member_id, status, request_date, _id` |
| `tool_checkout_requests` | `tool_id, status, request_date, _id` |
| `tool_checkout_requests` | `tool_group_id, status` |
| `tools` | `shop_id, name, _id, disabled, open` (case-insensitive collation) |

The tool index places shop equality and name ordering before availability
inequalities. A test-database explain comparison with 6,000 synthetic tools
returned the same 343 results without a blocking sort for either index; including
`open` reduced fetched documents from 514 to 343, with 601 keys examined in both
plans. This is fixture evidence, not a production workload benchmark.

The deployment task in `lib/tasks/checkout_indexes.rake` is repeatable and uses
model declarations. It never drops indexes or changes documents. A conflict on
a targeted index stops the task for review. Use it instead of global
`db:mongoid:create_indexes`, which may encounter unrelated legacy identity-index
conflicts such as `cards.uid_1`. Existing documents need no migration.

## Slack commands

Command acknowledgements, help, and status lists are visible only to the
caller. The request and approval workflows can additionally send the DMs and
channel announcements described below.

Bare `/checkout` opens the same four-choice menu for members and approvers:
**View my checkouts**, **Request a checkout**, **Volunteer to do checkouts**, and **View open requests**. In a configured
shop channel that shop is fixed for the entire modal session. Elsewhere the
initial view offers enabled shops in case-insensitive alphabetical order; once
chosen, the shop cannot be switched within that session. Close and reopen the
command to choose another shop. Legacy textual approvals still require a shop
channel. An unknown Slack identity is synchronized once before an account-link
message is returned. Expired, revoked, suspended, inactive and otherwise
ineligible members receive distinct membership guidance. Pending members can
enter, but can only interact with tools allowing pending members.

| Command | Behavior |
| --- | --- |
| `/checkout` | Opens the checkout menu and, outside a shop channel, an enabled-shop selector. |
| `/checkout @member tool-name` | An authorized approver checks out the mentioned member on a tool in the current shop channel. An email address may replace the mention. |
| `/checkout request` | In a shop channel, opens a request modal containing only eligible tools without an existing open request. Outside a shop channel, lists all of the caller's open requests across shops. |
| `/checkout request tool-name` | Requests the named tool in the current shop channel after rechecking eligibility. |
| `/checkout active` or `/checkout list` | In a shop channel, lists the caller's available active checkouts using the same alphabetical ordering and detail fields as the modal, without the redundant shop line. Outside a shop channel, behaves like `active all`. |
| `/checkout active all` | Lists available active checkouts across enabled shops using the shared query and detail formatter. Each entry identifies its shop. |
| `/checkout volunteer` | Opens the volunteer flow. A member in good standing may request approver access for any tool on which they have an active checkout. |
| `/checkout help` | Shows the commands available to the linked caller, including textual approval only for callers with approval authority. |

Members with a checkout in the current shop are encouraged to volunteer as
checkout approvers for tools they know well. The request accepts an optional note and asynchronously DMs each RM for
the containing shop with that note, the tool checkout date, and the member's join date and appears ahead of ordinary requests in that shop's **View
open requests** list. An assigned shop RM, or an admin/board member tagged as a contact for that shop, may approve or decline it, with an optional decision note. Approval adds an
individual-tool `CheckoutApprover` assignment. Either decision DMs the requester with the status and RM note. A resource manager (RM) is
implicitly an approver for every tool in each shop they manage. Approval and decline are serialized with the same per-member/tool lock used by checkout mutations, and the request is reloaded under that lock. Concurrent reviewer decisions therefore cannot both apply or leave a declined request with approver access, and checkout revocation uses that same lock so it cannot race a grant.

## Stateful Slack modal

`SlackCheckoutModal` renders callback `checkout_modal`; `SlackCheckoutWorkflow`
handles `block_actions` and `view_submission`. The legacy
`checkout_request_submit` submission callback remains supported separately.

Stable selector block IDs are `checkout_menu`, `checkout_shop`, `checkout_tool`,
`checkout_request`, and `checkout_checkout`; their action IDs append `_select`.
The note input uses `checkout_note` for both IDs. Declining uses a required
input whose block and action ID are both `checkout_reason`. The `checkout_actions` block
contains `checkout_edit_note`, `checkout_cancel_request`,
`checkout_approve_request`, and `checkout_decline_request` buttons when authorized, plus
`checkout_approve_volunteer` for an RM reviewing a volunteer. `checkout_navigation`
contains `checkout_back`.

Private metadata is integrity-protected and expires after one hour. Its payload
contains only `member_id`, optional `shop_id`, the original `response_url`,
`slack_user_id`, `step`, and optional `record_id`. Neither notes nor permission
flags are cached there. Each transition checks the Slack identity against its
current member link, reloads selected records, checks membership and shop/tool
availability, and rechecks ownership or current approval assignments. Option
labels are display-only; notes come exclusively from the note input value.

Open requests combine the member's own eligible requests with this approval scope:

| Acting member | Additional visible requests |
| --- | --- |
| Ordinary member | None |
| Admin or board member | Every eligible request in the selected shop |
| Resource manager | Eligible requests in the selected shop, if they manage it |
| Assigned tool approver | Eligible requests for assigned tools or assigned shops, within the selected shop |

Assignments are additive, but never expose another shop's requests in the current
modal. Expired, inactive, revoked, suspended and otherwise ineligible requesters
are excluded; pending requesters remain only where the tool allows pending.
Lists are oldest first, with `_id` breaking equal request dates.

Only the owner may edit or cancel a request. Owner details show tool, requested
date and note with Edit note, Cancel request and Go back. Notes are limited to
128 characters. Other members' details
include requester and shop and offer only Approve, Decline and Go back. Approval and
cancellation buttons open confirmation views; writes happen on submission.
Request creation, note editing, cancellation and approval share the existing
per-member/tool Redis request lock and revalidate inside it. Successful approval
creates a Slack-signed-off checkout and closes the request synchronously.
`CheckoutNotificationJob` then performs the users-channel invitation, checkout
DM, success announcement and audit logging in the background. Request
announcements (including legacy modal submissions) and cancellation announcement
updates also run in that job. No Slack notification API call runs before the
interaction acknowledgement. Successful writes enqueue final outcome
delivery before returning `response_action: "clear"`, including when enqueueing
fails. Notification failure never undoes a saved request or checkout.

Block navigation uses `views.update` with the incoming view hash. A failed update
is never retried without that hash; the handler attempts a separate explanatory
alert and acknowledges the interaction. Submission note errors stay next to the
note input; stale records and authorization changes replace the view with an
explanation. Navigation reloads records even when going back.

## Request eligibility

A tool can be newly requested only when all of the following are true:

- it requires a checkout (`open != true`) and both the tool and its shop are
  enabled; disabled/hidden/out-of-service resources are unavailable;
- the member is active and unexpired, or is pending and the tool explicitly
  permits pending members;
- every tool ID in `Tool#prerequisite_ids` has a non-revoked checkout for the
  member;
- the member has no checkout record for the target tool, including a revoked
  record (only the admin/board reinstatement path looks past a revoked record;
  see [Reinstating a revoked checkout](#reinstating-a-revoked-checkout)); and
- there is no open checkout request for that member and tool.

A declined request is no longer open, so it does not block a new request for the same
tool; the member may ask again.

The portal, named Slack request job, Slack modal, and Slack modal submission
all use `ToolCheckoutRequestEligibility`. Eligible tools are displayed in
case-insensitive alphabetical order. Submission checks again so changes made
after the modal opened cannot create an invalid request. Slack displays at
most 100 selectable static options; when more than 100 tools are eligible it
directs the member to the portal instead of silently omitting tools.

## Request notifications, decline, and reminders

**Approvers are told, in a roll-up.** A new request is announced in the tool's announce
channel immediately (when `announce` is enabled, unchanged). Approvers are not DMed per
request. Instead, the daily digest run (14:30 UTC, about 10:30 am Eastern) sends each resource manager (for the request's shop)
and each approver assigned to the tool, its shop, or the requested group one Slack DM that
rolls up *every* open request they can act on (the same requests "View open requests" shows: a request from an expired, inactive, revoked or suspended member, or one with unmet prerequisites, is left out), grouped by requester (oldest first) with each
tool, its shop, and the calendar days the request has waited. To avoid flooding people, a
person is messaged at most once a day, and only when there is a new request since their last
digest, or when some open request they can act on is exactly 5, 10, 15, ... days old. Older
requests never trigger a message between those milestones:

```
Open checkout requests (5)

Pat Member
  • Laguna Bandsaw (Woodworking) – 12 days old
  • CNC Plasma Cutter (Metalworking) – 3 days old
Lee Davis
  • Lathe (Metalworking) – 1 day old

use /checkout → View open requests, or use the Member Portal
Already did one in person? Record it (Approve in Slack, or Check Out Member in the portal) so it stops showing up.
```

Someone with nothing new and no 5-day milestone receives nothing. Admin and board members are not included unless they
also hold one of those roles, a requester is never sent their own request, and members without
a linked Slack account or with suppressed direct notifications are skipped. A per-recipient,
per-day Redis key prevents a rerun from sending a second digest. Each new digest is a fresh message (so it notifies), and the recipient's previous digest is edited into a short "Replaced by a newer digest below." stub. There is no email fallback.

**Declining.** Anyone who can approve a request (admin or board member, the shop's resource
manager, or an assigned approver) can decline it from the portal
(`POST /api/admin/tool_checkout_requests/:id/decline` with a required `reason` of at most 255
characters) or from the Slack open-requests modal (**Decline**, with a required reason). The
request becomes `declined`, recording who decided, when, and why. A decline runs under the same
locks as approval and cancellation, so only one can apply. The requester alone receives a Slack
DM with the reason; an existing channel announcement is edited to say the request was declined.
The member may request the same tool again, because only an open request blocks a new one.

**Reminders and automatic time-out.** A request that is still open after 5 days, then again
at 10 and 15 days (three reminders in all), is posted in the Resource Managers channel
(`slack_channel_rm`): "MEMBER requested checkout on TOOL (SHOP) on DATE and is still waiting. If
this was already done in person, please record the checkout so this stops." The third reminder
says it is the last one and gives the date the request will be automatically declined. If no
checkout is recorded 5 days after the third reminder (20 days for a new request), the system
declines the request as `declined` with no deciding member, a reason of "Automatically declined:
timed out with no checkout recorded after N days. Contact the board if you still need this
checkout.", and an audit entry (`tool_checkout_request_timed_out`). The requester, and only the
requester, is DMed: the request was automatically declined because it timed out, and to contact
the board on Slack or visit an open house to see a board member in person, or submit a new
request. The channel announcement and posted reminders are edited to say it timed out. The cap
counts reminders actually posted, so a request that is already old when this ships still gets all
three first. When a request is approved, declined, timed out or cancelled, each posted reminder
is edited to say so. See the checkout request notifications section of `jobs-tasks-services.MD`.

## Checking a member out by fob tap

An approver on a tool's page can check a member out by tapping the member's fob with their
phone. `POST /api/admin/tool_checkouts/lookup_card` (`tool_id` or `tool_group_id`, `uid`) turns the tapped fob into
the member it is assigned to; nothing is created. It is allowed for anyone who can approve
checkouts for that tool (admin or board member, the shop's resource manager, or an approver
assigned to the tool or its shop); everyone else gets 403 and no member data. The existing
`GET /api/admin/cards/lookup`, which returns card-management data, stays admin/board only. A POST
keeps the UID out of request URLs and logs, and the response is `Cache-Control: private, no-store`.

The response is limited to what is needed to confirm the person: member id, name, status,
expiration, whether they can be checked out on this tool (`eligible`) with the reason when not,
and the names of unmet prerequisites. An existing open request does not make a member ineligible.
Rules: exactly one of a tool or a group is given (422); the UID must be uppercase hexadecimal byte
pairs (422); an unknown fob, tool or group, or a card with no member, is 404; duplicate UID records
are 409; and a fob reported lost or stolen is refused (422) without naming the member. For a group,
`eligible` follows the group review (every included tool eligible, prerequisites met, something left
to grant) and the authority rule is the group approval rule. Self-checkout is not blocked: an
approver, such as an RM on a new tool, may need to be checked out themselves.

**Every lookup is audit-logged** (`fob_checkout_lookup`): who looked, the tool or group, the outcome
(`found`, `not_found`, `invalid_uid`, `lost_or_stolen`, `forbidden`, `duplicate_uid`, ...), whether
the member was eligible, and the last four characters of the UID, with no Slack post. Lookups are
deliberately not throttled, since a class of members may need checking out in one sitting.

Each tool in the `GET /api/workshops` response carries `canCheckoutMember`, true when the viewer may
check members out on that tool (the same rule `CheckoutCreation.authorized?` enforces, computed without
a query per tool); the page shows the Check Out Member button only when it is true, and the server
still enforces the rule when the checkout is created.

The approver then presses an explicit confirm button, which posts the checkout through
`POST /api/admin/tool_checkouts` with `source: "fob"` (anything else is recorded as `portal`);
`signed_off_via` shows how the sign-off happened. All the usual checkout rules, locks, Slack
messages, audit entry and volunteer credit apply, and the member's open request for that tool, or
for a group whose tools are now all held, is closed by the checkout itself.

## Checkout approvers

Board members and admins can approve every tool. RMs can approve every tool in
the shops they manage. An additional checkout approver is a member with a
`CheckoutApprover` record assigning one or more complete shops and/or
individual tools; shop and tool assignments are additive. Outside those
assignments, an additional approver has no checkout authority. All creation paths reject disabled tools and shops, ineligible membership, unmet
prerequisites and existing checkout records. Portal, textual Slack approvals and
the modal all use `CheckoutCreation` under the same per-member/tool lock.

When an additional checkout approver completes a checkout, the application
silently creates an auto-approved `0.25` volunteer credit for that approver.
This does not apply when the checkout is completed under admin, board-member,
or RM authority, and it does not send the normal volunteer-credit award DM.
The credit also retains the checkout ID and the checkout retains the credit ID for idempotent recovery and auditing. If the checkout is later
revoked, a silent `-0.25` reversal record offsets that exact credit and the
original credit is marked reversed. If the original credit contributed to a Braintree discount, the normal treasurer review notification is retained even though the member-facing reversal DM remains suppressed.

A member's active checkout list appends `:a:` to tools for which that member is
an additional checkout approver. Tool details state either that the member is
an approver or that an approver volunteer request is pending. Non-reservable
tools omit `Reservable: No`; reservable tools still show `Reservable: Yes`.

Revoking a checkout also removes that member's individual approver assignment
for the tool and marks open volunteer requests for that member/tool as revoked.
Shop-wide assignments are not altered; an otherwise-empty approver record is removed.

## Reinstating a revoked checkout

A revoked `ToolCheckout` blocks the member from every ordinary path: a member
request, an approver signoff, a fob tap and a Slack command are all rejected
with "A checkout record already exists for this tool". Reinstatement is the one
deliberate, audited way past that.

`POST /api/admin/tool_checkouts/:id/reinstate` with a required `reason`
(`ToolCheckoutReinstatement`):

- **Authority**: Admin or Board only, enforced in the controller and again in the
  service. Shop RMs and ordinary approvers receive 403.
- **The revoked record is never changed or deleted.** A new `ToolCheckout` is
  created with `reinstated_from_id` pointing at it, `approved_by` set to the
  reinstating admin/board member, and `signed_off_via` `portal`. Both rows then
  appear in the roster, so revocation history remains visible.
- **Rechecks, under the shared per-member/tool lock and in a transaction**: the
  target must be revoked, its revocation cleanup must have finished, it must not
  already have been reinstated, and `ToolCheckoutRequestEligibility` (with
  `reinstating: true`, which ignores revoked records but still rejects an active
  one) must pass, so the member must still be a current member and the tool
  available with prerequisites met. Failures are 422.
- **Audit**: a `tool_checkout_reinstated` entry records the actor, subject, the
  reinstatement reason, the revoked record's ID and revocation time, and is posted
  to the logs channel. The reason is internal, like the revocation reason.
- **Notifications**: only the member is told, with the normal checkout DM and
  users-channel invitation. No success announcement is posted and the original
  approver is not notified.
- **Approver credit**: the new checkout is a fresh checkout. The standard
  `CheckoutApproverCredit.award!` runs for the reinstating actor, which grants
  nothing to an admin/board/RM (they are not additional approvers). The credit
  reversed at revocation stays reversed. The member's individual approver
  assignment removed at revocation is not restored.
- **Tool groups**: a revoked record superseded by an active one no longer blocks
  group approval, volunteering or approver group assignment
  (`ToolCheckout.blocking_revoked_tool_ids`). Group membership checks reconcile
  against the new active record.

The Tool Checkouts roster shows a Reinstate button on revoked rows to Admin/Board
members.

### Roster notes and the derived Reinstated status

The reinstatement stores `reinstatement_reason`, `reinstated_by_id` and
`reinstated_at` on the **new** checkout (set in the same transaction); the
revoked row is still never edited. The roster has a Notes column showing, per
row, the internal notes the system already holds:

| Row | Notes shown |
| --- | --- |
| Revoked | `revocation_reason`, who revoked it (`revoked_by_id`) and when (`revoked_at`) |
| Reinstated (new active row) | `reinstatement_reason`, who reinstated it and when |
| Ordinary | `request_note`, the note on the open `ToolCheckoutRequest` the checkout fulfilled |

`request_note` is copied at creation from the request the checkout closes (the
named request, else the oldest open one for the member and tool) by every
creation path: portal, Slack and fob sign-offs (`CheckoutCreation`), group
approvals (`ToolGroupCheckout.approve!`, the group request's note, copied onto
each created checkout) and the non-deferred `after_create` request close. It is a
snapshot; later edits to the request do not change it.

**Privacy.** `revocationReason`, `requestNote`, `revokedById/Name`,
`reinstatementReason`, `reinstatedById/Name` and `reinstatedAt` are serialized
only by `ToolCheckoutSerializer` when the viewer is an admin, a board member, a
Resource Manager of the tool's shop, or a checkout approver who can approve that
tool (`CheckoutReadContext#internal_notes_visible?`). They are omitted for the
member the checkout belongs to (My Checkouts, `/api/tool_checkouts`, even when that
member is also an approver) and for every other member. The serializer is the
single gate for all of its endpoints (`/api/tool_checkouts`,
`/api/admin/tool_checkouts` index/create/update/delete/reinstate and group
approval responses).

**Derived `Reinstated` status.** A revoked row whose id is the `reinstated_from_id`
of an *active* checkout is serialized with `reinstated: true` and
`reinstatedByCheckoutId` (the active checkout's id); both are computed, not stored,
and looked up with one query per response (`CheckoutReadContext#load_reinstatements`).
If the replacement is later revoked, the original is no longer reinstated. The
roster shows such a row as a grey **Reinstated** (instead of red Revoked) pointing
at the current checkout, and shows a **Reinstated** badge next to **Active** on
the replacement. `GET /api/admin/tool_checkouts` accepts `reinstated=true` (the
superseded revoked rows and their replacements) and `reinstated=false` (everything
except superseded revoked rows), combinable with `active`; the roster's Status
filter (Active only / Revoked only / Reinstated / All) uses these. When sorted by
member or tool the roster keeps a pair adjacent, replacement first.

## Slack notifications and announcements

### Requests

- Creating a request posts a channel message only when the tool has `announce`
  enabled. It goes to the tool's `announce_channel` when configured, otherwise
  to the shop's `slack_channel`. The message identifies the member, tool, shop,
  and optional request note. This post is immediate.
- The requester receives a DM that the request was created, including the shop's
  "annotation for requestors" when one is set. It is skipped for members without a
  linked Slack account or with suppressed direct notifications.
- Approvers (resource managers for the shop, and approvers assigned to the tool, its
  shop, or the group) are not DMed per request. They receive a roll-up DM of all their
  open requests, sent at most once a day and only when a request is new since their last
  digest or an open request is exactly 5, 10, 15, ... days old. See "Request
  notifications, decline, and reminders" above for the format and rules.
- A request still open after 5 calendar days, and again at 10 and 15 days, is posted in the
  Resource Managers channel (`slack_channel_rm`): "MEMBER requested checkout on TOOL (SHOP) on
  DATE and is still waiting. ..." The third is the last reminder. 5 days later, with nothing
  recorded, the request is automatically declined and the requester is DMed (see "Reminders and
  automatic time-out" above). The posts are edited when the request is approved, declined, timed
  out, or cancelled.
- Declining a request DMs only the requester, with the approver's required reason.
  The decline is also recorded in the audit log (`tool_checkout_request_declined`) and
  posted to the logs channel. The digest and reminder messages are not audit-logged.
- A successful legacy `checkout_request_submit` submission queues a confirmation
  explaining that unpaid volunteers process checkouts and identifying tagged
  resource managers they can contact about becoming an assistant checkout
  approver. It replaces the ephemeral acknowledgement first, with DM fallback;
  delivery failure does not undo the saved request.
- Declining an announced request updates that same channel message to say it was declined.
- Cancelling an announced request updates that same channel message; it does
  not post a second announcement. If approval or cancellation races an in-flight
  request announcement, both senders atomically retain the first recorded Slack
  timestamp. The retained message is updated to the final state, and a redundant
  late post is deleted rather than replacing the stored success timestamp. The submitting owner receives the asynchronous
  final outcome described below, with DM fallback if replacement fails.

- Creating an approver volunteer request DMs every assigned RM for the tool's
  shop, identifying the volunteer, tool, shop, optional note, checkout date, and
  makerspace join date and directing the RM to **View open requests**. Suppressed or unlinked RM notifications are skipped, and a
  delivery failure does not undo the saved request.
- Approving or declining a volunteer request sends the requester a DM with the
  resulting status and the RM's optional decision note.

### Approvals

- A newly checked-out member receives a DM identifying the tool, shop, and
  approver, plus private tool notes when present. Direct notifications are
  suppressed for members whose notification policy disables them.
- If tool announcements are enabled, success is posted to the tool's
  `announce_channel`, falling back to the shop's `slack_channel`. When the
  approval closes an announced request, the existing request message is
  updated where possible.
- If the tool has a `users_channel`, success is also posted there and the
  member is invited to that channel. A failed automatic invitation is called
  out in the success message so it can be completed manually.

### Revocations

- The member whose checkout is revoked receives a DM naming the tool and shop,
  but the internal revocation reason is not included. The member is removed
  from the tool's users channel when one is configured.
- When somebody other than the original approver revokes the checkout, the
  original approver also receives a DM only if they are still authorized for
  that tool as an additional approver, the shop RM, a board member, or an
  admin. The DM identifies the shop, tool, original checkout date, checked-out
  member (Slack mention when available, otherwise full name), and whether the
  revoker acted as an RM, board member, admin, or checkout approver.
- The revoker's name is withheld from an ordinary additional approver or RM.
  It is included only when the original approver receiving the DM is currently
  a board member or admin.
- Checkout creation and revocation also write operational audit messages to
  the configured Slack logs channel.

## Active checkout details and outcome delivery

The modal and `/checkout active` share `listed_active_checkouts` and
`CheckoutDisplay`. The Mongo query requires the caller's member ID, no revocation,
and tools in the chosen shop; available tools are ordered using case-insensitive
collation. Tools and shops are loaded in bulk. Empty lists retain Go back.
Details recheck ownership, shop and current activity before showing tool name,
description, authorized notes, users channel, effective wiki URL, checkout date,
reservability when true, and approver or pending-volunteer status, plus Go back. The date comes from `checked_out_at`. Modal fields are truncated to Block Kit limits; textual
responses escape user-controlled Slack formatting and bound message length.

Final checkout outcomes use the original response URL asynchronously, replacing
the initial slash-command acknowledgement using `replace_original: true`,
`response_type: "ephemeral"`, and the final text. Non-2xx responses and request
exceptions count as replacement failures. Replacement failures fall
back to a DM to the submitting Slack user. Enqueue, replacement and DM failures
are reported without the response URL and never undo persisted requests or
checkouts. Outcome job credentials are encrypted and job argument logging is
disabled. See `docs/jobs-tasks-services.MD` for timeouts and delivery details.

## Annotation for requestors

When the requested tool or tool group has a **Checkout training plan** URL,
the confirmation DM for a new portal or Slack request also tells the member:
"Next step: review the material available in the Checkout training plan."
**Checkout training plan** is a clickable Slack link to that target's URL.
This uses the existing confirmation, independently of channel announcements;
members without a linked Slack identity or with suppressed direct notifications
do not receive a DM. A group uses its own URL, not a constituent tool's URL.

Shops and tools have an optional `requestor_annotation` text field. Blank or
whitespace-only values normalize to nil. Shop managers (plus admins and board
members) edit the shop default. Owning-shop managers and eligible additional
approvers assigned to the tool or shop can edit the tool override through
`PATCH /api/admin/tools/:id/requestor_annotation`; that endpoint cannot change
other tool settings. The portal provides shop form fields and a tool annotation
editor. These annotations are separate from private tool notes and the member's
request note.

After successful submission through the portal or Slack, the linked requestor
receives a confirmation DM with the tool annotation, falling back to the shop
annotation when the tool has none. This is independent of channel announcements.
No annotation section is included when neither is set; members without linked
Slack accounts receive no DM. Slack modal delivery runs in CheckoutNotificationJob.
Existing Slack ephemeral outcome acknowledgements are preserved. Notification
failures do not roll back a saved request.

Request responses expose `requestorAnnotation`, resolved from current tool/shop
settings at read time. The member's My Checkout Requests table displays it in a
keyboard-focusable tooltip. Clearing a tool override restores the shop fallback.

Approver responses include `toolGroups` summaries (`id`, `name`, `shopId`) for
explicit group assignments, batched for overview lists. The portal displays them
in Authorized Groups with Group chips, separately from effective individual grants.
Group checkout requests expose their shop's current `requestorAnnotation`, including
null after instructions are cleared.

Deferred group approval notifications retain the approved group revision, name,
included tool IDs, child details and channels. Catalog edits after approval do not
change the queued audit or message content. Whole-shop selection in the approver
editor clears that shop's explicit tool and group selections; deselecting the shop
does not restore the cleared grants.

Both Slack checkout-request modals defer group announcements and requestor DMs
to `CheckoutNotificationJob` after persistence, matching individual requests.
Slack group edits/cancellations and portal group request mutations take the shop
catalog lock followed by the included member/tool locks, then reload and authorize
the open request. Approval uses the same lock order: a winning cancellation blocks
approval; a completed approval prevents a later cancellation from reporting success.
The create-request API response schema describes tool and group variants, including
nullable `toolId`, `toolGroupId`, `targetType`, `targetName`, `groupRevision` and
`includedToolIds`.

## Member Home recommendations

The authenticated `GET /api/home` endpoint returns up to ten safety checkout
recommendations for the current member only. It reuses
`ToolCheckoutRequestEligibility.eligible_tools`, including pending-member rules,
expiration, all active prerequisites, existing checkout records (including
revoked ones), and open requests. Home additionally excludes out-of-service tools
and tools in out-of-service shops. This extra filter does not change request
eligibility on other surfaces.

Eligible tools named `Orientation` (case-insensitive) sort first; remaining tools
sort by name, with ID breaking ties. Filtering and ordering precede the limit.
Each entry contains `id`, `name`, `shopName`, and `requestorAnnotation`, with the
tool annotation taking precedence over the shop annotation. The portal displays
annotations inline and links to `/tools/:id/request-checkout`. Returning to Home
refreshes the list. Requests still undergo the existing server-side validation.

The same Home response includes `availableVolunteerOpportunities`: up to five
randomly sampled tasks/future events for `activeMember` members, after existing
claim eligibility checks. Child tasks, unavailable/cooling-down tasks, reusable
tasks previously claimed, and in-progress repeatable/recurring claims are omitted.
Events must be open, dated after today, and not already joined. Non-active members
receive an empty list. The portal omits an empty volunteer section; claim/join
buttons use the existing volunteer APIs and refresh Home after success. Reading
Home never claims a task or checks a member in.

The response also includes the existing current-member representation,
fully described by the `HomeMember` OpenAPI schema (including Slack identity,
Mailtrap delivery status, subscription plan, TOTP, household, and address fields), and
a small Slack object (`accepted`, `newMembersChannelUrl`). Acceptance requires a
valid associated Slack ID matching the current email, current-email provisioning
records, a join timestamp, and `slack_acceptance_pending: false`. The HTTPS channel
URL uses the existing workspace ID and `slack_channel_new_members` setting (with
the existing `new_members` default); missing configuration returns null. Home
disables Slack profile URL resolution in member serialization, leaving
`member.slack.url` null when a linked Slack user exists. It uses only the cached
workspace ID for the top-level channel link and never contacts Slack, sends
invitations, or starts provisioning.

Home responses use `Cache-Control: private, no-store` and require authentication
and a completed TOTP challenge. Expected authentication failures render locally
without Redis writes or Slack alert jobs. Missing/expired member sessions and
expired TOTP challenges receive a 401 object with `status`, `error`, and `message`;
a session awaiting TOTP receives `{ "error": "TOTP verification required." }`.
Both bodies are documented by the `HomeUnauthorized` OpenAPI schema and retain
the private/no-store header. See the executable Home API specification and
the [portal Home documentation](../../makerspace-react-2026/docs/member-home.md).

## Training plans, expiration, and renewal

Tools and tool groups have an optional **Checkout Training Plan URL**. Catalog
managers (admins, board members, and the shop's Resource Managers) can set an
absolute HTTP/HTTPS URL; whitespace is trimmed and blank clears it. Requests
show their requested resource's current URL. Checkouts use their tool's current
URL, falling back only to their recorded originating group's current URL. A
deleted group supplies no fallback; current group membership is not inferred.
Portal request forms, pending-request chips, and checkout rows open training
plans in a new browsing context. Slack request and own-checkout modals include
escaped clickable links.

**Checkouts expire after** on tool create/edit accepts Never (the default) or
1–5 calendar years. Approval, group approval, and reinstatement calculate each
tool's date using America/New_York; February 29 clamps to February 28 when
needed. Policy edits affect future approvals only. Missing/null dates never
expire. A checkout remains valid through its displayed date and expires at the
following Eastern midnight.

Member checkout lists offer Active, Expired, and History views. An eligible
member can **Request renewal** for an expired checkout. Approval creates a new
record and atomically links/supersedes the predecessor. Superseded records never
become active through date edits. Revocation is separate: unresolved revocations
still require admin/board reinstatement. Expiration alone does not reverse
volunteer credit, remove Slack memberships, or remove explicit approvers.
Prerequisites, voluntary approver eligibility, private notes granted through a
checkout, active lists, group reconciliation, and canvas generation require a
current non-revoked checkout whose date has not passed. Independent manager or
approver permissions still apply.

Managers can **Edit expiration** on current, non-revoked rows to any date or
Never. Writes carry the displayed expiration revision and return a conflict
when stale. **Set checkout expirations** on a selected tool confirms its name
and current affected count, and accepts only a date later than today. Bulk
changes include expired/undated records but exclude revoked and superseded
history. Both operations use catalog/checkout locks, transactions, and actor +
before/after audit records, without awarding credit. Reassigning the same date
does not restart notices.

### Checkout expiration deployment

Deploy Rails contracts first. Run `bundle exec rake data:ensure_checkout_expiration_indexes`
on the selected deployment database, then deploy the complete React build. The
index task is repeatable and does not backfill expiration dates. Local React
wrappers cover the new contracts; no generated client publication is needed.
Run `bundle exec rake checkout_expiration_notice` manually, or use admin
Jobs → **Checkout Expiration Notices** → **Run Now**. There is no new schedule.
The first warning uses the admin setting (default 14 days, minimum 4); another
is due at 3 days and a final notice after expiration. See [email](email.MD) and
[job operations](jobs-tasks-services.MD).
After scanning notices, the job queues a full checkout roster canvas rebuild for
each shop with newly expired checkouts, including when member notices cannot be
sent. Only successfully published rebuilds are skipped on later runs; failed
enqueues or exhausted canvas retries can be retried by running the notice job
again. Canvas updates run asynchronously. Legacy enqueue-only markers trigger
a fresh rebuild on the next run.

Wiki changes are prepared in [the release patch](wiki-checkout-expiration.patch).
Apply/review against current WikiPages master and publish only after deployment.
The environment-variable inventory is unchanged: no new variables or external
email template dependencies are introduced.

Renewal approval rebuilds the shop checkout canvas to replace a predecessor that
may still be published after expiration. Bulk expiration changes hold one
persistent catalog lock for the transaction; see [lock recovery](jobs-tasks-services.MD#bulk-expiration-locking-and-recovery).
The Reinstated roster filter is offered only on the authorized management roster;
the member endpoint does not support that filter.
