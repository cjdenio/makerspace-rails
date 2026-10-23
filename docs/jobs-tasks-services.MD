# Production jobs, tasks, and services

## Checkout Required sheet services

`CheckoutRequiredSheetsController#create` synchronously authorizes a shop/tool
sheet with `CheckoutRequiredSheetPolicy`, then allocates/reuses its public HTML
shortcode and calls `CheckoutRequiredSheet` to produce an SVG attachment.
The policy is also used by authenticated catalog serializers, with batched shop
and approver lookups for tool lists. The renderer embeds the repository-owned
round red-and-white logo and QR vectors and prints one or two signs on Letter
landscape paper, inside 0.25-inch margins. The 2.4-inch logo and 2.3-inch QR flank
the centered burgundy heading; “Operation & Safety” follows the centered resource
name, with a QR caption and matching-size name/channel labels. The cleaned logo
asset contains only vector geometry; the renderer always generates the QR from
the resource shortcode. See [layout and printing](checkout.MD#printable-checkout-required-sheets).
No Slack API lookup, mail, queue job, persisted sheet, or status mutation occurs.
Shortcode allocation is the sole database/cache write, using its existing
permanent mapping and advisory Redis behavior. Missing channels warn; forbidden,
hidden/open resources and shortcode failures produce no attachment. Responses
are private/no-store. See [contracts and permissions](checkout.MD#printable-checkout-required-sheets).

`bundle exec rails runner scripts/ci/checkout-sheet-fixtures.rb` is a manual
development/test validation helper. It writes ten example SVGs beneath
`tmp/checkout-sheets/` for the companion browser/QR check: `double`, `single`,
`long`, `long-single`, `long-channel`, `long-channel-single`, `unbroken`,
`unbroken-single`, `blank`, and `blank-single` (each with the `.svg` extension).
They use a fixed example short URL and make no database changes. This is not
recurring production work.

## Tool group services

- `CatalogMutationLock` serializes physical-tool and group catalog mutations by
  shop, also coordinating checkout approval and reservation expansion.
- `ToolGroupCatalog` validates revisions, archives requests and extends persistent
  individual approver grants when a group's membership changes. Under the shop
  catalog lock it acquires assigned members' approver locks in sorted order before
  opening the MongoDB transaction, rechecks revoked checkouts, and holds the locks
  through commit so revocation cannot race grant propagation.
  Membership edits also lock open checkout-request holders' approver records to
  coordinate with revocation, then reconcile only that group's newly satisfied
  requests in the same transaction. These closures reuse existing checkouts and
  create no credit. Post-commit delivery uses edited catalog details with the
  pre-edit announcement channel, so a simultaneous channel edit does not move an
  existing message timestamp. Failed or retried transactions do not deliver stale
  notification intents; archival takes precedence over reconciliation.
  Archival and the `ToolGroup` destruction callback share request cleanup: open
  checkout requests become `deleted`, open volunteer requests become `revoked`,
  and terminal history is retained. Shop deletion runs this callback for each group
  before destroying its physical tools. Destruction captures announced open
  requests and their group name/channel before removing the target, then updates
  their Slack posts through `remove_announcement` after group destruction. Slack
  failures are best effort and do not abort deletion or skip subsequent posts.
- `ToolGroupCheckoutNotificationJob` runs on the Slack queue after Slack-sourced
  group approvals commit. It receives committed checkout/request IDs and the batch
  ID plus a catalog snapshot captured inside the approval transaction and catalog
  lock (group name/revision, included IDs, child details and delivery channels).
  Delivery uses that snapshot even after catalog edits; current member DM suppression
  still applies. Older queued five-argument jobs remain supported using their legacy
  current-catalog lookup; drain those jobs before catalog edits during deployment.
  It then delivers audit, deduplicated users-channel invitations, announcements,
  member DMs, canvas scheduling, and reconciled request announcement updates.
  All-held resolutions use the queued snapshot for the approved group's existing
  message, including its channel and group/child names after edits or destruction.
  Other reconciled requests retain their own target's announcement details.
  Batch delivery updates only a same-group request present in that approval's
  reconciled request IDs. It sends a fresh group post when no such request exists;
  older closed requests and their timestamps are never selected from history.
  Both stateful and signed group modals use it. Enqueue errors are reported without
  rolling back approval or falling back to synchronous Slack delivery. Repeated
  approvals with no new checkouts or reconciled requests do not enqueue again.
- `ToolGroupCheckout` reviews and atomically grants physical checkouts, records
  batch provenance, reconciles requests and issues one credit before post-commit
  Slack delivery. `ToolGroupVolunteering` revalidates complete membership at decision.
- `SlackGroupApprovalModal` signs the reviewed group revision and Slack identity
  for manual `/checkout @member group-name` approvals and rechecks both on submit.
- `ReservationGroupExpansion` expands selections and preserves historical snapshots.
- `CheckoutNotificationJob` accepts either request target for request/cancellation
  and volunteer delivery. Both Slack request modals enqueue group request announcements
  and requestor DMs only after persistence, so these sends do not delay acknowledgement.
  `SlackCheckoutRequestJob` resolves tool or group names.
- `data:ensure_unique_indexes` creates group indexes and replaces the open
  volunteer-request unique key with its tool/group-aware version. Run before
  deploying clients that select groups; no checkout backfill task is required.
  Run `data:ensure_checkout_indexes` as well to install the nonunique group-request
  lookup index; the unique-index task does not install `ToolCheckoutRequest` indexes.

## Shop outage announcements

`ShopAvailabilityService` lets admins, board members, and assigned resource managers
mark a shop out of service with a required reason, or restore it. The shared
reservation service blocks new shop and tool bookings during an outage.
`ShopOutageSlackJob` posts the shop name and reason to its configured Slack channel
on the default queue, retrying failures up to five attempts. It stores Slack's
message timestamp in the shop's `ts_oos` field. Each outage has an `outage_id` used
as Slack's stable client message ID; completed deliveries and superseded outages
are skipped. A new outage clears the prior receipt; restoration retains it.
The job also sends each assigned resource manager with a linked Slack account a
direct message containing the actor's name, shop name, and outage note, even when
the shop has no channel. Member IDs and actor name are captured when the flag
is set; suspended/revoked members are excluded. Before each DM, delivery rechecks
the member's current assignment, notification suppression and active Slack link.
It skips outage DMs after restoration or a newer outage. Legacy raw-Slack-ID
recipient lists are not used to send private outage messages. Per-member receipts
prevent completed DMs from being resent on retry.
The same admin/board/assigned-RM authorization applies to restoring service.
Restoration never clears tool flags. It queues a reply to the original `ts_oos`
in the original channel with `reply_broadcast: true`, recording `ts_in_service`.
If restoration precedes root delivery, the delivery job sends the root first,
then the recovery reply. Failed destinations retry independently of successful
deliveries, up to the job's retry limit.
Setting or clearing a shop outage also queues `ReservationSlackCanvasSyncJob`
for today and tomorrow. Both reservation canvases show a prominent shop-outage
banner above the agenda while the flag is set; restoration removes the banner
without removing bookings or tool flags. Scheduled rebuilds include unavailable
shops even when they have no reservations or existing canvases.

Unscoped repair-ticket creation and note events capture an explicit staff-channel
notification intent. `FixTicketDelivery` sends those events to the configured
`slack_channel_rm` (**RM Channel**), defaulting to `resource_managers` when the
setting is absent or blank. The separate **Members Relations Channel** uses
`slack_channel_admin`, defaulting to `members_relations`.
This is independent of the optional central ticket feed and uses the normal
delivery receipts/retry handling. Scoped tickets retain their RM/approver routing.

<!-- markdownlint-disable MD013 -->

This is the production operator's inventory of recurring background work. It
covers every job returned by `GET /api/admin/system_configs` or accepted by
`POST /api/admin/system_configs/run_job`, the recurring work configured in
`config/schedule.rb`, and other Rake tasks whose source says they are intended
to recur in production.

Run commands from the application root with the production environment and
production credentials available. Examples below use:

```sh
RAILS_ENV=production bundle exec rake TASK_NAME
```

`data:ensure_checkout_indexes` is a manual deployment task, not recurring work.
It creates only the nonunique checkout performance indexes on
`members(status, expirationTime)`, `tool_checkouts(member_id, revoked_at, tool_id)`,
`checkout_approvers(member_id)`,
`tool_checkout_requests(member_id, status, request_date, _id)`,
`tool_checkout_requests(tool_id, status, request_date, _id)`,
`tool_checkout_requests(tool_group_id, status)`, and
`tools(shop_id, name, _id, disabled, open)` (case-insensitive collation),
using their model declarations. It can be
rerun and never drops indexes or modifies documents. Unrelated legacy identity
index conflicts do not block it; conflicts on one of its targets are
reported as errors for operator review.

`data:ensure_unique_indexes` runs in the release phase for both buildpack and
container deployments. In addition to the core identity constraints, it installs
the partial unique indexes that permit only one open checkout-approver request
per member/tool and only one volunteer credit per tool checkout, plus the
nonunique reminder indexes on `volunteer_tasks(status, completed_at)` and
`volunteer_events(status, event_date)`. These two indexes are installed from
their individual model declarations; this does not install the unrelated unique
task/event number indexes on legacy data. For an existing deployment that has
not run the updated release task, run
`RAILS_ENV=production bundle exec rake data:ensure_unique_indexes` before relying
on the reminder age indexes. Deployments stop for operator review when existing
duplicate data prevents either constraint from being created.

The Tool index keeps the equality-scoped shop and case-insensitive name ordering
before the availability inequalities. A test-database `executionStats` comparison
with 6,000 synthetic tools across ten shops returned the same 343 tools with both
indexes and no blocking sort. Adding `open` reduced fetched documents from 514
to 343; both plans examined 601 keys. These fixture results justify the additional
availability field, but are not a production workload benchmark.

`SlackCheckoutRequestJob` handles named `/checkout request` commands and
resolves shops from either the Slack channel ID or normalized channel name. It uses
an exact, case-insensitive tool-name match so similarly named tools cannot be
selected ambiguously, then applies the same checkout-request eligibility service
as the Member Portal and Slack
modal, and rechecks tool/shop availability, membership, prerequisites, existing
checkouts, and open requests immediately before creating a request. Creation is
serialized per member and tool so concurrent Slack deliveries cannot announce
duplicate open requests.
`SlackCheckoutMember` resolves linked target members locally by Slack mention,
username, or email. `/checkout MEMBER GROUP` opens its signed review synchronously
in `Slack::CommandsController`, before the trigger expires, with email recovery
for unlinked targets. No modal trigger is passed to `SlackCheckoutJob`.

`SlackCheckoutJob` handles approver-driven physical `/checkout MEMBER TOOL` commands and
resolves the shop from the channel ID or normalized name. It delegates to
`CheckoutCreation`, the same operation as the portal and modal. Authority,
member eligibility, availability, prerequisites, duplicates and selected-request
state are rechecked under the shared per-member/tool lock. `ToolCheckout` closes
the selected request in its callback and retains users-channel invitations;
notifications and audit logging are best effort after creation.

`ToolCheckoutReinstatement` is a synchronous request-time service (no job or task) behind
`POST /api/admin/tool_checkouts/:id/reinstate`. Under the same per-member/tool lock it creates a new
checkout in a transaction, leaving the revoked record unchanged; the member DM, users-channel
invitation, canvas-sync enqueue and `tool_checkout_reinstated` audit entry are best effort afterwards.
See [checkout.MD](checkout.MD#reinstating-a-revoked-checkout).

`SlackCheckoutActiveJob` serves `/checkout active [all]` and its `/checkout list
[all]` alias. In a configured shop channel, the command without `all` lists
that shop and omits the redundant shop-name line. With `all`, or when Slack's
channel cannot be resolved to a shop, it lists checkouts across enabled shops
and includes each shop name.
It uses `CheckoutInteractionQuery.listed_active_checkouts` and `CheckoutDisplay`,
the same availability, alphabetical sorting, bulk association loading and detail
content policy as the modal. Disabled resources and revoked checkouts are
excluded. Long messages direct the user to the portal instead of exceeding Slack
limits. Its result is delivered by `SlackCheckoutOutcomeJob`.

`CheckoutNotificationJob` runs on the `slack` queue for modal mutations. It takes
an action (`request`, `approval`, `cancellation`, `approver_volunteer`, or
`approver_volunteer_decision`) and persisted record ID. Approver-volunteer
actions deliver shop-reviewer DMs and requester decision DMs after Slack has
acknowledged the interaction.
The modal saves the mutation under the existing lock, closes the selected request
for approvals, and enqueues side effects before clearing. Request confirmation DMs
(including the tool requestor annotation or shop fallback, plus a linked
**Checkout training plan** next step when the requested tool/group has a URL), request announcements,
cancellation announcement updates, users-channel invitations, checkout DMs,
success announcements and creation audit logging do not call Slack in the
interaction acknowledgement path. Legacy request-modal submissions also defer
their announcements. Portal and textual-command creation retain their existing
notification behavior through the shared services.

Approval delivery invites the member before building its success announcement,
preserving the manual-invitation fallback text. Each approval side effect is
best effort so one failure does not prevent subsequent notifications or audit.
Deleted records and request announcements whose requests are no longer open are
ignored. After a request announcement returns its Slack timestamp, the sender
atomically records its timestamp only if none exists, then reloads the request.
Approval sends use the same first-timestamp-wins operation. If approval or
cancellation completed during the send, the retained message is updated to the
final status. A sender whose timestamp lost the race deletes its redundant post
after updating the retained message, so a late request cannot overwrite an
existing success timestamp or leave a second success announcement behind.
Slack update/delete failures remain best-effort reported notification failures. Slack calls remain outside the
member/tool mutation lock and the interaction acknowledgement path.
Enqueue errors or aborted enqueues are reported without reversing the
saved mutation. This job is separate from final ephemeral/DM outcome delivery;
a working `slack` queue consumer is required for both.

`SlackCheckoutOutcomeJob` runs on the `slack` queue. Checkout modal submissions
queue it after saving request creation, note editing, cancellation or approval,
and before acknowledging success with `response_action: clear`. Legacy
checkout, request and active-list jobs also delegate final delivery to it. It
first posts `replace_original: true`, `response_type: "ephemeral"`, and final
text to the original slash-command response URL. Open/read/write timeouts are
0.5/1/0.5 seconds. Non-2xx responses, invalid URLs and exceptions trigger a
separate replacement-failure report, followed by a DM to the submitting Slack
user. DM failures are reported separately and never escape back into persistence.
Enqueue failures do not undo saved records or become validation errors.

Outcome URLs are encrypted before job enqueueing using the application key
generator. Argument logging is disabled for all four checkout jobs. Reports
contain fixed messages and error class/status only, never raw exceptions, URLs
or outcome bodies. HTTP logging filters response_url and Slack's JSON payload.
No response-URL HTTP request occurs in the interactions controller.

`ToolCheckoutSlackCanvasSyncJob` incrementally updates an extant shop checkout
canvas when one member's checkout is added or revoked. It locates the affected
Canvas section with `canvases.sections.lookup`, applies the member and last-updated
timestamp changes with `canvases.edit`, and falls back to rebuilding the complete
canvas if an incremental lookup or edit fails. Ambiguous member-section matches
also trigger a rebuild rather than deleting a checkout from the wrong tool, and
incremental additions omit inactive or expired members just as full rebuilds do.
Calls that do not identify one
checkout continue to perform a complete canvas rebuild.
Failure to enqueue an added checkout's canvas update is reported without changing
the saved checkout or its closed request into a failed approval.

After a checkout's `revoked_at` value is first persisted, its model callback
synchronously removes the member's tool-specific checkout-approver access,
revokes open volunteer requests, and reverses any checkout-approver credit before
returning. If cleanup fails, including from contention on the member's approver
record, the revoked checkout retains the durable `revocation_cleanup_pending`
marker that was written in the same database update as `revoked_at`. A subsequent
update retries every idempotent cleanup step and clears the marker only after they
all succeed; the checkout remains revoked throughout so a partial failure cannot
restore tool authority. Credit reversals use an ID derived from the original
credit, preventing a retry after a partial failure from inserting a second
negative credit. A successful resumed cleanup also enqueues the checkout-canvas
removal that the failed callback did not reach. The hourly
`MemberProvisioningReconciliationJob` automatically sweeps pending revocations;
failures are reported and isolated per checkout so later pending records are
still attempted and failed records remain marked for the next sweep.

Changing a tool's out-of-service (`disabled`) state enqueues
`ReservationSlackCanvasSyncJob` for today and/or tomorrow when an active
individual-tool reservation overlaps those dates. This keeps operational
reservation canvases synchronized with tool outages and restorations.

The admin endpoint **enqueues** an Active Job and returns before it completes.
Its `key` parameter is the value in the **Admin key** column below. The
application must have a working Active Job queue consumer for those requests.
The direct Rake commands run synchronously in the invoking process.

Document uploads run asynchronously as `DocumentUploadJob` on the `slack`
queue. Its Active Job lifecycle log suppresses arguments because the first
argument contains the complete base64-encoded signature. A separate safe log
entry identifies the resource, member, and document type. If post-upload Drive
verification fails, the retry log includes the member, resource, expected
filename, and destination folder ID that were used for the unsuccessful
lookup. Before uploading, the job checks for the expected file in the
destination folder. If it is already present (for example, when a successful
upload is retried after delayed Drive search indexing), the job does not upload
a duplicate; it reads that archived file back from Drive for the
signed-document email instead of re-rendering it, so the attachment always
matches the exact bytes on file. This retry check -- and the read-back
download -- both use the Active Job ID stored in the Drive file's application
properties, rather than filename alone, so a contract signed earlier on the
same date cannot be mistaken for the current signing attempt.

Slack reservation submissions and modal closures enqueue
`SlackReservationOutcomeJob` on the `slack` queue before acknowledging the
interaction. The job first replaces the original slash-command response with
an ephemeral outcome, using short HTTP connection/read/write timeouts, and
falls back to a direct message to the submitting Slack user. Its arguments are
suppressed from Active Job lifecycle logs because the response URL is a private,
short-lived Slack credential. Delivery failure never rolls back a reservation.

## Admin-triggerable recurring jobs

`SystemConfig::JOB_KEYS` is the source for the list shown by the admin API. A
job wrapper records `job_status_<admin key>` with a completion time and
`success` or `failure`; direct task behavior differs where noted.

| Admin key | Task displayed by API | Manual command | Purpose and effect |
| --- | --- | --- | --- |
| `slack_sync` | `slack:sync_users` | `RAILS_ENV=production bundle exec rake slack:sync_users` | Reads the Slack workspace user list and creates or updates local `SlackUser` identities by matching email addresses to members. It reports created, updated, and unmatched counts to the logs channel. When `slack_sync_enabled` is true, both the task and job wrapper record status. When it is false, the direct task skips and leaves the previous admin-visible status untouched; the job wrapper records the skipped invocation as a success. |
| `slack_profile_sync` | `slack:sync_profiles` | **No Rake task currently exists.** Use `RAILS_ENV=production bundle exec rails runner 'SlackProfileSyncJob.perform_now'`. | Performs an expiration-only incremental sync. It selects members whose `expirationTime` is after the saved `slack_profile_sync_last_run_at` checkpoint and at or before the run time, randomizes that materialized list to distribute calls across members, then attempts to write `Expired` to their Slack custom-profile field. A Slack 429 response pauses the affected update for its `Retry-After` duration and is retried up to five times. On the first run, the lower bound is the Unix epoch. It does **not** reconcile active members or unrelated member-status changes. `slack_profile_sync_enabled` can skip the work. The API-displayed `slack:sync_profiles` task does not exist. See the partial-success warning below before relying on its count or status. |
| `slack_channel_cache` | `slack:refresh_public_channel_cache` | `RAILS_ENV=production bundle exec rake slack:refresh_public_channel_cache` | Rebuilds Redis lookups for active public Slack channels, atomically promotes the staged cache, removes stale live entries, and stores cache metadata. The task calls the job synchronously, so it records status. |
| `member_review` | `member_review` | `RAILS_ENV=production bundle exec rake member_review` | On Sunday in production, compiles membership exceptions (orientation, no purchase, PayPal, missing contracts, and expired members with rentals), notifies affected members where applicable, queues contract emails, and posts a report to Member Relations. On other production days it exits successfully without a report. Only the job wrapper records status. |
| `invoice_review` | `invoice_review` | `RAILS_ENV=production bundle exec rake invoice_review` | On Sunday in production, reports weekly invoice creation/settlement plus past-due, pending-settlement, and pending-refund cases to the treasurer. On other production days it exits successfully without a report. Only the job wrapper records status. |
| `garbage_collect` | `gc` | `RAILS_ENV=production bundle exec rake gc` | Deletes invoicing Redis cache entries older than 30 days and reports success or failure to the logs channel. This does not invoke Ruby's memory garbage collector. Only the job wrapper records status. |
| `db_backup` | `db:backup` | `RAILS_ENV=production bundle exec rake backup` | Runs `mongodump` against `MLAB_URI`, writes a dated archive below `dump/`, uploads it to the configured Google Drive backup folder, removes the temporary MongoDB config file, and reports to the logs channel. The API-displayed and Whenever-scheduled name `db:backup` does not currently exist; the working task is `backup`. Only the job wrapper records status. |
| `card_expiration_check` | `card_on_file_expiration_check` | `RAILS_ENV=production bundle exec rake card_on_file_expiration_check` | Finds active subscribers whose Braintree cards expire in the current Eastern-time month, caches the affected count and card types in Redis until next month, DMs members who have Slack identities, and reports every affected member to Member Relations. Only the job wrapper records status. |
| `reservation_canvas_rebuild` | `reservations:rebuild_slack_canvases` | `RAILS_ENV=production bundle exec rake reservations:rebuild_slack_canvases` | Processes every shop, but rebuilds today's and tomorrow's reservation canvases only when the shop already has either canvas or has a blocking reservation/blackout in that two-day window. Thus it does not provision empty reservation canvases for an inactive shop. It creates a missing daily canvas when the shop qualifies, refreshes agendas and owner access, and stores its ID. Slack does not attach a newly created canvas to the shop channel header; after its first build, a channel manager must manually attach each daily canvas to its respective shop channel with Slack's **+** button. For every shop, including shops skipped by the reservation path, the command calls volunteer-canvas synchronization with `create_if_needed: true` and owner-access synchronization. That call still leaves a shop unchanged when it has no Slack channel (or the channel cannot be resolved), and it creates a missing volunteer canvas only when the shop has at least one claimable top-level task or active event dated today or later. The command also rebuilds every recorded checkout canvas; it warns the interface-log Slack channel and writes an audit entry for a failed checkout canvas before continuing to the next shop. It retries reservation Slack rate limits and fails after collecting reservation/volunteer failures. Only the job wrapper records status. |
| `membership_expiration_notice` | `membership_expiration_notice` | **No Rake task currently exists.** Use `RAILS_ENV=production bundle exec rails runner 'MembershipExpirationNoticeJob.perform_now'`. | Finds active, non-landlord members with no Braintree subscription (`subscription` not true and `subscription_id` blank) and no active Earned Membership whose `expirationTime` falls exactly 3 days out, and emails each a renewal reminder; separately finds the same population whose `expirationTime` fell exactly 1 day ago and emails an expired notice. Each email is sent at most once per expiration -- the sent state is keyed to the exact `expirationTime` value, so it resets automatically once the member renews to a new date. Only the job wrapper records status. |
| `volunteer_event_reminder` | `volunteer_event_reminder` | **No Rake task currently exists.** Use `RAILS_ENV=production bundle exec rails runner 'VolunteerEventReminderJob.perform_now'`. | Sends/retries assigned shop RM review DMs for submitted tasks and dated open events ready for closure; posts or updates Members Relations Channel reminders after more than five days and retries saved final-outcome updates. See the volunteer approval reminder workflow below. Individual delivery failures do not fail the complete scan. |
| `checkout_request_reminder` | `checkout_request_reminder` | **No Rake task currently exists.** Use `RAILS_ENV=production bundle exec rails runner 'CheckoutRequestReminderJob.perform_now'`. | Posts a "still waiting" reminder in the configured Resource Managers Slack channel (`slack_channel_rm`, default `resource_managers`) for every open checkout request that has been open for 5 days, then again at 10 and 15 days (three reminders in all, the third being the last); declines (as a system decision, audit-logged and DMed to the requester) a request still unrecorded 5 days after the third reminder; edits each posted reminder when its request is approved, declined, timed out or cancelled and retries any resolution edit that failed. Each reminder is recorded on the request, so a reminder is never posted twice. Individual failures are reported without stopping the scan. See the checkout request notifications section below. |
| `checkout_request_digest` | `checkout_request_digest` | **No Rake task currently exists.** Use `RAILS_ENV=production bundle exec rails runner 'CheckoutRequestDigestJob.perform_now'`. | Sends each resource manager and assigned approver one Slack DM rolling up every open checkout request they can act on, grouped by requester with each tool, its shop, and its age in calendar days. A recipient is messaged only when there is a request new since their last digest, or an open request that is exactly 5, 10, 15, ... days old, and at most once a day; nothing is sent otherwise. Not sent to a requester about their own request, or to members without a linked Slack account or with suppressed notifications. Redis keys (`checkout_request_digest:MEMBER_ID:DATE`, `checkout_request_digest_last:MEMBER_ID`) prevent duplicates and track the last digest, and `checkout_request_digest_message:MEMBER_ID` remembers the last digest's Slack message so the next digest can edit it into a "replaced" stub; the daily key is released after a failed send. Individual failures are reported without stopping the run. |

### Triggering through the admin API

An authenticated admin can enqueue one of the keys above:

```sh
curl -X POST "$APP_URL/api/admin/system_configs/run_job" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TOKEN" \
  --data '{"key":"member_review"}'
```

The `200` response means the job was enqueued, not that its effects completed.
Inspect the corresponding job status returned by `GET
/api/admin/system_configs` and the application/error-reporting logs.

## Inert Whenever schedule template

`config/schedule.rb` is only a template of intended schedules. The reviewed
production setup does not include the Whenever gem in `Gemfile` or
`Gemfile.lock`, and neither `Procfile` nor `heroku.yml` installs or consumes the
file. Consequently, `whenever --update-crontab` is unavailable in the deployed
bundle and **none of the entries below is activated by this repository**.

Operators must translate each desired entry into an external platform scheduler
or first add and configure a scheduling mechanism. Times below are template
values and would use the chosen scheduler's timezone.

| Template frequency | Template expression | Manual equivalent | Purpose and effect |
| --- | --- | --- | --- |
| Daily at 02:00 | Rake `db:backup` | `RAILS_ENV=production bundle exec rake backup` | Intended to perform the database backup described above. **The configured task name is currently invalid**, because only `backup` is defined. |
| Daily at 07:00 | `SlackProfileSyncJob.perform_later` | `RAILS_ENV=production bundle exec rails runner 'SlackProfileSyncJob.perform_now'` | Performs the Slack profile synchronization described above. The scheduled form enqueues it. |
| Monthly at 03:15 | Rake `slack:refresh_public_channel_cache` | `RAILS_ENV=production bundle exec rake slack:refresh_public_channel_cache` | Refreshes the public-channel Redis cache described above. Whenever's `1.month` interval is translated by Whenever; verify the generated crontab when deploying. |
| Hourly | `MemberProvisioningReconciliationJob.perform_now` | `RAILS_ENV=production bundle exec rails runner 'MemberProvisioningReconciliationJob.perform_now'` | First retries durable pending checkout-revocation cleanup, isolating and reporting failures per checkout, then reconciles initialized members with live Slack state, promotes eligible Slack guests, and periodically revalidates/provisions Google Drive access when Drive invitations are enabled. Provisioning errors are isolated per member and reported without aborting the complete scan. |
| At 08:00 on the first of each month | `CardExpirationCheckJob.perform_later` | `RAILS_ENV=production bundle exec rake card_on_file_expiration_check` | Runs the monthly card-expiration workflow described above. The Rake command performs the service but does not update the admin job status. |
| Daily at 08:00 | `VolunteerEventReminderJob.perform_later` | `RAILS_ENV=production bundle exec rails runner 'VolunteerEventReminderJob.perform_now'` | Sends/retries assigned shop RM review DMs for submitted tasks and dated open events ready for closure, then posts or updates Members Relations Channel reminders after more than five days and retries saved final-outcome updates. The job records success after the scan completes even if individual Slack deliveries fail; inspect error reporting to confirm delivery. Also exposed as `volunteer_event_reminder` in the admin jobs list. |
| Daily at 09:00 | `MembershipExpirationNoticeJob.perform_later` | `RAILS_ENV=production bundle exec rails runner 'MembershipExpirationNoticeJob.perform_now'` | Runs the membership-expiration-notice workflow described above. |
| Daily at 12:30 UTC | `CheckoutRequestReminderJob.perform_later` | `RAILS_ENV=production bundle exec rails runner 'CheckoutRequestReminderJob.perform_now'` | Runs the checkout-request reminder scan described above. Also exposed as `checkout_request_reminder` in the admin jobs list. |
| Daily at 14:30 UTC | `CheckoutRequestDigestJob.perform_later` | `RAILS_ENV=production bundle exec rails runner 'CheckoutRequestDigestJob.perform_now'` | Sends the checkout-request approver digests described above. Also exposed as `checkout_request_digest` in the admin jobs list. |

## Recurring production Rake tasks not installed by Whenever

These tasks describe recurring production use in their source, but this
repository's Whenever schedule does not invoke them. Configure them in the
deployment scheduler only after choosing appropriate times and considering the
side effects.

| Task | Manual command | Intended cadence, purpose, and effect |
| --- | --- | --- |
| `member_review` | `RAILS_ENV=production bundle exec rake member_review` | Intended weekly. Its built-in production Sunday guard makes other days a no-op. See the admin-job table for notifications and effects. |
| `invoice_review` | `RAILS_ENV=production bundle exec rake invoice_review` | Intended weekly. Its built-in production Sunday guard makes other days a no-op. See the admin-job table for report effects. |
| `volunteering:update_activity` | `RAILS_ENV=production bundle exec rake volunteering:update_activity` | Intended daily. Stores a `MembershipSnapshot` containing IDs of currently active members and reports the count to the logs Slack channel. Re-running on the same date creates another snapshot unless database constraints prevent it. |
| `volunteering:evaluate_requirements` | `RAILS_ENV=production bundle exec rake volunteering:evaluate_requirements` | Intended on the last day of each month and is a no-op on other production dates. Members appearing in more than 21 snapshots for the month have their requirement count updated in the volunteer Google Sheet, with a ten-second pause per member, followed by a Slack completion message. |
| `volunteering:evaluate_eligibility` | `RAILS_ENV=production bundle exec rake volunteering:evaluate_eligibility` | Intended daily. It visits every current and former local member. When a member is absent from the volunteer Google Sheet, it first appends a row containing the member ID, name, start date, completion-count formula, and `N/A` for dates before eligibility; a run can therefore populate the sheet with rows for every missing local member. It then fills only blank volunteer-date cells with `-` when a matching membership snapshot says the member was active or `N/A` otherwise. Existing populated cells, including existing `-` and `N/A` values, are unchanged, so the task will not repair an incorrect populated value. The service sleeps for one second and the Rake loop sleeps for another second per member; adding a missing row introduces another one-second sleep. Allow at least two seconds per existing member, at least three per missing member, and Google API time. It reports completion to the logs channel. |

`RentalVacatingCheckJob` also says it should run nightly, but it has no Rake
task and no entry in `config/schedule.rb`. If production policy requires it,
invoke it with `RAILS_ENV=production bundle exec rails runner
'RentalVacatingCheckJob.perform_now'`. It changes expired `vacating` rentals to
`cancelled`, DMs the member, posts the cancellation notice to the Member
Relations channel, and queues an ended-rental email. It rescues errors per
rental, so a run can finish even when some rentals were not changed.

## Supporting services

Repair ticket delivery jobs accept integer sequence IDs (including their string
form in queued arguments) and legacy ObjectId ticket IDs. Their persisted queue
reservation and recovery behavior is unchanged.
Delivery skips members whose direct notifications are suppressed before Slack
lookup, preserving progress past revoked or suspended recipients.

`ReservationSlackCanvasMemberAccessJob` synchronizes a member's current Slack
canvas access for the supplied shops. Member edits enqueue it when RM shop
access changes. Shop-side RM assignment edits also enqueue it once per added
or removed member, after saving all assignment changes, for that shop only.
Each enqueue failure is logged and does not interrupt the remaining enqueues
or turn the completed shop save into a failed request. Unchanged or omitted
assignments do not enqueue access synchronization.

Recurring jobs should normally be invoked through their job or Rake entry
point, because wrappers provide status tracking and error reporting. The table
below identifies the service that performs each recurring workflow and gives a
synchronous diagnostic invocation where one is useful.

| Service | Manual invocation | Purpose and effect |
| --- | --- | --- |
| `Service::SlackUserSync.sync_all` | `RAILS_ENV=production bundle exec rails runner 'pp Service::SlackUserSync.sync_all'` | Implements bulk Slack identity synchronization. It observes `slack_sync_enabled`; use the Rake task for normal operations and Slack reporting. |
| `Service::SlackProfileSync.sync_all` | `RAILS_ENV=production bundle exec rails runner 'pp Service::SlackProfileSync.sync_all'` | Performs the checkpointed expiration-only Slack profile update described above and observes `slack_profile_sync_enabled`. Eligible members are materialized and shuffled before updates begin, and each profile update honors Slack's `Retry-After` delay for rate-limit responses, retrying up to five times. It is not a full profile-status reconciliation, and its returned count includes selected members whose Slack update failed after retries. This is currently the only direct implementation behind the admin profile-sync job. |
| `Service::SlackChannelCache.rebuild!` | `RAILS_ENV=production bundle exec rails runner 'pp Service::SlackChannelCache.rebuild!'` | Rebuilds and swaps the Redis public-channel cache. Prefer the Rake task, which also records admin-visible status through its job. |
| `Service::MemberProvisioning.reconcile_all!` | `RAILS_ENV=production bundle exec rails runner 'Service::MemberProvisioning.reconcile_all!'` | Implements hourly Slack/Drive reconciliation. It can change remote Slack membership and Google Drive permissions; it is not a read-only audit. |
| `Service::CardExpirationCheck.run!` | `RAILS_ENV=production bundle exec rails runner 'pp Service::CardExpirationCheck.run!'` | Performs the Braintree query, Redis cache update, member DMs, and Member Relations notifications. Prefer the job if admin-visible status is required. |
| `Service::ReservationSlackCanvas.rebuild_all!` | `RAILS_ENV=production bundle exec rails runner 'Service::ReservationSlackCanvas.rebuild_all!'` | Rebuilds the two rolling reservation canvases only for shops with an existing daily canvas or relevant blocking reservation/blackout; it does not create empty canvases for other shops. It calls volunteer-canvas synchronization for every shop, but a shop needs a resolvable Slack channel, and a missing volunteer canvas is created only when a claimable top-level task or current/future active event exists. Newly created reservation canvases require manual attachment to their Slack shop-channel headers. Prefer the Rake task or job for the normal operational path. |
| `Service::GoogleDrive.upload_backup` | Do not call alone; use `RAILS_ENV=production bundle exec rake backup`. | Uploads the archive created by the backup task to Google Drive. Calling it directly requires an existing archive filename and does not create a database dump. |
| `Service::MembershipExpirationNotice.run!` | `RAILS_ENV=production bundle exec rails runner 'pp Service::MembershipExpirationNotice.run!'` | Performs the daily membership-expiration-notice scan and email sends described above. Outside production, it logs each candidate date window and the comma-delimited names (or `nil`) in the expiring-soon and expired lists. Prefer the job if admin-visible status is required. |
| `Service::VolunteerApprovalReminder` | Use `RAILS_ENV=production bundle exec rails runner 'VolunteerEventReminderJob.perform_now'`. | Owns pending-approval Slack message content, saved delivery receipts, in-place age updates, final-outcome updates, retirement of rescheduled event reminders, and recovery of failed final updates. Task/event lifecycle methods invoke it after approval, rejection, event closure, or rescheduling; use the job for recurring scans and status tracking. |
| `VolunteerApproverNotification` | Use the task completion flow or `RAILS_ENV=production bundle exec rails runner 'VolunteerEventReminderJob.perform_now'`. | Delivers one review DM per shop resource manager per task completion submission, or per scheduled event date ready for closure. Stores per-recipient delivery state and retries failed/stale attempts. Direct links select the task claim or event on the authenticated React Volunteer page. |
| `CheckoutRequestDigest` | `RAILS_ENV=production bundle exec rails runner 'CheckoutRequestDigestJob.perform_now'` | Builds each approver's daily digest (recipients: the shop's resource managers and approvers assigned to the tool, shop, or group) and sends it with a per-recipient, per-day Redis key. |
| `HouseholdSetupReminder.notify(member, trigger:)` | Request-time only; no manual command. Called from `Card#perform_assignment_effects!` (key fob registered, `trigger: :fob`) and `Admin::MembersController#update` when an admin renews a membership (`trigger: :renewal`). | Queues one Slack message to the members relations channel when `Member#household_setup_needed?` is true: the member is active or pending, not expired, not in a household (`household_role` is empty, so legacy `groupName` labels do not count), and their most recent member invoice is on a household plan (plan id contains `household`, the same test `Admin::GroupsController#create` requires). The message tells staff to open the profile, choose Create Household, then Manage Household > Add Secondary Member. It never raises; failures are logged and the triggering fob or renewal still succeeds. The same rule is exposed to admins and board as `householdSetupNeeded` on the member profile payload, which drives the profile banner and toast. No status, schedule, or stored state; the message is queued through the existing Slack queue keyed by request id, member and trigger. |
| `FobIssuanceNotifier.notify(member, issuer)` | Request-time only; no manual command. Called by `FobIssuanceController#create` after a fob issuer (a volunteer with the fob-issuer checkout) issues a member's first key fob. | Queues a Slack direct message to the member (only when a `SlackUser` is linked) and a note to the members relations channel, each keyed by request id and member. It never raises; failures are logged and the issued card stands. No status, schedule, or stored state. |
| `CheckoutRequestDecision` | Called by `POST /api/admin/tool_checkout_requests/:id/decline` and the Slack decline action. | Declines an open request under the approval/cancellation locks with a required reason, then queues the requester DM. |
| `CheckoutRequestReminder` | Use `RAILS_ENV=production bundle exec rails runner 'CheckoutRequestReminderJob.perform_now'`. | Owns the five-day reminder message, its per-reminder receipts, and the resolution edit. |
| `MobileSessionClient` and mobile session persistence support | Invoked synchronously by password/provider login, TOTP completion/enrollment, and Devise/Warden remember-cookie hooks; no manual job or Rake command. | Classifies phone clients and gates persistent authentication. See [Mobile session persistence](#mobile-session-persistence) for lifecycle, side effects, and failure behavior. |

### Mobile session persistence

[`MobileSessionClient.phone?`](../lib/mobile_session_client.rb) is the shared
server-side phone classifier. It accepts iPhone or Android-with-Mobile user
agents and rejects iPad/Tablet identifiers, desktops, and missing or unknown
agents. It reads only the supplied user-agent string and has no storage or
network side effects. Classification is not hardware attestation.

[`mobile_rememberable.rb`](../config/initializers/mobile_rememberable.rb) installs
Devise/Warden hooks at boot. During requests they use the classifier to gate
remember-cookie issuance, authentication through that cookie, and its idle-timeout
exemption. The logout hook clears pending persistence. Unsupported clients retain
ordinary session behavior; copying a phone cookie to a desktop does not enable
remember-cookie restoration or its timeout exemption.

[`MobileSessionPersistence`](../app/controllers/concerns/mobile_session_persistence.rb)
coordinates password and Firebase login with TOTP challenge/enrollment completion.
It suppresses Devise's initial remember flag, then, after successful authentication
and CSRF checks, clears the current browser's old remember cookie and replaces
the pending choice. Phone opt-in stores the member ID, authentication salt, and
ten-minute expiry in the encrypted session. Completion consumes that state and
issues persistence only for the matching, still-eligible member after any required
TOTP step. Successful opt-out clears an earlier pending opt-in. Failed credential
retries preserve the original pending choice and expiry and any existing remember
cookie; invalid TOTP codes do not grant persistence. Missing, expired, mismatched,
or salt-invalid pending state grants no remember cookie. Logout and expired
challenges clear pending state through the authentication controllers/hooks.

Devise writes signed, HttpOnly remember cookies and uses the existing member
`remember_created_at` field. The configured two-week window renews on successful
remember-cookie restoration. Password changes/resets and `session_token` rotation
invalidate remembered credentials; logout retains the existing global invalidation
policy. This support has no scheduled work, admin job status, external integration,
or background retry. Unexpected errors follow the enclosing authentication
controller's error handling. No new environment variables, collections, indexes,
or backfills are required. See [authentication](authentication.md) for endpoint
contracts and [member field lifecycle](mongodb-collections.MD) for persistence.

### Checkout request notifications

Approvers are told about open checkout requests by a roll-up DM, not per request.
`CheckoutRequestDigestJob` runs daily at 14:30 UTC (about 10:30 am Eastern) and as the `checkout_request_digest` admin job.
`CheckoutRequestDigest` rolls up (leaving out requests the approver could not act on, such as one from an expired member or with unmet prerequisites), for each resource manager assigned to a request's shop and
each approver assigned to the tool, its shop, or the requested group (not every admin or board
member, and never the requester), every open request they can act on, grouped by requester with
the tool, shop and age in calendar days. It sends only when a request is new since that
person's last digest, or when some open request is exactly 5, 10, 15, ... days old, and at
most once a day. Recipients with no linked Slack account or suppressed direct notifications
(`revoked` or `suspended`) receive nothing. The new digest is always a fresh message (Slack does not notify on edits); the recipient's previous digest, tracked by a Redis key holding its channel and `ts` (30-day expiry), is then edited into a "Replaced by a newer digest below." stub, best effort. Redis keys per recipient track the day's send
(36-hour expiry) and the time of the last digest (90-day expiry). There is no email fallback.
The tool's announce-channel post for a new request is unchanged and immediate.

`CheckoutRequestReminderJob` runs daily at 12:30 UTC (about 8:30 am Eastern) and as the
`checkout_request_reminder` admin job. A request open for 5 calendar days gets a message in the
Resource Managers channel (`slack_channel_rm`): "MEMBER requested checkout on TOOL (SHOP) on DATE
and is still waiting. If this was already done in person, please record the checkout so this
stops." It is reminded again at 10 and 15 days; the third reminder says it is the last and gives
the automatic decline date, and no fourth is posted. Receipts are kept in the request's
`reminders` hash keyed by reminder number; `reminder_open` marks a request whose posted reminders
still need their resolution edit.

The same run declines (`CheckoutRequestDecision.time_out!`) any open request that has had all
three reminders posted and whose last reminder is at least 5 calendar days old, counting
reminders actually posted so an already-old request still gets all three first. The request
becomes `declined` with no `decided_by_id`, the audit log records `tool_checkout_request_timed_out`,
and `CheckoutNotificationJob` (`decline` action) DMs the requester and edits the announcement. When the
request is approved, declined, timed out or cancelled, each posted reminder is edited to say so
(immediately for a decline, timeout or cancellation or when the approval's notifications run,
otherwise by the next daily scan).

### Volunteer approval reminders

`VolunteerEventReminderJob` keeps its daily 08:00 schedule template and
`volunteer_event_reminder` admin key. It now considers submitted task completions
whose `pending` state has lasted **more than five elapsed days** from
`completed_at`, and open dated events whose `event_date` is **more than five
calendar days** before today. A task still being worked on (`claimed`) is not
awaiting approval; an undated event has no date from which to age a reminder.
There is one event reminder for the event, regardless of attendee count.

Overdue tasks and events use separate status/date queries supported by the
compound indexes installed by `data:ensure_unique_indexes` during release.
Saved final-delivery retries run in separate queries for current and archived
receipts, without a pending/open status restriction. Those receipt queries can
still scan a collection; their unindexed predicates are never combined with the
overdue range query. Retry processing only synchronizes closed messages, so an
overdue record also selected for retry does not receive a second pending-age
refresh.

The proposed shop-reviewer notification rollout requires deploying the Rails
changes that provide `VolunteerApproverNotification` together with React's
`/volunteer?task=:id` and `/volunteer?event=:id` selection handling. The preceding
Rails revision `5789f76b051490c20ad283771b115048ba727662` includes the five-day
reminder workflow but not these reviewer DMs or the renamed channel defaults.

Task completion submission invokes `VolunteerApproverNotification` immediately
in both portal and Slack flows. The daily job retries all shop-assigned pending
submissions, and sends/retries event DMs once an open dated event's date is
before today in the application time zone. This event DM is independent of the
five-day escalation threshold. Recipients have role `resource_manager`, an
assignment to that shop, and a current non-invalidated linked Slack identity;
the task claimant is excluded. Events without a shop/date and tasks without a
shop send no RM review DMs. Membership expiration is not an additional DM
eligibility filter. Managers whose direct notifications are suppressed
(`revoked` or `suspended`) are skipped both before taking a delivery lease and
when eligibility is rechecked before sending.

Each recipient is tracked in the task/event's private `approver_notifications`
hash, keyed by task submission time or scheduled event date and manager ID. A successful Slack
post stores its `ts`, returned channel, destination mode, and sent time. A
five-minute tokenized sending lease prevents concurrent attempts from sending
the same manager again; failed attempts and expired sending leases are retried
by later runs, while `sent` receipts are not repeated. Before sending, delivery
reloads both the activity and the recipient, then rechecks the same submission,
current resource-manager role, shop assignment, and manager notification
suppression. Deleted managers, terminal tasks/events, and superseded task
submissions have their attempts marked `obsolete` without a DM. Temporary
suspension/revocation, removal of the manager's role or shop assignment, a
changed/missing activity shop, or the manager becoming the task claimant leaves
the receipt `failed` without posting. Later scans skip ineligible recipients;
when eligibility is restored while that submission still awaits review, the
same receipt can be retried without repeating successful recipients. If an open
event is rescheduled to today or a future date, or loses its date after leasing, delivery
sends no DM and leaves the receipt `failed` for retry. Later scans wait until
the scheduled date is before today; a restored date uses the same rule. A closed
event remains obsolete. Event buckets use `event_YYYYMMDD` keys: a successful
`sent` receipt suppresses repeats only for that scheduled date. Rescheduling
through the normal event update creates a separate review cycle; after the new
date passes, eligible managers receive a fresh DM. Old date buckets remain for
audit, and restoring a previously notified date reuses its successful receipts.
Pre-versioning `event` buckets are atomically renamed to the existing date on
the first scan or before a model update changes the date, preserving successful
notices and active delivery leases. Missing old dates use `event_undated`.
The rename checks the stored date and refuses to overwrite an existing date
bucket; a conflict is reported and blocks that date update rather than losing
either set of receipts. Before deploying date-versioned notifications, drain
or stop workers running the preceding implementation. An old worker still
sending through the legacy `event` path cannot save its acknowledgment after
that bucket is renamed, and lease recovery could then repeat the DM. Workers
using date keys can finish their original schedule's delivery normally.
Delivery also queries the manager's active `SlackUser`
again after acquiring the lease and verifies its ownership, active state, and
nonblank Slack ID. A replacement identity found then receives the DM. If the
link has disappeared, been invalidated or reassigned, or lost its Slack ID,
the attempt sends no message and remains `failed` so a later scan can retry
after relinking. Managers missing a Slack link before leasing are skipped.
Individual errors are reported without aborting the remaining recipients.

An accepted Slack post whose receipt cannot be saved is reported as uncertain
delivery and retains its sending lease rather than immediately reposting.
If that lease later expires, or a worker crashes between Slack acceptance and
receipt persistence, recovery can send a duplicate DM. Successful durable
receipts prevent repeats during normal scans; this is not an absolute
exactly-once guarantee across remote-post/database failures.

The DM contains the activity/claimant summary and an absolute review link built
by `ShortUrl.base_url` from `APP_DOMAIN`. The link selects the exact child claim
when applicable; it does not grant review authority or bypass login. This
background path has no validated-request-host fallback: missing/invalid
`APP_DOMAIN` makes delivery fail and remain retryable. These review links do not
allocate shortcodes or create public endpoints. No email fallback is sent.

The first reminder goes to `Service::SlackConnector.admin_channel`, the retained
helper alias for **Members Relations Channel**: `slack_channel_admin`, default
`members_relations` when absent or blank. **RM Channel** remains the separate
`slack_channel_rm` setting, default `resource_managers` when absent or blank.
This is separate from the pending-volunteer channel used when a member submits
task completion. The job persists the wait start and subject before making the
Slack request, then saves Slack's message `ts`, returned channel, and
`destination_mode` (`production` or `test`) with that intent when Slack
acknowledges the post. Subsequent runs update that same message with the current
elapsed wait instead of posting another reminder. Pending text uses the current
title and attendee count; final text retains the claimant or event/attendee
subject snapshot from the original intent.

Updates use the saved conversation ID even if the configured Members Relations Channel later
changes. Normal post redirection to `test_channel` still applies outside
production. A saved receipt is edited only when its `destination_mode` matches
the running Slack environment; a mismatch is reported and retained for retry
in the original environment. This prevents changing destinations when a saved
message is processed under a different production/test mode.

Task approval or denial and event closure save closure metadata in the same
MongoDB update as the lifecycle transition. Cancellation and generic task
status edits use the same mechanism. Genuine dotted receipt fields preserve
concurrently registered Slack timestamps, channels and destination modes;
normal Mongoid validation and callbacks still run. The transition saves
`finalized: false`, so the existing final-delivery scan can recover even if a
later metadata write or Slack update fails. Sync finalizes a closed snapshot
without a timestamp without posting; late receipt registration reopens delivery.
Recorded reminders are then updated in place with the outcome and total wait.
Task approval first saves a `Credit award not confirmed` outcome with the
completed status, and changes it to approved only after credit creation returns
successfully. If creation raises, it instead saves a `Credit award failed`
outcome and updates the existing message with a warning to verify the saved
credit and correct the award manually. The task remains completed and cannot
be approved again through the normal completion flow. Check credits linked to
the task before correcting it: a write can have succeeded before the exception,
so blindly awarding another credit can duplicate it. A later notification or
billing failure after successful creation retains the approved outcome.
Failed delivery of the warning uses the normal final-message retry scan; the
job retries message delivery, not credit creation. If the later outcome write
also fails, error reporting records that failure and the original creation
error is preserved for the caller. The initial unconfirmed warning remains
durable whenever the completed-status write succeeded, including when credit
creation actually succeeded but recording its confirmation failed. Verify the
saved credit before manual correction; the job cannot infer the award outcome.
Event closure saves a `Credit award not confirmed` warning atomically with its
closed status before processing attendees. After processing, it confirms closure
only if no attendee operation raised. Member lookup failures (other than deleted
members), credit creation, award notification, and membership discount processing
failures produce a warning identifying the affected member IDs and processing
stage, counting each affected attendee once even if multiple stages fail. An
award DM or template failure is recorded independently; discount processing
still runs for that attendee's saved credit. Other attendees are still processed; deleted and inactive members are
skipped as before. Verify saved credits and follow-up processing before correcting
an award, since a credit can have been saved before the failure. Event closure
opts into error propagation from the credit notification and discount helpers;
those helpers only propagate the original error in this mode. Event closure
owns its single error report and, for discount-processing failures, a single
logs-channel discount error notice. Other callers retain their existing
rescued-error behavior. Failure to deliver the error notice itself is reported
as a separate notification failure. A failed outcome
write leaves the original unconfirmed warning durable. A delivered warning can
be `finalized: true`: this confirms message delivery, not correction of the credit
problem. The job retries warning delivery, not attendee credit operations. No final message is
created if that activity never had an overdue reminder. An outcome snapshot can
exist before a posted-message receipt; if an in-flight post finishes after
review, its returned `ts` is attached to the matching snapshot and finalized.
A failed final update leaves durable state for a future job run to retry,
including a rejected task that is available again. If that task is claimed
again, its old intent or receipt is retained in `approval_notification_history`
so the old outcome can still be delivered without overwriting the new claim's
reminder. Conditional MongoDB writes guard against concurrent receipt/review
changes; competing posts retain the first registered message and attempt to
delete duplicates. A failed duplicate cleanup is reported.

Rescheduling an open event retires its Members Relations Channel reminder as
well as versioning the separate RM DM receipts. The new date and archival of
the live channel intent are saved in one guarded database write, preserving a
Slack timestamp that arrived after the event was loaded. The old reminder is
updated immediately to show `Rescheduled from ... to ...` and the elapsed wait
for its previous schedule; this does not close the event or issue credits. Its
current `approval_notification` is cleared, and failed updates remain retryable
in `approval_notification_history` even while the new date is in the future or
absent. After the new date becomes more than five days overdue, a fresh channel
message starts its wait clock at that date. A unique intent `generation_id`
keeps in-flight posts attached to their archived reminder even after a date is
changed back to its previous value. Legacy receipts without IDs are still
supported. Changes without a channel intent do not manufacture old reminders.
Validation failures leave the date and reminder unchanged; a concurrent
schedule/status change aborts the guarded reschedule, so reload before retrying.

Proposed task cancellation and generic status edits also finalize an outstanding
review reminder with the actual outcome. Setting a task to completed through a
generic edit does not issue credits, and the final notice states that distinction.
Before destroying an unlinked task, its model callback withdraws pending review
(saving cancelled status and a deletion-requested outcome together), closes any
outstanding historical reminders, and synchronizes final Slack text. Subject
generation uses `Unknown member` when the claimant record has been deleted,
including when deletion must build an outcome without a saved reminder subject.
If a known
posted message cannot be finalized, destruction raises `Error::ServiceUnavailable`
and `DELETE /api/admin/volunteer_tasks/:id` returns HTTP 503 with the usual
`status`, `error: service_unavailable`, and retry-guidance `message` JSON fields.
It preserves the cancelled record and retry receipts; the daily job can finish delivery, then deletion can be
retried. Existing approved/denied outcomes are preserved. A post or age update
already in flight when the task disappears removes its message best effort;
the worker first verifies absence of the task/event document on the MongoDB
primary. A missing claimant uses the subject fallback and retains the Slack
message; a failed existence check retains the message and reports the error.
Cleanup failures are reported. Low-level `delete`/`delete_all` bypass model
callbacks. Event destruction still removes its receipt without finalizing the
Slack message; an actually deleted event cannot be retried by this job.

Individual post/update failures are reported and the scan continues. The job's
`success` status means its scan completed, not that every reminder was delivered.
It does not approve claims, close events, award credits, or change the monthly
processing policy. No new collection, environment setting, or public API field
is introduced; these receipts remain internal task/event data.

## Operational cautions

- Slack API errors from an individual profile update are rescued inside
  `Service::SlackProfileSync.sync_one`. Despite that failure, `sync_all` counts
  the member as synced, advances `slack_profile_sync_last_run_at`, and allows the
  wrapper job to record success. The member is then outside later incremental
  runs even though Slack was not updated. After correcting the Slack error,
  retry that member directly with `RAILS_ENV=production bundle exec rails
  runner 'pp Service::SlackProfileSync.sync_one(Member.find("MEMBER_ID"))'` and
  confirm that it returns the member rather than `nil`. Rate-limit responses
  are first retried up to five times using Slack's requested delay; this warning
  applies if those retries are exhausted. Rewinding the global
  checkpoint is an alternative only when deliberately replaying all expirations
  in that interval and accepting duplicate updates.
- Manual Rake invocations of `member_review`, `invoice_review`, `gc`, `backup`,
  `card_on_file_expiration_check`, and
  `reservations:rebuild_slack_canvases` do not update their admin-visible job
  status. Invoke the corresponding Active Job synchronously when status history
  must reflect the manual run.
- Several workflows send Slack messages, email, or mutate remote Slack, Google,
  Braintree-derived caches, and Google Drive state. A manual run is not a dry
  run, and repeated runs can repeat notifications.
- A reservation canvas rebuild also attempts volunteer-canvas synchronization
  for every shop and can create missing volunteer canvases or change their owner
  access. A missing canvas is created only if the shop has a resolvable Slack
  channel and at least one claimable top-level task or current/future active
  event; shops that fail those prerequisites remain unchanged. Do not treat the
  command as a reservation-only operation. It skips reservation synchronization for
  shops with no existing daily canvas and no relevant blocking reservation or
  blackout, and Slack requires a channel manager to attach each newly created
  daily canvas manually to its shop channel header.
- `VolunteerEventReminderJob` records success when its task/event and final-update scan completes,
  not when its Slack messages are delivered. Each delivery error is rescued and
  reported separately, so check error reporting when delivery confirmation
  matters even if `job_status_volunteer_event_reminder` says `success`.
- The database backup task writes a credentials-bearing config file in `/tmp`
  only for the duration of the run and removes it in `ensure`; protect process
  output and the generated archive as production data.
- Review worker, Redis, MongoDB, Slack, Google, Braintree, and environment
  configuration before enabling scheduler entries. Failures are generally sent
  to the central error reporter and/or Slack logs channel, but per-record rescue
  behavior can allow a job to complete after partial failure.

## Repair ticket delivery

`FixTicketDeliveryJob` delivers each ticket's pending events in revision order under a renewable per-ticket Redis lease (`FixTicketDeliveryLease`). It creates/repairs central Slack roots, posts threaded/broadcast updates, optional shop summaries and recipient DMs. Stable per-event delivery IDs and persisted receipts support retries; failures do not roll back committed tickets. Retry policy: polynomial backoff, eight attempts. A MongoDB reservation (delivery_job_id and delivery_job_until on the ticket) admits only one queued/running/retrying job chain per ticket. Enqueue failure, success, or exhausted retries release it by matching job ID. Every enqueue and running lease heartbeat renews the reservation for 24 hours beyond the current/scheduled time; an abandoned reservation can then be replaced, and stale job IDs stop without spawning retries. Events arriving during delivery are rechecked after release. Reservation writes never advance the ticket update timestamp.

`FixTicketDeliveryRecoveryJob` runs every ten minutes in config/schedule.rb; it re-enqueues tickets with undelivered events, including events whose original queue enqueue failed. External schedulers may run `bundle exec rake fix_tickets:recover_deliveries` every ten minutes instead. `data:ensure_unique_indexes` creates repair ticket, event, and reveal indexes alongside the core indexes during deployment. `fix_tickets:ensure_indexes` remains a compatibility alias for that task. FixTicketService owns transactional mutations/outbox creation; FixTicketPolicy owns scopes/capabilities; FixTicketDelivery owns notification content and routing.

`FixSlack` builds the private `/fix new` and `/fix-tickets new` report modals at
request time. Their Shop dropdown embeds all non-hidden shops in alphabetical
order, with **No Shop Selected** first. A matching non-hidden channel shop is
selected by default, otherwise the default is no shop; opening the dropdown
needs no options-search callback. Submission
removes that empty-shop choice before calling `FixTicketService.create!`.
Selecting a catalog tool still uses its shop, and channel-based ticket list
filters retain their scope. Modal construction writes no ticket; submission
uses the existing transactional service and validation/error handling.

`AvailableShopCache` is a synchronous display-list service. `fetch` stores only
string `id`, `name`, and the persisted `slack_channel` (including null/blank) for
shops whose `disabled != true`; out-of-service shops remain included. It never
resolves Slack channels. JSON entries retain MongoDB's English strength-2
collation order by name then ID. Empty lists are valid hits. Keys include schema
version, Rails environment and effective MongoDB database. The fixed lifetime is
10,800 seconds from snapshot start; reads never extend it. Generation tokens and
atomic conditional publication reject snapshots overtaken by invalidation or
older than three hours. Generation keys are retained to fence in-flight readers.

Shop save/destroy callbacks refresh before post-save integration callbacks on
creation, name/channel changes, hide/unhide and successful destruction. Invalid
saves and aborted destruction do not refresh; unrelated fields do not refresh.
These are Mongoid save/destroy callbacks, not transaction commit callbacks.
Future transactional shop writes must arrange refresh after the outer transaction
commits; never publish an uncommitted snapshot. `with_bulk_changes` invalidates
before callback-bypassing imports/deletes and refreshes in ensure, including
partial failure. `db:db_reset` uses it around clearing and seeding. Raw `set`,
`update_all`, `delete_all` or direct database changes to cached fields must use
this wrapper or explicitly refresh afterward. Existing raw canvas, Google-resource
and outage-receipt updates do not change cached fields.

`load_all` and `load_visible` own full MongoDB queries, return fresh Shop records,
and warm from those same records without a second query. Complete shop/workshop
indexes and reservation/checkout canvas and Google-resource maintenance scans
use them. Restricted indexes, search, pagination and projections never warm the
cache. Fix-ticket creation, ordinary-member catalog/suggestions, Slack checkout
selectors and non-hidden shop-channel enumeration consume display entries.
Privileged hidden-shop scopes, authorization, routing decisions and reservation
eligibility continue querying MongoDB. Public response fields are unchanged.
`Service::ShopSlackChannels.associated?` checks live non-hidden shops when the
cached channel association is absent, using the same normalized name/ID matching.
This preserves checkout routing for newly created or reassigned channels after
Redis recovers with a snapshot whose invalidation failed. Cache hits retain the
fast path; channel enumeration and public-channel resolution remain unchanged.

Redis read/write failures are logged and do not fail successful shop edits;
reads fall back to MongoDB. Later reads and relevant writes retry maintenance.
A failed invalidation may leave stale entries until their original expiration
(at most three hours). MongoDB remains authoritative. `refresh!` is strict for
operators; `refresh` logs maintenance failures after successful persistence.
Run `bundle exec rake shops:refresh_cache` after restores or out-of-band changes,
with the target Rails environment, MongoDB database and Redis configuration.
It rebuilds synchronously and exits unsuccessfully on failure or a superseded
refresh (retry in that case). It is manual, not scheduled, and has no job-status
record. No new environment variable, collection or index is required.

Central repair-ticket delivery allowlists status, confirmation, assignments, and announcement-note changes plus new discussion notes/bounties. Unrelated field updates do not create central replies or roots.

FixTicketService maps MongoDB `TransactionsNotSupported` to an actionable HTTP 503 error; it never retries ticket writes outside a transaction. Local single-node replica-set setup is documented in `fix-tickets.MD`.

Ticket mutations enqueue `VolunteerSlackCanvasSyncJob` for the linked shop after commit when creating a bounty or cancelling an available bounty through ticket closure/withdrawal. Rolled-back mutations do not enqueue canvas updates.

Linked bounty release/rejection defers its claimant Slack notification and `VolunteerSlackCanvasSyncJob` until after assignment and event writes commit; transaction aborts/retries do not publish those effects.

Linked bounty claims also suppress the superclass canvas enqueue inside the transaction. One canvas sync (with the claimed task ID struck) is enqueued only after the claim, assignment, and event writes commit; aborted claims enqueue none.

Checkout canvas catalog synchronization includes out_of_service changes. Visible unavailable tools show an Out of service - do not use warning; Hidden remains independent.

`SlackVolunteerJob` filters personalized bounty listings through `VolunteerTask#eligible_for?` for every role, before the 15-task limit. Linked-ticket reporter and prerequisite restrictions apply; ordinary-task privileged exemptions remain.

Slack task-claim and event-check-in confirmations, completion acknowledgments,
and `/volunteer myclaims` (including an empty list) show the shared
`VolunteerCreditMessaging` timing and review guidance. Event check-in DMs use the
same guidance, including when staff add an attendee. It explains the manually
managed policy that credits from activity in one month are reflected in the next
month's totals (for example, April activity in May), and asks members to wait
patiently for unpaid volunteer approvers. Pending task rows await volunteer
approver review rather than asking members to submit completion again. This is
member-facing guidance for approvers' manual workflow; it does not add a monthly
job, defer automatic credit creation, or change ledger or discount calculations.

Repair-ticket delivery skips missing optional shop destinations, and scopes central reply receipts to the current Slack thread so recovery can republish pending events after root deletion.

### Volunteer task and repair-ticket visibility

Volunteer task Slack listings and claim-error messages apply the viewer's catalog
visibility; shared volunteer canvases omit hidden task prerequisite names. Hidden-shop
canvases use a generic header and rename existing titles on refresh.
Stored prerequisites continue to govern eligibility. Repair-ticket announcements
also run when shop or tool references change, selecting the current tool/shop
channel and retaining per-event delivery receipts to prevent duplicate sends.

Tool availability updates queue `ReservationSlackCanvasSyncJob` for each affected active, unexpired reservation overlapping today or tomorrow in the reservation time zone. Tool restoration also refreshes these dates. Reservation canvases retain bookings and label individually booked out-of-service tools as unavailable.
# NFC card assignment and release

`CardManagement` performs assignment and eligible release in MongoDB transactions
(replica set required). Assignment defers the existing card provisioning/invoice
callbacks until commit; release enqueues `MemberProvisioningJob` for the prior
member after committing deletion and its audit. Release also clears the matching
rejection-card holder so the UID can be imported again. The member write within
the transaction detects concurrent renewals/revocations; a stale version returns
409. Card operations create no recurring job.

Recipient repair-ticket DMs use a linked **Ticket #N** portal label and an
**Open ticket in Slack** button (`fix_view`). The existing interaction handler
rechecks workspace identity and ticket permission before opening the private
detail modal. Only the first message chunk contains the button; delivery receipts,
reconciliation, and central/shop message formatting remain unchanged. Wiki changes
for this and roster recovery are held in `docs/wiki-ticket-notifications.patch`,
prepared against WikiPages master `7c1a7f1316bd12d30da43ce9af09b40e92602ff3`.
Publish after the Rails deployment; refresh the patch against current wiki first.

## Checkout expiration

`SlackReservationModal` uses `ReservationReadContext.valid_through_tool_ids` for
each duration and the final computed end. `ReservationPolicy.eligible_tools`
accepts an optional `through` time for end-aware choices; existing today-only
callers retain their behavior. All checks share cached current checkout records
within a single operation. Slack date/time/duration block actions refresh the
preview, with no writes or notifications. No valid duration yields **Review
selection** and a prerequisite warning. Final submission still revalidates with
fresh data under the reservation locks. No environment variables changed.

**CheckoutExpirationNoticeJob** is registered as checkout_expiration_notice
(**Checkout Expiration Notices**) in the portal job inventory.
`bundle exec rake checkout_expiration_notice` performs the same job synchronously;
admin Run Now queues it. This new job and its advance-days setting are admin-only
(the existing board access to other jobs is unchanged). It records success/failure
through SystemConfig.record_run. No recurring schedule was added. Run against
the intended application environment; it sends real email and Slack DMs.

**CheckoutExpirationNotice** scans dated current non-revoked checkouts, serializes
delivery per member using a Redis ownership-token lock, rechecks current dates
and member eligibility before each channel/group, and sends the highest due
stage. Upcoming and newly expired records are separate groups. State is stored
per channel on the checkout and guarded by date/revision when marking success.
Missing Slack identity skips Slack only. Failures are reported while other
channels/members continue; partial failure raises and marks the job failed.
Retry resumes unrecorded channels. Provider acceptance followed by acknowledgment
failure can cause duplicates; delivery is not exactly-once.

After the delivery scan, the service queues one full
`ToolCheckoutSlackCanvasSyncJob` rebuild per shop with newly expired current
checkouts. This runs even after partial delivery failures and is independent of
member eligibility, email availability, and Slack linkage. The checkout's
`expiration_notice_state.canvas_completed` is set to 3 only by a successful full
publish in `Service::ToolCheckoutSlackCanvas.sync!`, including calls from the
canvas job. The service snapshots expired checkout dates/revisions before
rendering, then marks only unchanged current rows after Slack accepts the publish.
Skipped or failed publishes leave rows eligible for later notice scans, even
after the canvas job exhausts its five retries. Enqueue failures fail the notice
job while other shops continue. Date changes clear completion with notice state.
Legacy `canvas` enqueue markers are ignored, so the next scan repairs those
rosters without a backfill. Repeated scans before completion can enqueue duplicate
rebuilds; completion-write failures also retry safely through a full rebuild.

**CheckoutExpirationManagement** is the synchronous, scoped date-management
service: strict ISO dates, future-only bulk dates, catalog then member/tool locks for individual edits,
MongoDB transactions, revision conflicts, audit persistence, and canvas refresh
after commit. It never grants checkout credit. **CheckoutExpiration** centralizes
current/valid scopes, Eastern date boundaries, initial policy dates, renewal
linkage, and effective training links. **CheckoutTrainingPlan** normalizes and
validates tool/group URLs. ReservationReadContext/ReservationService now apply
valid-through-end checks in previews and mutations; checkout eligibility readers
use the shared valid scopes. CheckoutMailer uses local HTML/plain templates.

`bundle exec rake data:ensure_checkout_expiration_indexes` is a manual repeatable
deployment operation creating the expiry query index only. It neither sends
messages nor backfills dates. See [collection inventory](mongodb-collections.MD).

### Bulk expiration locking and recovery

Bulk date updates use CatalogMutationLock.with_persistent on the existing
checkout_request_lock/catalog/<shop-id> Redis key. CheckoutMutationLock acquires
it with SET NX and no expiry, releases it only when its ownership token matches,
and supplies an ownership check used before writes and before transaction commit.
Only one lock is held regardless of roster size. Renewals, approvals, catalog
edits, and individual date edits already contend on this same catalog key.
The bulk transaction streams the current records without a recursive member-lock
chain. Concurrent revocations cause MongoDB write conflicts; each transaction
retry requeries the current records. A failed/too-long transaction rolls back
its dates and audits, rather than allowing a lease to expire during writes.

An exception releases the key normally. A killed worker or failed Redis release
can leave an orphan key: stop/confirm termination of the owning request/worker
and confirm no transaction can still commit before recovering it. Read the
exact key's token and remove it with the same compare-token-and-delete Lua used
by CheckoutMutationLock; never clear a live lock or delete unrelated keys.
Do not add a TTL to an in-progress persistent lock to work around contention.
No new environment variables, schedules, or collections are introduced.

CheckoutCreation queues a full shop checkout canvas rebuild for renewals
(renewed_from_id present). The rebuild renders current valid members once,
replacing stale expired predecessor lines. Initial checkouts retain incremental
adds. Neither path sends notices inside its approval transaction.
