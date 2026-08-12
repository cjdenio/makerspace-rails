# Shop and Tool Reservations

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
They can edit or cancel their own future pending or approved reservations.

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
- Pending and approved reservations consume capacity.
- Cancelled and denied reservations do not consume capacity.
- A shop-wide reservation conflicts with all tool reservations in that shop.
- A tool reservation conflicts with a shop-wide reservation in that shop.
- Tool capacity is evaluated independently for every selected tool.
- A reservation is pending when any selected resource requires approval.
- A reservation is also pending when its owner already has an overlapping
  pending or approved reservation anywhere.
- Material edits repeat current eligibility and capacity validation and may
  return an approved reservation to pending.
- Configuration changes do not invalidate existing reservations, but new and
  materially edited reservations use the current configuration.
- Shops and tools referenced by future pending or approved reservations cannot
  be deleted.

Reservation writes are serialized with a Redis lock scoped to the shop. If Redis
or locking is unavailable, the request fails safely with a retryable message.

## Reservation statuses

- `pending`: waiting for RM/Admin/Board approval; blocks capacity.
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
replace the agenda with the day's pending and approved reservations. Cancelled
and denied reservations are removed because they do not consume capacity.

Slack does not automatically add these read-only canvases to the shop channel
header. A channel manager must manually add each canvas to the header using the
**+** button.

When a canvas is first created, the portal collects the linked Slack IDs for
all admins, board members, and Resource Managers assigned to that shop and
grants those users `owner` access with `canvases.access.set`. Members without a
linked Slack ID are skipped. Assigning an RM to a shop updates both cached shop
canvases to `owner` access; removing that shop assignment changes the member's
access on both canvases to `read`.

The **Reservation Canvas Rebuild** automated job is available beside
**Database Backup** under Admin Settings → Jobs. It runs the
`reservations:rebuild_slack_canvases` rake task through
`ReservationSlackCanvasRebuildJob`, records its last-run status, and can be
started with **Run Now**. It can also be invoked directly with:

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
later. It includes blocking reservations—pending and approved reservations—that
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
