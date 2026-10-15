# Repair tickets and independent availability

Ticket detail/list projections apply catalog visibility independently of ticket
access: hidden tool/shop IDs, names and availability are redacted for viewers
without catalog access, including historical reference changes. Authorized
admins and scoped RMs retain catalog metadata; raw records remain available to
the authorization policy. Reporter assignees retain ordinary names/IDs, while
assignment events never associate their identities with the Reporter label.
Revoked and suspended recipients are skipped before repair-ticket Slack DM
lookup, so they do not block the event delivery queue.

Outage authorization uses a tool/shop scope without constructing a ticket or
allocating a ticket number, including rejected requests.

New repair tickets use the integer returned by `Ticket.pull` (the `tickets`
counter sequence) as `_id`. Portal/API links retain string representations;
ticket details, Slack posts and DMs display `#<id>`. Existing ObjectId tickets
and their event/bounty/reward references remain readable without renumbering.
Deploy the mixed-ID backend before the frontend; do not reset the counter in
an existing deployment. Sequence numbers need not be gap-free.

Both `/fix` and `/fix-tickets` use `/slack/commands/fix`. Apply the updated Slack
manifest to register the alias. A matching shop channel name or ID prefills new
reports and the list filter. Input blocks have persistent labels and hints.
`/fix-tickets show` returns an ephemeral list of all authorized nonterminal
tickets, including public tickets, the member's reports, assignments, and
approver scope. In a shop channel it restricts the results and prefixes them
with `Tickets in <SHOP NAME>:`. Pages contain ten tickets; Next/Previous send
another private page and recheck permissions. Detail and form buttons open
authorized modals. No ticket list is posted publicly by this command.

Creation validates catalog visibility inside the reporter transaction. Hidden shops/tools are available only to admins/board or the RM managing their shop, consistently in portal catalogs and Slack suggestions. Ordinary reports may still reference visible out-of-service tools or uncatalogued tools. Existing scoped staff ticket edits remain available.

Assignment events use a neutral Member actor and omit assignee-name deltas in history and Slack delivery, including older stored events. New events omit those deltas at write time. Current assignee lists remain visible; no event labels a named assignee as the reporter. Already delivered Slack messages are not rewritten. Ordinary task claim capabilities retain privileged prerequisite exemptions; linked repair bounties always require prerequisites.

Discussion notes require at least two non-whitespace characters and at most 10000 characters. The portal disables confirmation until valid; the shared service enforces the same rule for portal, Slack, and API submissions, including nonblank notes attached to state changes.

The portal's Default View uses `mode=all`, combining all tickets the current viewer may read (with the existing nonterminal status filter initially selected). Priority, Created, and Last update table headers toggle server-side sorting, reset the page, and preserve the other filters in the URL.

Admins and board members can assign or remove existing Resource Managers while creating/editing a shop in Workshops or Tool Checkouts. `resource_manager_ids` on shop writes replaces this shop's assignments, without changing their roles or other shop assignments; omitted values preserve assignments. The admin-only/board-only options endpoint lists members with the Resource Manager role. Shop responses include `resourceManagers`, and assignment changes are audited.

Successful portal submissions return to the default ticket list, clearing URL filters and pagination and refreshing results. Every terminal transition (resolved, rejected, or withdrawn) stores the closer's member ObjectId in `FixTicket.closed_by_id` and creates a `ticket_closed` audit record in the same transaction. Audit failure rolls back the closure. Reopening clears the current closure attribution; prior audit records remain. Responses expose nullable `closedBy` only when someone other than the reporter closed the ticket. Reporter closures remain labeled Reporter in ordinary audit views, without their identity or request metadata. Legacy tickets without attribution show no closer.

The portal entry is `/fix-tickets`. `/fix new`, `mine`, `assigned`, `queue`, `public`, and a ticket ObjectId open private Slack modals. Both clients use the same service authorization and transitions. Ticket list queries are server-paginated and scoped before filtering.

## Data and privacy

The Bounty Tasks section of `/admin/system-settings` includes `ticket_bounty_max_credit` (default 2), separate from the ordinary task-creation maximum. It limits ticket-to-bounty conversions and is returned as `bountyMaxCredit` in the ticket catalog. Setting edits use the portal audit log. Admin/board edits of existing bounty tasks may set any positive finite credit value without an upper cap; credit changes record actor, task ID/title, and before/after credits in the portal audit log. Existing awarded volunteer credits are not rewritten.

Acknowledged admin reporter reveals also create a general audit record containing the ticket ObjectID, title, and acting admin. No reporter identity, subject, or ticket snapshot containing reporter data is included. The separate restricted reveal record is retained; the reveal response is withheld if the general audit record cannot be saved.

`FixTicketService` requires MongoDB transactions on a replica set. Its reporter write lock participates in the transaction, serializing cap checks, current-role checks, priority insertion, ticket changes, and bounty linkage. Do not run this feature on standalone MongoDB. Use `data:ensure_unique_indexes` before accepting submissions. The admin security settings page exposes `ticket_open_limit` (default 10).

Reporter identity is excluded by explicit presenters unless the submitter chose to show it at creation. Reveal is a separate admin-only acknowledged, no-store action recorded in `fix_ticket_reveals`. Restrict operational collection access and backups accordingly. User-authored text may identify its author. Reporter reward credits are excluded from general credit administration and reviewed through ticket capabilities by a different authorized reviewer.

`Tool.disabled` retains existing Hidden behavior. `Tool.out_of_service` defaults false and is changed separately under the same shop lock used by reservations. Closing tickets does not restore service. Existing reservations and billing remain intact; the outage response identifies affected reservations for staff review.

## Slack delivery

Reporters cannot claim their own linked repair bounties, including privileged reporters. Staff assignment edits preserve bounty-derived assignments; release/rejection removes them while retaining manual grants. Linked release/rejection notifications and canvas refreshes occur only after the ticket/bounty transaction commits. Generic volunteer-task API responses include nullable `ticketId`; source ticket access is independently authorized.

Slack filter dialogs retain selected tool and assignee IDs when changing other filters. Shop-linked bounty creation and automatic cancellation refresh the volunteer canvas after commit. Direct cancellation of a claimed or pending linked bounty is blocked under the ticket transaction lock: release the claim or reject pending work first so claim-derived ticket access is removed by the existing cleanup flow.

Configure the optional `SLACK_TICKETS_CHANNEL` only after testing the destination. Full ticket notes are visible to channel participants, including notes on otherwise private tickets. Human thread replies are not imported. Shop/tool announcements are independently opt-in and contain designated summaries only.

Events and recipients are saved in the mutation transaction. Per-ticket delivery jobs preserve revision order; delivery receipts and pre-send intents are persisted without changing ticket timestamps. Uncertain sends reconcile Slack history by stable client message ID before resending. A history permission or network failure keeps the event pending rather than assuming deletion. Invite the bot to destination channels and grant the history scopes in the manifest. Thread reconciliation must be exercised against the workspace token in staging; missing history access must be resolved before enabling publication.

Run `fix_tickets:recover_deliveries` every ten minutes if using an external scheduler. `config/schedule.rb` includes the equivalent scheduled job. Disabling the central variable stops pending central sends; events created while disabled are not backfilled. Existing roots retain string timestamps, resolved channel IDs, and workspace IDs; a destination change establishes a new root on the next eligible event.

## Deployment order and staging

### Local MongoDB transaction support

Specs needing real transactions are tagged `requires_transactions: true`. Local standalone runs report these examples as skipped/pending; transaction-capable deployments run them normally. CI uses a replica set and `REQUIRE_MONGO_TRANSACTIONS=true`, failing suite startup if transactions are unsupported. Nontransactional tests, including transaction-unavailable regressions, still run everywhere. Connection/authentication errors are not converted into skips. See [MongoDB test setup](testing-mongodb.md) for shared card/repair-ticket policy and parallel database isolation.

A standalone `mongod` cannot execute multi-document transactions. Repair writes return HTTP 503 with a JSON `error` containing the full `TransactionsNotSupported` message and replica-set setup guidance; the portal displays this message and retains the form for retry. Other MongoDB exceptions are not exposed verbatim. There is no nontransactional fallback, because it could leave priorities, bounty publication, and the notification outbox partially saved.

For a local test server, a single-node replica set is sufficient. Stop the existing test `mongod` cleanly, keep its existing data directory, and restart it with its existing options plus `--replSet rs0` (or add `replication.replSetName: rs0` to its MongoDB configuration). Do not start a second process on that directory. Initialize once from `mongosh`:

```javascript
rs.initiate({ _id: "rs0", members: [{ _id: 0, host: "localhost:27017" }] })
```

Wait until `db.hello().isWritablePrimary` returns `true`. For Rails running on the same host, set `MLAB_URI=mongodb://localhost:27017/makerspace_test?replicaSet=rs0`, restart Rails, and run `bundle exec rake data:ensure_unique_indexes`. Preserve your actual database name, credentials, and other URI options. If Rails or MongoDB runs in Docker, use a replica-set member hostname and port reachable from both MongoDB and Rails instead of `localhost`; the URI must use that reachable address too. Single-node configuration provides transactions, not failover redundancy.

### Rollout

1. Deploy additive Rails models, services, indexes, and jobs before exposing the portal and Slack entry points. Run `bundle exec rake data:ensure_unique_indexes` with the deployment database configuration.
2. Purge managed/CDN caches for public shop and tool HTML/JSON. Their new responses require revalidation. Previously fresh browser responses can remain until their original three-day freshness expires. QR SVG caching stays separate.
3. Deploy the portal assets, update Slack command/interactivity URLs from the manifest for the staging host, and verify signatures and workspace identity. Keep publication disabled initially.
4. Exercise role scopes, cap/concurrency, anonymous reward review, bounty claim/release, all four Hidden/out-of-service combinations, public QR-linked pages, and reservation edits in staging.
5. Test central root creation/deletion recovery, uncertain sends, destination changes, full notes, broadcasts, and DMs with staging members. Enable the production publication variable only after these checks pass.

Local verification uses an isolated MongoDB replica set and mocked Slack. `spec/services/fix_ticket*_spec.rb`, `spec/services/tool_availability_spec.rb`, `spec/requests/fix_tickets_spec.rb`, and `spec/api/fix_tickets_spec.rb` cover the domain/API. Regenerate Swagger with `bundle exec rake rswag:specs:swaggerize`. In React, run `npm run typecheck`, `npm run build`, and `node scripts/check_fix_tickets.cjs` for the isolated browser fixture at 320, 600, 900, and 1440 px. Live workspace delivery and staging deployment are operational checks, not performed by these local tests.

Ticket titles and ad-hoc tool names accept ASCII letters, digits, spaces, and `. , _ ( ) / -`. The API rejects other characters on creation or when these fields change. Existing names are not rewritten, and free-form descriptions and notes remain supported.

Linked-bounty claims require the prerequisite tool checkouts even for admins, board members, and RMs. Staff assignment edits retain existing manual grants without converting claim-only grants to manual ones; releasing the claim therefore removes only its derived access. Authenticated ticket, outage, bounty-detail, and system-config operations declare the `_member-interface_session` cookie through the OpenAPI `sessionAuth` scheme. The executable system-config contract documents `security.ticket_open_limit` and its admin-only positive-integer update.

The catalog includes a creation-unavailable reason for deep-linked reporting dialogs. Authenticated bounty detail returns viewer-specific claim/completion capabilities and is not cacheable. Central Slack replies include only state, confirmation, assignments, discussion notes, announcement notes, and bounty activity; edits to unrelated ticket fields are not published. Reusable OpenAPI schemas describe ticket pages/details, capabilities/history, catalog data, reveal results, and affected reservations.

Ticket list reads apply authorization and filters before a page/count `$facet`, then batch-load related records through `FixTicketContext`. This read-only context belongs to one response; write transactions and delivery-time authorization use fresh records. The presenter and policy retain authorization and reporter redaction checks.

Local refactor verification (September 12, 2026) compared identical responses against the previous implementation. For pages of 1/25/100 tickets with three assignees, a hidden tool, bounty, and reward, Mongo reads fell from 17/377/1502 to 7/7/7 for admins and from 30/678/2703 to 7/7/7 for approvers. A separate 10,000-ticket benchmark covering three sorts, three page sizes, and optional shop filtering measured median page/count latency of roughly 31 ms separately versus 15-18 ms with `$facet`. These are local measurements, not production latency guarantees. `fix_ticket_query_spec` guards bounded reads and empty pages; the existing lifecycle, privacy, and delivery specs remain in place.

### Response attribution and repair updates

A viewer who is both reporter and assignee must choose `respond_as` (`reporter`
or `assignee`) when submitting a discussion or transition note. Portal and Slack
forms offer an unselected Respond as choice. Reporter responses remain anonymous;
assignee responses use the ordinary member name without identifying the reporter.
The private event `note_role` preserves that choice; it is not a response field.
Current assignees receive notes and status/confirmation updates, excluding the actor,
with existing deduplication and delivery-time permission/suppression checks.

Linked bounty feeds use the same eligibility predicate as claims: current membership,
a different reporter, and all prerequisites. Ordinary privileged task exemptions remain.
Outage transitions emit `tool_availability_changed` audits with actor, tool ID, and
old/new boolean values after the update succeeds; no-op requests emit no audit.

Workshop bounty eligibility and Slack volunteer task listings use the same claim predicate as the member task feed. The Slack reservation picker excludes out-of-service tools, while server validation still protects against outages occurring after the modal opens.

The Slack settings tab displays and overrides `SLACK_TICKETS_CHANNEL`. Saved `slack_channel_tickets` takes precedence, including a blank value that disables central announcements. Without an override the environment value is used, with no default channel. Both event creation and delivery use this effective value.

Missing optional shop/tool announcement destinations are skipped so recipient DMs
and later outbox events can proceed. Central reply receipts are scoped to workspace,
channel, and root; replacing a deleted root republishes pending event replies and
bounty broadcasts. Legacy receipts are reused only for their original thread.

Pending reporter rewards can be reviewed only while the ticket remains resolved;
reopening leaves the pending credit unissued and hides review controls until resolution.
An active ticket may explicitly replace a cancelled bounty with a new reviewed bounty.
The old task remains cancelled with its source ticket backlink; reopening alone never
reactivates it. Bounty events record their task ID so delayed notifications retain the
correct historical bounty link. Active, claimed, pending, and completed bounty links
cannot be replaced by this action.

Donation Offers (`donation_offer`) default to showing the submitter identity. Portal and Slack creation forms allow an explicit opt-out. The `show_identity` creation choice is persisted; existing tickets stay private and staff category edits do not change that choice. Authorized ticket responses include `reporter` only for visible identities, and Slack details, summaries, and reporter-authored events use that identity.
