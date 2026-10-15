# Shop and Tool Reservations

## Group selection

Reservation inputs accept `tool_group_ids` alongside `tool_ids`. The service
expands groups and deduplicates all physical tools before policy, conflict,
capacity and fee evaluation. A reservable group permits individually
non-reservable children; hidden/out-of-service restrictions and all other child
policies still apply. Group prerequisites supplement child prerequisites.
Groups have no price or Google Calendar resource of their own.

Saved `group_snapshots` preserve the selected name, revision, membership and
prerequisites. Updates omitting both resource arrays retain those snapshots.
Legacy clients resending unchanged physical IDs without group IDs also retain
them. Calendar descriptions, Slack summaries and portal history use saved names.
Explicit resource selection performs a fresh expansion and fee preview; the
portal clears fee acceptance when the selection changes. The reservation catalog
adds `toolGroups` only for `include_groups=true`, preserving older native clients.

## Overview

The reservation feature allows eligible members to reserve an entire shop or one
or more reservable tools in that shop. Reservations can be created in the Member
Portal or with `/reserve` in the Slack channel assigned to a shop.

The implementation spans:

- `makerspace-rails-2026`: models, authorization, reservation rules, Slack
  endpoints, Google Workspace resources, Calendar events, background jobs, and
  APIs.
- `makerspace-react-2026`: resource configuration, reservation creation,
  availability, history, cancellation, and manager approval screens.
- Google Workspace: Calendar resources for shops and tools, Calendar labels,
  and reservation events.
- Slack: the `/reserve` command, a reservation modal, validation responses, and
  approval/denial notifications.

Redis is required for reservation locking and Google color caching. A background
job worker must be running for Calendar synchronization and Slack decision
notifications.

## Roles and authorization

### Members

An active, unexpired member can create a reservation when:

- The selected shop or tools are enabled and reservable.
- The reservation starts in the future and uses 30-minute increments.
- The start is within the configured reservation horizon.
- The duration does not exceed the strictest selected resource limit.
- The member has every required active checkout.
- The reservation does not exceed the available concurrent capacity.
- If the member has no active recurring subscription, the reservation ends no
  later than the current membership expiration.

Members can view their own reservations, including cancelled reservations.
They can edit or cancel their own future pending, unpaid, or approved reservations.

Inactive, expired, or revoked members cannot create or edit reservations. They
can still view and cancel existing reservations. Revoking a member cancels their
current and future active reservations.

### Resource Managers

A Resource Manager only has reservation and catalog authority in shops listed
in the member's `resource_manager_shop_ids`.

Within an assigned shop, an RM can:

- Configure the shop and its tools for reservations.
- Create reservations on behalf of an eligible member.
- View the shop's reservation queue.
- Approve, deny, edit, or cancel reservations.

An RM cannot approve their own reservation.

An RM who is only a checkout approver for a tool in another shop has ordinary
checkout-approver authority for that tool only. Checkout-approver assignment
does not grant catalog management or reservation-management authority.

### Admin and Board

Admins and Board members have global management access. They can create
reservations on behalf of eligible members.

Board members additionally have a personal reservation override:

- Up to 72 hours per reservation.
- Required checkouts are waived.
- Their own overlapping reservations are allowed.

The Board override does not make a non-reservable resource reservable.

## Shop and tool configuration

Shops and tools have these reservation settings:

| Setting | Default | Meaning |
| --- | ---: | --- |
| `reservable` | `false` | Makes the resource available for new reservations. |
| `max_concurrent_reservations` | `1` | Maximum overlapping reservations for the resource. |
| `reservation_horizon_days` | `7` | Furthest permitted reservation start date. |
| `max_reservation_duration_hours` | `8` | Maximum duration, in 0.5-hour increments. |
| `reservation_requires_approval` | `false` | Makes new reservations pending until approved. |
| `reservation_prerequisite_tool_ids` | Shop: none; Tool: itself | Active checkouts required from the reservation owner. |

Prerequisite tools must belong to the same shop. A tool always requires a
checkout on itself, even when its prerequisite field is empty or missing in a
legacy document.

Each shop can also define:

- `slack_channel`: channel name without `#`, used to route `/reserve`.
- `color_id`: used for the shop's Calendar label and reservation events.
- `google_resource_id` and `resource_email`: synchronized Google resource
  metadata.

Tools also store `google_resource_id` and `resource_email`.

## Reservation rules

- Times are stored in UTC and entered/displayed in `America/New_York`.
- Start and end times must fall on 30-minute boundaries.
- The end is exclusive.
- Reservations are non-recurring.
- A title is required.
- A member first chooses a shop, then the entire shop or one or more tools.
- Multi-tool reservations are atomic: every selected tool must be eligible and
  available.
- Pending, unpaid, and approved reservations consume capacity.
- Cancelled and denied reservations do not consume capacity.
- A shop-wide reservation conflicts with all tool reservations in that shop.
- A tool reservation conflicts with a shop-wide reservation in that shop.
- Tool capacity is evaluated independently for every selected tool.
- A reservation is pending when any selected resource requires approval.
- A reservation is also pending when its owner already has an overlapping
  pending, unpaid, or approved reservation anywhere.
- Material edits repeat current eligibility and capacity validation and may
  return an approved reservation to pending.
- Configuration changes do not invalidate existing reservations, but new and
  materially edited reservations use the current configuration.
- Shops and tools referenced by future pending, unpaid, or approved reservations cannot
  be deleted.

Reservation writes are serialized with a Redis lock scoped to the shop. If Redis
or locking is unavailable, the request fails safely with a retryable message.

## Reservation statuses

- `pending`: waiting for RM/Admin/Board approval; blocks capacity.
- `unpaid`: awaiting reservation fee payment; blocks capacity until cancelled.
- `approved`: valid reservation; blocks capacity.
- `denied`: rejected; does not block capacity.
- `cancelled`: cancelled by the member, manager, membership lifecycle, or
  revocation; does not block capacity.

Cancelled reservations remain visible to their owner and to authorized
managers.

## Member Portal behavior

The Reservations page provides:

- Shop and resource selection.
- A required title.
- A start date and 24-hour start-time field.
- The next whole hour as the initial start time.
- A duration input and linked 0.5-hour slider.
- A computed end date and time.
- A duration maximum based on configuration, membership expiration, and the
  next capacity conflict.
- Preview warnings for prerequisites, conflicts, and approval requirements.
- A 30-minute day agenda.
- Upcoming and historical reservation lists.
- Edit and cancellation controls.
- A scoped manager approval queue.

After a successful reservation creation, the form is reset and the returned
title and status are shown both at the top of the page and below the Reserve
button. API validation and authorization messages are displayed when creation
fails.

## Google Workspace integration

### Required APIs

Enable these APIs in the Google Cloud project associated with `GOOGLE_ID`:

1. Google Calendar API
2. Admin SDK API

Google Drive API is also required if the same credentials are used by the
portal's existing Drive functionality, but it is not required by reservations
alone.

### Required OAuth scopes

The minimum refresh-token scopes for reservations are:

```text
https://www.googleapis.com/auth/admin.directory.resource.calendar
https://www.googleapis.com/auth/calendar
```

The Directory scope permits creation, lookup, update, and deletion of Calendar
resources for shops and tools. The Calendar scope permits colors, labels,
attendees, and reservation-event synchronization.

If one refresh token is shared with the existing Google Drive integration,
authorize all three scopes:

```text
https://www.googleapis.com/auth/drive
https://www.googleapis.com/auth/admin.directory.resource.calendar
https://www.googleapis.com/auth/calendar
```

### Create the refresh token

1. In Google Cloud Console, configure the OAuth consent screen. Prefer an
   **Internal** app for a Workspace-only deployment.
2. Create or select the Web application OAuth client represented by
   `GOOGLE_ID`.
3. Add this authorized redirect URI:

   ```text
   https://developers.google.com/oauthplayground
   ```

4. Open the [OAuth 2.0 Playground](https://developers.google.com/oauthplayground).
5. Open the Playground settings and select:

   - OAuth flow: **Server-side**
   - Access type: **Offline**
   - Force prompt: **Consent Screen**
   - **Use your own OAuth credentials**

6. Enter the same client ID and client secret that will be deployed as
   `GOOGLE_ID` and `GOOGLE_SECRET`.
7. Under Step 1, choose **Input your own scopes**, enter the required scopes
   above, and authorize them.
8. Sign in as a Google Workspace administrator or delegated administrator who:

   - Can manage buildings and Calendar resources.
   - Owns the dedicated reservations calendar.
   - Has access to any Drive resources when the Drive scope is included.

9. In Step 2, exchange the authorization code for tokens.
10. Copy the **refresh token**, not the temporary access token, into
    `GOOGLE_TOKEN`.

Do not commit the client secret or refresh token.

### Google environment variables

```dotenv
GOOGLE_ID=<OAuth client ID>
GOOGLE_SECRET=<OAuth client secret>
GOOGLE_TOKEN=<offline refresh token>
GOOGLE_RESERVATIONS_CALENDAR_ID=<dedicated calendar ID>
GOOGLE_CUSTOMER_ID=my_customer
```

`GOOGLE_CUSTOMER_ID` defaults to `my_customer` when omitted.

The account behind the refresh token should be the data owner of
`GOOGLE_RESERVATIONS_CALENDAR_ID`. Merely granting an ACL role may not be
sufficient for Calendar event-label management.

### Resource and event synchronization

On shop/tool creation, or when editing a record that lacks Google metadata:

- A shop is matched or created as a `CONFERENCE_ROOM`.
- A tool is matched or created as `OTHER`.
- The Mongo ObjectID is used as the Google resource ID.
- The returned resource email is saved locally.
- A Calendar label is created or updated using the record's deterministic UUID,
  name, and shop color.

Directory creation and deletion are best-effort and do not roll back the local
catalog operation.

Each active reservation is synchronized as one deterministic Calendar event:

- The reservation ObjectID is the event ID.
- The shop or tool resource emails are resource attendees.
- The owner's email is included when it is deliverable.
- The returned Google `htmlLink` is stored on the reservation as
  `calendar_html_link`.
- Pending events are prefixed with `[Pending]`.
- The shop color and shop label are attached.
- Approval and edits update the event.
- Denial and cancellation delete the event.

When `calendar_html_link` is present, reservation titles in the Member Portal
link to the Google Calendar event and open it in a new tab.

If Google rejects an event with `invalid: Invalid event label`, the application
recreates the shop label and retries. If label creation or the labeled retry
fails, it submits the same event without label metadata.

Google color definitions are cached in Redis. The first eleven choices use the
standard RGB definitions for black, red, blue, green, yellow, orange, brown,
purple, gray, tan, and teal, followed by additional Google colors.

### Reconcile existing resources

After deploying credentials or changing Google configuration, restart Rails and
the background workers, then run:

```shell
bundle exec rake google_resources:reconcile
```

This queues resource and label synchronization for existing shops and tools.

## Slack integration

### Slack app capabilities

Create a Slack app for the workspace or update the existing Member Portal app.
The reservation integration needs:

- A `/reserve` slash command.
- Interactivity enabled for modal submissions.
- A bot token that can open views and send messages.
- Read-only reservation agenda canvases shared with each configured shop
  channel.
- The app signing secret for request verification.

Minimum bot/OAuth scopes for the reservation flow:

```text
commands
chat:write
canvases:write
channels:read
groups:read
```

`canvases:write` permits the app to create and replace the reservation agenda
canvases and grant a shop channel read access. `channels:read` and
`groups:read` allow the app to resolve configured public and private shop
channel names to Slack channel IDs. Slack canvases require a paid Slack plan.

For the complete scope inventory covering every Slack API call in the Rails
application, including commented-out admin/user-token scopes, see
`makerspace-rails-2026/config/slack_scopes.example.yml`.
For an importable bot-only Slack app manifest containing all scopes supported
by `SLACK_BOT_TOKEN`, see
`makerspace-rails-2026/slack-bot-manifest.json`.

The broader Member Portal Slack synchronization may also require:

```text
users:read
users:read.email
```

Other existing portal features may require additional administrative scopes;
do not remove scopes already used by those features.

### Configure `/reserve`

In **Slack API → Your App → Slash Commands**:

1. Create a command named `/reserve`.
2. Set the request URL to the public HTTPS Rails endpoint:

   ```text
   https://<portal-host>/slack/commands/reserve
   ```

3. Suggested short description:

   ```text
   Reserve this shop or one of its tools
   ```

4. Save the command.

The command must be invoked in a channel whose name exactly matches a shop's
`slack_channel` value. Store the channel name without the leading `#`.

### Configure modal interactions

In **Slack API → Your App → Interactivity & Shortcuts**:

1. Turn **Interactivity** on.
2. Set the request URL to:

   ```text
   https://<portal-host>/slack/interactions
   ```

3. Save the configuration.

Both URLs must be publicly reachable over HTTPS. They are intentionally outside
the Rails `/api` namespace because Slack sends form-encoded requests.

### Install the app and configure secrets

Install or reinstall the app to the workspace after changing commands or OAuth
scopes. Copy the bot token and signing secret into the Rails environment:

```dotenv
SLACK_BOT_TOKEN=xoxb-...
SLACK_ADMIN_TOKEN=xoxp-...
SLACK_SIGNING_SECRET=<Slack app signing secret>
SLACK_ENV=production
SLACK_TEAM_ID=<optional workspace/team ID>
```

`SLACK_BOT_TOKEN` is preferred for all ordinary Slack API calls. If it is not
configured, the application falls back to `SLACK_ADMIN_TOKEN` for those calls.
When both are configured, `SLACK_ADMIN_TOKEN` is used only for calls that
require an administrator/user token, such as workspace invitations,
deactivation, billable-user lookup, and editing another user's profile. A
bot-only deployment logs skipped administrator operations to stderr and
Honeybadger.

Always configure `SLACK_SIGNING_SECRET` in deployed environments. When it is
present, Rails validates `X-Slack-Signature`, rejects requests older than five
minutes, and prevents replay or forged requests.

Set `SLACK_ENV=production` in production. In other environments, outbound
channel messages are redirected to `test_channel`.

Restart Rails and background workers after changing Slack environment
variables.

### Link shops and members

For each Slack-enabled shop:

1. Edit the shop in the Member Portal.
2. Set **Slack Channel** to the exact channel name without `#`.
3. Make the shop or at least one enabled tool reservable.

Members must have a linked `SlackUser` record and an active, unexpired Member
Portal account. If the Slack identity is not linked, `/reserve` returns an
ephemeral instruction to link an active account.

### Slack reservation flow

1. The member types `/reserve` in the configured shop channel.
2. Rails verifies Slack's signature and resolves the channel to a shop.
3. Rails resolves the Slack user to an active member.
4. The app opens a modal containing:

   - Title
   - Entire-shop or tool scope
   - Reservable tools
   - Date
   - Start time
   - End time

5. Modal submission uses the same reservation service and validation rules as
   the Member Portal.
6. Validation errors are returned inline in the modal.
7. Success clears the modal and sends the member a status confirmation.
8. When a pending reservation is approved or denied, a background job sends
   the linked Slack user a direct notification unless direct notifications are
   suppressed.

Approved reservations also receive a scheduled Slack reminder when the member
has a linked Slack account. If the reservation starts 6 through 47 hours in the
future, the bot schedules the reminder for 30 minutes before the start time. If
it starts more than 47 hours in the future, the reminder is scheduled for 8
hours before the start time. Reservations starting in less than 6 hours do not
receive a scheduled reminder. The message includes the title, time, shop/tools,
and a linked **member portal** cancellation prompt.

Slack's returned `scheduled_message_id` is stored on the reservation. Edits
replace the scheduled reminder so its details and delivery time remain current.
Returning a reservation to pending, denying it, or cancelling it removes the
scheduled message with `chat.deleteScheduledMessage`. These calls use the
ordinary bot token and require the existing `chat:write` bot scope.

When a reservation is created, updated, cancelled, approved, or denied and it
touches today or tomorrow in `America/New_York`, a background job refreshes the
corresponding shop agenda canvas. The first refresh creates an unbound canvas
named **Today's SHOPNAME Reservations** or **Tomorrow's SHOPNAME Reservations**,
grants the configured shop channel read access, and saves the returned canvas
ID as `canvas_today` or `canvas_tomorrow` on the shop. Subsequent refreshes
replace the agenda with the day's pending, unpaid, and approved reservations. Cancelled
and denied reservations are removed because they do not consume capacity.
When a separately selected tool is marked out of service or restored, any
today/tomorrow agenda containing an active reservation for that tool is also
refreshed. Out-of-service tools are labeled **OUT OF SERVICE** in the
reservation's Resources cell so shop operators can identify unsafe bookings.

Slack does not automatically add these read-only canvases to the shop channel
header. A channel manager must manually add each canvas to the header using the
**+** button.

Tool checkouts use a separate read-only canvas named **SHOPNAME Checkouts**.
Creating or revoking a checkout queues a refresh for the tool's shop. The first
refresh creates the canvas and saves its ID as `checkout_canvas_id` on the
shop; later refreshes replace its contents. The canvas lists every enabled tool
in the shop, its description and wiki link, enabled checkout prerequisites,
and active, unexpired members with a current checkout. Checkout approvers and
Resource Managers for the shop are distinguished from other checked-out
members. Each checked-out member is rendered as a separate bulleted-list item
so Slack preserves one member per line. Linked members are displayed as plain,
ASCII-only sanitized Slack usernames rather than Slack mention markup; members
without a stored Slack username fall back to their sanitized portal name.

Like reservation canvases, Slack does **not** automatically make a newly
created checkout canvas visible in the shop channel header. After the shop's
first checkout creates **SHOPNAME Checkouts**, a channel manager must manually
open the shop channel, use the header's **+** button, and add that canvas. This
is a one-time step for each shop; subsequent checkout additions and revocations
update the same canvas. Changes to a checkout holder's membership status or
expiration also queue updates for every shop where that member has a current
checkout, so renewals and revocations are reflected without another checkout
event.

When a canvas is first created, the portal collects the linked Slack IDs for
all admins, board members, and Resource Managers assigned to that shop and
grants those users `owner` access with `canvases.access.set`. Members without a
linked Slack ID are skipped. Assigning an RM to a shop updates all cached
reservation, volunteer, and checkout canvases to `owner` access; removing that
shop assignment changes the member's access on those canvases to `read`.

The **Reservation Canvas Rebuild** automated job is available beside
**Database Backup** under Admin Settings → Jobs. It runs the
`reservations:rebuild_slack_canvases` rake task through
`ReservationSlackCanvasRebuildJob`, records its last-run status, and can be
started with **Run Now**. In addition to the reservation and volunteer canvas
work, it rebuilds every checkout canvas whose ID is recorded on a shop. A
checkout canvas failure is posted as a warning in the interface-log Slack
channel and stored in the audit log, then processing continues with the next
shop. The job can also be invoked directly with:

```sh
bundle exec rake reservations:rebuild_slack_canvases
```

For every shop with `canvas_today` or `canvas_tomorrow` stored in MongoDB, the
task rebuilds both the current-day and next-day agendas in
`America/New_York` and reapplies the complete admin, board, and assigned-RM
owner list. Schedule this rake task through the same automated-job mechanism
used for **Database Backup**; it is no longer installed as a reservation-specific
cron entry in `config/schedule.rb`.

All Slack API calls used during canvas lookup, creation, sharing, permission
updates, and agenda writing explicitly catch HTTP 429 responses. The operation
waits for the number of seconds in Slack's `Retry-After` header before retrying;
retries are bounded so a prolonged Slack outage is still surfaced to logging,
Honeybadger, and the background-job retry mechanism.

Slack static select menus are limited to 100 tools. Shops with more than 100
reservable tools direct members to use the Member Portal.

## Operational checklist

- MongoDB is configured and reachable.
- `REDIS_URL` is configured and reachable.
- Rails web processes and background workers are running.
- Google Calendar API and Admin SDK API are enabled.
- The Google refresh token has both reservation scopes.
- The dedicated Calendar ID and Workspace customer ID are configured.
- Existing Google resources have been reconciled.
- The Slack app is installed with `commands`, `chat:write`, `canvases:write`,
  `channels:read`, and `groups:read`.
- `/reserve` and Interactivity request URLs use the deployed HTTPS host.
- `SLACK_SIGNING_SECRET` and `SLACK_ADMIN_TOKEN` are configured.
- Each Slack-enabled shop has an exact `slack_channel` mapping.
- Test members have linked Slack identities and the required checkouts.

## Public reservation agenda

The public reservation agenda is a read-only view of a shop's reservations over
the next 24 hours. It is intended for wall displays, kiosks, and integrations
that need the same schedule as structured JSON. It does not require a member
session, although deployments can protect it with a shared token.

### Route and representations

The canonical route is:

```text
GET /reservations/agenda
```

HTML is returned by default. JSON clients can either add the `.json` suffix or
negotiate the representation with an `Accept` header:

```text
GET /reservations/agenda.json?shop=Woodshop
GET /reservations/agenda?shop=Woodshop
Accept: application/json
```

### Query parameters

| Parameter | Requirement | Matching and behavior |
| --- | --- | --- |
| `shop` | Required | Case-insensitive exact match of the shop name after surrounding whitespace is removed. Disabled shops do not match. |
| `tool` | Optional | Case-insensitive exact match of a tool name in the selected shop after surrounding whitespace is removed. Disabled tools do not match. |
| `token` | Optional unless protection is configured | Must match the configured reservation token when token protection is enabled. |

Query values must be URL encoded. Compose a single query string with `&` when a
filter and token are both present; do not start a second query string with `?`.
For example, a tool display protected by a token uses:

```text
/reservations/agenda?shop=Woodshop&tool=Table%20Saw&token=REDACTED
```

The application first reads the `reservation_token` portal setting and then
falls back to `RESERVATION_TOKEN`. If either is nonblank, requests must supply
that exact value in `token`; the portal setting takes precedence. If both are
blank, the agenda is openly accessible. Do not place a real token in
screenshots, documentation, analytics, or other public artifacts.

### Agenda behavior

The window begins when the response is generated and ends exactly 24 hours
later. It includes blocking reservations—pending, unpaid, and approved reservations—that
overlap that interval, including reservations already in progress. Cancelled,
denied, and blackout records are not shown.

A shop view includes reservations for the entire shop and its tools. When
`tool` is supplied, the view includes reservations for that tool **and
whole-shop reservations**, because a whole-shop reservation also blocks the
tool.

The HTML tool menu lists enabled, reservable tools in the shop, sorted by name,
and also offers an **Entire shop** view. A tool does not need to be reservable
to be addressed directly by `tool`, but only enabled and reservable tools appear
in that menu. Menu links preserve the selected shop and any supplied token.

JSON returns `shopName`, `toolName`, `generatedAt`, `windowStart`, `windowEnd`,
`upNext`, and `reservations`. Each reservation row includes `title`,
`memberName`, `slackUsername`, `startAt`, `endAt`, `status`,
`reservationScope`, `toolNames`, and `inProgress`.

`upNext` is `null` for an entire-shop view. In a tool view it describes the
earliest reservation whose start is strictly after generation time, or is
`null` if there is none. Consequently, an in-progress reservation can appear in
`reservations` but is never selected as `upNext`. When present, `upNext`
contains `memberName`, `slackUsername`, and `startAt`.

### Errors

Errors use plain text for HTML requests and an `{"error":"..."}` object for
JSON requests.

| Status | Condition |
| ---: | --- |
| `400 Bad Request` | `shop` is absent or blank. |
| `403 Forbidden` | Token protection is configured and `token` is absent or incorrect. |
| `404 Not Found` | The exact enabled shop cannot be found, or the exact enabled tool cannot be found within that shop. |

### Examples

A browser or wall display for an entire shop:

```text
https://portal.example.org/reservations/agenda?shop=Woodshop
```

A protected wall display filtered to a tool (replace the placeholder only in
the display's private configuration):

```text
https://portal.example.org/reservations/agenda?shop=Woodshop&tool=Table%20Saw&token=REDACTED
```

A JSON feed using the suffix:

```sh
curl 'https://portal.example.org/reservations/agenda.json?shop=Woodshop&tool=Table%20Saw&token=REDACTED'
```

A JSON feed using content negotiation:

```sh
curl -H 'Accept: application/json' \
  'https://portal.example.org/reservations/agenda?shop=Woodshop'
```

Agenda rows expose reservation titles, member names, Slack usernames, times,
resources, and statuses. Before using a publicly visible screen or feed,
consider whether this member information is appropriate for its audience and
physically secure the display and its configuration.


## Duration-based reservation fees and full days

Admins, Board members, and the shop's assigned Resource Managers can use **Add
duration-based fee** in the shop/tool editor. Each rule selects an enabled item
from **Shop fees** and specifies a minimum duration and maximum hours per billing
unit, or **Full day**. There is no limit on the number of rules, and overlapping
rules are allowed. The minimum is the eligibility threshold; the maximum is the
size of a repeatable billing unit, not a cap on the reservation's duration.
Only the applicable rule with the longest billing duration applies per resource.
Equal billing durations prefer the higher minimum; exact ties use the first
configured rule. Fees for separately selected tools are added together.

Partial units round up. For example, a $10 rule with a four-hour minimum and
four-hour maximum charges three units ($30) for a twelve-hour reservation.
A $15 Full day rule charges $15 for a one-day full-day booking, taking precedence
over the four-hour rule. Full-day rules apply only to full-day bookings; timed
bookings continue to use the hourly rules. Shorter bookings below every minimum
remain free. Monetary totals are rounded to cents.

Rules and catalog prices are snapshotted for each resource when it is first
included in a reservation. Deleting a duration rule or changing/deleting its
catalog item does not change existing reservations, their fees, or their rule
snapshots. Material edits use those snapshots; adding a different resource uses
that resource's current rules. New reservations use current rules. No migration
is required: Mongoid supplies empty rule arrays and false full-day flags for
existing documents.

### Full-day configuration and booking

**Minimum reservation duration: full day** requires full-day bookings for the
resource. Its maximum must be at least 24 hours and a multiple of 24. The portal
shows **Full day** whenever the selected resources permit at least 24 hours,
forces it on and disables it for resources requiring full days, and replaces the
time and duration controls with start/end date fields. The end date is exclusive:
September 10 through September 11 means all of September 10.

A full day starts at midnight and ends at the following midnight in
`America/New_York`. The start date must be later than today's local date; same-day
full-day bookings are forbidden, including for Board members. Multiple days must
be consecutive complete calendar days. Each counts as 24 nominal hours for fees
and duration limits. At daylight-saving transitions the actual elapsed time is
23 or 25 hours so that midnight boundaries remain correct. Capacity checks and
membership expiration still use the actual instants. These requirements are
validated on the server as well as represented in the portal.

### Confirmation, invoices, and reservation status

The preview response adds `feeLines`, `feeTotal` (the outstanding amount after paid credits), and `feeConfirmation`. The portal
highlights the applicable fees and units. The first submit click displays the
fee warning; the second explicitly approves the amount and saves. A create or
material edit carrying fees must submit the preview's `fee_confirmation` token.
Changing the selected duration/resources or the quoted price requires fresh
confirmation. Clients cannot supply their own price. Slack's existing timed
modal cannot accept charges: use the portal for fee-incurring or full-day
bookings; all server rules also apply to Slack submissions.

The Slack `/reserve` modal retains the initiating command's response target and
requests a `view_closed` event. Submitting or cancelling the modal replaces the
original slash-command acknowledgement with an ephemeral outcome. Outcomes
distinguish cancellation without submission, pending manager approval,
payment-required/unpaid creation, and approved creation. If that response
replacement fails, the application attempts a direct message to the initiating
Slack user. Failure of both notification methods is reported without logging the
private response URL and never rolls back a successfully created reservation or
turns it into a modal validation error.

Outcome delivery is queued before the interaction is acknowledged, so a slow or
unreachable Slack response URL cannot hold the modal submission open past
Slack's interaction deadline or encourage a duplicate submission. The delivery
job also applies short HTTP connection, read, and write timeouts before using
the DM fallback.

The modal collects a start date/time and **Duration**, rather than a separately
entered end time. Timed reservations offer half-hour choices through five hours
and then whole-hour choices through 24 hours, two-hour choices through 48 hours,
and four-hour choices thereafter, capped at Slack's 100-option selector limit.
If any selected resource requires full-day reservations, Duration uses
whole-day choices and the start is midnight in `America/New_York`; advancing the
selected number of local dates preserves midnight boundaries across daylight-
saving transitions. Full-day policy compatibility treats tomorrow as the
earliest possible start. The time picker explicitly declares
`America/New_York`, the date and time defaults advance together when rounding
crosses midnight, and a read-only summary shows the calculated end date/time.

The modal's `alert` block contains only a short, plain-text status within Slack's
200-character alert limit. A separate `mrkdwn` section summarizes the current
selection's effective booking horizon, greatest advance-notice requirement,
same-day prohibition, shortest maximum duration, whole-day and approval
requirements, and checkout prerequisites. When selected resources differ, the
details name each resource alongside the differing rules. Changing between shop
and tool scope or changing selected tools refreshes both this alert and the
available Duration choices from the same shared policy aggregation used by
server-side reservation validation. Validation errors are returned beside the
title, date, time, resource, or duration input that caused them; broader failures
rebuild the modal with an error alert.

The initial view and every policy refresh also preview any fee implied by the
selected resources, start, and duration. A positive preview names the fee lines,
shows the estimated total, and directs the member to the Member Portal, where
the fee-confirmation workflow is available; Slack does not silently submit an
unconfirmed positive fee.

Scope and tool selectors dispatch Block Kit actions with dedicated action IDs.
Each action re-resolves the member, shop, and selected tools from persisted IDs;
stale, disabled, non-reservable, and cross-shop tool IDs are rejected. The
tool selector only lists enabled, reservable tools for which the member meets
pending-member restrictions and every effective checkout prerequisite (including
the tool's own checkout when it is not open access). Board members retain their
server-side prerequisite exemption. The updated view preserves its title, date,
start time, scope, tool selection, and
duration. If a newly added tool lowers the duration limit, Duration is clamped
to the greatest remaining valid choice. Removing all tools, or selecting a set
whose minimum-notice/same-day rules make its earliest start later than the
strictest booking horizon, changes the submit label to **Review selection** and
explains the incompatibility in an error alert and the detailed policy section.
The submit object remains present because Slack requires one when a view has
input blocks. Attempting to submit an incompatible tool set returns an error on
the tools input before creation. Final submission still repeats authoritative
policy validation to cover configuration changes and availability races after
the modal was rendered.

When RM approval is required (including **Reservation requires RM approval** on
any selected resource), the request stays `pending` and saves the member-confirmed
fee snapshot without issuing an invoice or an unpaid-fee Slack notice. Pending
edits update the saved quote; denial or cancellation before approval creates no
invoice. RM approval issues the invoice from that snapshot and changes the
reservation to `unpaid`; payment then makes it `approved`. The preview still shows
the fee and requires the member's confirmation before requesting approval.

A charged reservation without an approval requirement creates its invoice at
submission. In both cases, it is a one-off `Invoice` with `resource_class: "fee"`,
the reserving member as its billing resource, and a due date exactly four hours
before the reservation starts. `Reservation.invoice` stores its invoice ID, and
the reservation status is `unpaid`. Unpaid reservations consume capacity and may
be edited/cancelled. `fee_snapshot` records the selected line items;
`fee_rule_snapshot` preserves the available rules and prices. Title-only edits
preserve all billing state.

For material edits requiring renewed approval, billing changes are deferred until
approval; previously issued invoices remain payable. Otherwise an unsettled invoice is adjusted to the revised positive
charge and due date. A payment in progress blocks material edits. Paid amounts
are credited against a revised charge; an increase creates an invoice only for
the difference and archives the prior ID in `previous_invoice_ids`. Reductions
do not automatically refund payments or erase outstanding debt. Cancelling or
denying a reservation likewise leaves its invoice payable. Existing invoices
remain available in billing history.

Invoice settlement/reversal enqueues `ReservationInvoiceSyncJob`. Payment before
the start changes `unpaid` to `approved`, or to `pending` if manager approval is
still required. Manager approval of an unpaid reservation clears the approval
requirement but leaves it unpaid until payment arrives. Cancelled/denied
reservations are never revived by payment. Payment at or after the start cannot
reclaim an unpaid reservation. Calendar, reminder, and applicable shop canvas
syncs run when the status changes.

### Slack notices and overdue debt

`ReservationFeeNotificationJob` sends a direct message with the reservation,
resources, start/end, status, amount, and due date. The returned Slack `ts` is
stored as the string field `notified_at` (it is not a date), and the returned DM
channel is stored in `notified_channel_id`. Subsequent updates first call
`chat.update`; a missing message/channel falls back to a new message. Other Slack
failures propagate for job retry. Notification suppression preferences and
members without linked Slack users are respected.

The existing `reservations:rebuild_slack_canvases` task reconciles unpaid
reservations before rebuilding the agendas. Before the start, overdue invoices
produce an updated warning that the reservation is invalid unless paid before
start. At/after the start, unpaid reservations are cancelled and release capacity;
the message explains the cancellation and the invoice remains unpaid. Rebuild
processing includes unpaid reservations whose start/end dates have already
passed, so missed runs do not strand reservations. A background worker and the
existing recurring canvas rebuild schedule are required.

A member with **any overdue unpaid fee invoice** cannot create or materially edit
a fee-incurring reservation, regardless of role or whether it is created on their
behalf. This includes ordinary shop charges, not just reservation invoices.
Free reservations remain available, subject to the other eligibility rules.
The preview shows the debt warning and disables submission until overdue fee
invoices are cleared. Cancelling a reservation does not clear this restriction.


### Minimum advance notice and same-day bookings

Shop and tool reservation settings include `minimum_advance_notice_hours` (default 2, minimum 0) and `prohibit_same_day_reservations` (default false). Existing resources receive these defaults. For multiple tools, the longest notice and any same-day prohibition apply. Shop settings govern whole-shop reservations; tool settings govern tool reservations.

For ordinary members, the earliest start is the current time plus notice, rounded down to a 30-minute interval: at 17:11 with two hours notice, 19:00 is allowed and 18:30 is rejected. Zero disables advance notice; the existing future-time and interval requirements still apply. Same-day prohibition compares dates in America/New_York. These rules apply on creation and when changing the start time or reserved resources; unchanged-start duration and title edits do not reapply them.

Admin and board actors bypass both settings. Resource managers bypass them only for shops they manage, including tools within those shops, whether booking for themselves or another member. Delegated booking checks the authenticated actor rather than the beneficiary. Preview and submission enforce the same rules. These exemptions do not change the separate full-day future-date requirement.


Approval and denial notifications use the same saved reservation DM as invoice notifications, including reservations without a fee. Messages include the current status, resource, dates and decision note. Approval with an unpaid fee explicitly confirms approval while explaining payment is still required. Braintree payment confirmation reconciles the reservation before updating its DM to show the paid amount. Payment for a cancelled or denied reservation does not reinstate it.

These notifications first call `chat.update` using `notified_at` and `notified_channel_id`. If no message is saved, or Slack reports `message_not_found`, `channel_not_found`, or `cant_update_message`, a new DM is sent and its timestamp/channel replace the saved values. Other Slack errors propagate instead of silently sending duplicate messages. Member direct-notification suppression remains respected.


Reservation creation, approval, denial, cancellation, edits (including title-only edits), and payment-driven status changes queue refreshes of the affected shop's today/tomorrow Slack canvases. Dates use America/New_York and an exclusive reservation end: a booking ending at midnight does not occupy the following day. Edits refresh the union of the saved old and new shop/date targets, so moving a reservation also clears its old canvas rows. Reservations spanning both days refresh both canvases; changes entirely beyond tomorrow require no immediate canvas update. The regular rebuild handles subsequent date rollover.


Moving an existing reservation's start earlier must satisfy the resource's current minimum advance notice and same-day prohibition at the time of the edit. Preview reports a policy violation and saving rejects it without changing the original booking. This applies to both shop and tool reservations; the existing admin/board and managed-shop RM exemptions still apply. An earlier start exactly at the rounded notice cutoff is allowed.


Legacy reservations with no fee-rule snapshot keep an empty saved rule set for every retained shop/tool when materially edited. Adding or switching to a new resource snapshots that resource's current fees, without retroactively charging retained resources. The first material edit persists the explicit empty rules; no data migration is required.


Full-day fee rules take precedence over all hourly rules for full-day bookings, including hourly rules lasting 24 hours or longer. Payment reconciliation resolves the current attached invoice only after locking and reloading the reservation, so settlement of a previous invoice cannot approve a newer unpaid difference charge.

Reservation invoice IDs, fee snapshots, and Slack notification timestamps are serialized only for the reservation owner or an authorized shop manager/admin/board viewer. The member payment endpoint independently requires invoice ownership before entering the payment workflow; management settlement and Braintree callbacks retain their separate authorized paths.


Fee-rule snapshots retain historical resource entries when tools are removed, including explicit fee-free entries for legacy tools. Re-adding a tool reuses its first-inclusion rules and prices. Reconciliation sums paid credit across current and historical invoices; reversing an earlier payment makes an active reservation unpaid if its fee is no longer covered, and repaying before the start restores approval. Reconciliation does not create duplicate debt or revive cancelled reservations.

Member reservation details show approval explanations whenever approval reasons remain, including unpaid rows. Existing full-day reservations retain date-only mode when their resource maximum is subsequently lowered. Resource editors disable adding duration fees until an enabled positive-price fee is loaded, and offer Retry after catalog failures.


The member reservation page groups unpaid bookings with outstanding approval reasons under Pending rather than Upcoming. On edits and RM approval, linked historical unpaid invoices offset the charge before a new difference invoice is created, preventing a reversed charge from being billed twice. If fee application fails during initial reservation creation, callback-free cleanup removes all invoices linked to that new reservation and the reservation itself; retrying therefore does not encounter a blocking partial booking or an extra charge.


Every material edit replaces the accepted fee quote, including replacing it with an empty quote when a pending request becomes free. Later RM approval therefore cannot apply a superseded charge. Difference-invoice creation retains the draft invoice ID and restores the persisted reservation fields on failure (including failures after the reservation write), deleting the new invoice without touching earlier invoices or concurrent Slack message metadata. The same recovery protects invoicing during approval and permits clean retries.


Reservation Slack notifications report the total outstanding balance across all linked unpaid invoices, counting each invoice once and excluding settled invoices. If every linked invoice is settled, they report the total paid. The payment warning and due date use the earliest outstanding invoice due date. Both published Reservation and ReservationAgenda status enums include `unpaid`, including the checked-in Swagger document.


Edits that reuse an unpaid invoice restore its prior amount, due date, and description if reservation persistence fails, along with the reservation fields touched by the edit. This recovery handles errors both before and after the reservation write and permits retry without changing the invoice ID. A historical transaction ID alone no longer blocks edits after reversal: the processing guard uses an active invoice lock and timestamp, matching the invoice claim's 15-minute expiry. Direct payment submission remains protected by reservation shop/member locks.

Payment notifications remain deliverable after a cancelled or denied reservation's shop is deleted. They use the original shop name from the fee snapshot when available, otherwise "Deleted shop", while retaining the existing DM update/fallback behavior.

The published `ReservationPreview` contract includes required `feeLines`, `feeTotal`, and `feeConfirmation` fields, plus optional nullable `feeWarning`. Fee lines expose resource and invoice-option IDs, names, unit hours, quantity, unit price, and line amount. Clients should obtain a fresh preview after changes and submit its opaque token unchanged as `feeConfirmation` for charged creates/material edits. Free previews return an empty fee-line array and zero total.

For deleted tools, payment notifications resolve each selected tool by its current name, then its saved fee-snapshot name, then "Deleted tool". Historical fee lines for tools no longer selected are not included.

The shared published resource configuration includes minimumAdvanceNoticeHours (default 2, minimum 0), prohibitSameDayReservations, reservationFullDay, and durationFees with invoiceOptionId, minimumHours, maximumHours, and fullDay. Reservation responses publish fullDay and the optional owner/manager billing fields invoice, feeSnapshot, and notifiedAt. Invoice and notification IDs may be null; notifiedAt is a Slack message timestamp string, not a date-time.

Slack group reservation previews include group prerequisites alongside physical
resource prerequisites. Missing checkouts display an error and Review selection;
prerequisite tools are not added to reserved resources or their duration/fee rules.
Board-member overrides match server validation. Switching to whole-shop scope
uses the shop's prerequisites instead of stale group selections.
