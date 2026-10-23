# Tool group implementation validation

Validated using the supplied `MLAB_URI` test replica set (`dev_test_rspec`). 
The replica set advertises `mongo:27017`; a temporary,
process-local Ruby socket alias resolved that hostname to the supplied host.
No application database configuration or system DNS was changed.

- 297 distinct Rails examples passed across focused runs, using each example's
  latest result. The final group, concurrency, snapshot, Slack and calendar
  regression pass completed with 89 examples and zero failures.
- Covered group validation and shop/role boundaries, shared naming and tool
  reference guards, revision changes, internal/external prerequisites, open tools,
  partial and revoked checkouts, overlapping requests, transactional rollback,
  retry identity, notification failure, persistent approver grants, volunteering,
  shared credit/reversal, reservation expansion, outages, capacity, snapshots,
  legacy edits, calendar synchronization, and existing fee behavior.
- Concurrent individual/group approvals used independent MongoDB sessions and
  threads with a process-local implementation of the keyed lock contract.
  Redis operations and external Slack/calendar services were mocked; this does
  not constitute a live distributed-lock or external-service acceptance test.
- Ruby syntax passed for 59 changed Ruby files. `rswag:specs:swaggerize`
  regenerated `swagger/v1/swagger.json`; its 857 dry-run examples are schema
  generation, not additional executed API tests.
- React: all 62 Jest suites passed (354 tests). Relevant checkout/reservation
  tests were rerun after final UI changes. `npm run typecheck` passed using the
  repository's configured TypeScript command.
- The actual shared group form passed Chromium checks at 320, 600, 900 and
  1280 pixels: labeled inputs, disjoint selectors, default flags, no horizontal
  overflow and no browser JavaScript errors. Screenshots were visually reviewed.
  The fixture and check script are in the React repository under
  `tests/browser/tool-groups`; this is component browser coverage, not a full
  authenticated portal acceptance run.
- Production web and native web bundles built. Android debug compilation used
  the installed JDK/Android SDK and the configured production API origin.
  Existing webpack warnings about `import.meta.env.BASE_URL` and child
  compilations remain. iOS/device acceptance was not run on Windows.

The Android artifact is in the React repository at
`android/app/build/outputs/apk/debug/app-debug.apk`. Deployment and publication
were not performed. Deploy backend support and run `data:ensure_unique_indexes`
before releasing updated clients. No checkout backfill is required.

## Catalog and signoff follow-up

- Catalog grants now acquire approver locks before the transaction and retain
  them through commit. A deterministic revocation-at-lock-boundary regression
  uses the real test replica set with mocked Redis; distributed Redis contention
  was not exercised.
- Shop deletion removes active and archived groups before their physical tools.
  Both model and authenticated API regressions passed, including surviving-reference
  rejection before deletion.
- 41 distinct Rails examples passed using their latest results across the catalog,
  group checkout, shop model, and tools API runs. React checkout coverage passed
  45 tests in 13 suites, and TypeScript checking passed.
- The mocked Chromium fixture passed at 320, 600, 900, and 1280 pixels for catalog
  filtering, group load failure, keyboard retry, and group-only approver shop
  selection. Narrow and wide screenshots were reviewed. This is component coverage,
  not authenticated portal or physical-device acceptance.
- Service and collection lifecycle inventories were updated. No environment
  variables or API request/response schemas changed in this follow-up.

## Request resolution, dialog recovery, and Slack follow-up

- All-held group requests resolve through the reviewed API revision without new
  checkouts or credit. Dialog catalog failures preserve existing scope selections,
  expose retry, and block submission until loading succeeds.
- Textual group approvals open their signed Slack modal during the command request.
  Local target lookup supports mentions, usernames, and email; missing links have
  email recovery. Slack reservation previews include group prerequisites without
  applying prerequisite tools' resource policies.
- 88 distinct Rails examples passed using their latest results across focused
  group API, Slack controller/job, reservation preview, and identity lookup runs
  against the supplied test replica set. Slack and Redis were mocked.
- Full React suite: 372 tests in 66 suites passed; TypeScript and the production
  web build passed. Existing webpack BASE_URL/child-compilation warnings remain.
- Mocked Chromium checks passed at 320, 600, 900, and 1280 pixels for dialog retry,
  existing scope preservation, group-only shop selection, and request resolution.
  Narrow/wide screenshots were reviewed. Live Slack, device, and authenticated
  portal acceptance were not performed.
- Executable group response schemas now cover CRUD, checkout review, and volunteer
  responses. Checkout, reservation, service, and UI documentation were updated;
  the environment-variable inventory is unchanged.

Swagger was regenerated successfully (865 dry-run examples; not additional
executed tests), and the generated response schema references were checked.

## Deferred notifications and group overview follow-up

- Slack-sourced approvals queue post-commit group delivery, including both modal
  paths, reconciled announcements, and all-held request resolution. Tests cover
  rollback, enqueue failure without synchronous fallback, and repeat approval.
- Group request annotations follow the current shop instructions. Explicit group
  summaries are batched into approver responses and shown separately in the table.
  Group-list retry and automatic recovery clear old load errors.
- 53 distinct Rails examples passed using their latest results on the supplied
  test replica set; Slack and Redis were mocked. Focused React coverage passed
  53 tests in 15 suites, plus TypeScript and mocked browser checks at 320, 600,
  900, and 1280 pixels. Catalog recovery and approver scope screenshots were reviewed.
- Swagger was regenerated (865 dry-run examples, not additional executed tests)
  and its group summary contract checked. Job/service, checkout, and UX docs were
  updated. No environment variables changed. Release the backend response and
  notification worker before the updated group overview UI. Live Slack and
  physical-device acceptance were not performed.

## Scope selection, workshop recovery and notification snapshots

Whole-shop selection clears the shop's individual and group grants. Workshop Add
Tool retries both management catalogs in the same dialog, including rejected
requests. Slack group notification jobs now carry approval-time catalog details
through Active Job serialization; edits before delivery do not change audit or
message content/channels. Existing queued jobs without snapshots retain legacy
lookup behavior, so drain them before editing catalogs during rollout. Deploy the
updated worker before producers enqueue six-argument jobs. No API/client release
is required; the UI fixes may deploy independently. Environment variables and
collection/index schemas are unchanged.

Validation: 27 distinct Rails examples passed across the group checkout, signed
modal and individual/group notification suites using the designated test MongoDB.
Seven focused React examples and TypeScript passed. The mocked Chromium fixture
passed keyboard retry, recovery and overflow checks at 320/600/900/1280 pixels.
Slack calls were mocked; no live Slack or native-device acceptance was performed.

## Slack group request acknowledgement and cancellation

Both request modal paths queue group announcements/requestor DMs through the
existing notification worker after saving. Stateful Slack and portal group edits
and cancellations now share the catalog and constituent checkout locks with
approval and recheck state within them. The API create response documents both
target variants, including the null physical-tool ID for a group.

Validation: the focused workflow/API/Slack interaction run passed 91 examples;
the final API run passed all 15 examples, including two added portal group mutation
cases (93 distinct examples total). Race tests exercised both winning operations
with real MongoDB transactions and process-local keyed locks replacing Redis.
The designated test MongoDB was used. Slack calls were mocked. Swagger was
regenerated from the executable specs; its dry run is not additional test coverage.
Checkout and jobs documentation were updated. Environment variables and collection
schemas are unchanged. Existing portal types already support group fields;
publishing regenerated API-client types remains a separate release step.

## Group request lifecycle and index follow-up — 2026-10-04

All-held Slack approval announcements use the queued approval snapshot for the
approved group's name, constituent names and announcement channel, including after
group edits or destruction. Other reconciled group and individual requests keep
their own announcement details. Group destruction, including shop cascades, shares
archival cleanup: open checkout requests become deleted, open volunteer requests
become revoked, and terminal request history remains stored.

`data:ensure_checkout_indexes` now installs the declared nonunique
`(tool_group_id, status)` checkout-request index. Run
`RAILS_ENV=production bundle exec rake data:ensure_checkout_indexes` during rollout;
the unique-index task does not install this model's indexes. This follow-up needs
no API-client publication or companion UI change.

Validation: 51 focused and related Rails examples passed with no failures or
pending examples using Ruby 3.4.5, MongoDB 7.0 as a disposable replica set, and
Redis 7. Coverage includes serialized delayed announcements after edits/destruction,
other reconciled targets, model and authenticated shop deletion, archival, repeated
index creation and preservation of unrelated indexes, checkout rollback/concurrency,
and existing individual notifications. Slack delivery was mocked; lock-focused
examples used mocked Redis or process-local locks. The independent MongoDB probe
verified commit and rollback. All 11 changed Ruby/Rake files passed syntax checks,
and `git diff --check` passed. Checkout, service/job and collection/index inventories
were updated. The environment-variable inventory and API schemas are unchanged.
Production index installation and live Slack acceptance were not performed.

## Catalog edits and cascade announcements — 2026-10-04

Included-tool membership edits reconcile newly satisfied checkout requests for
the edited group within the catalog transaction. Request holders share approver
locks with revocation, closures reuse existing active checkouts, and no checkout
or volunteer credit is created. Unsatisfied, revoked and unrelated requests remain
open; archival takes precedence over reconciliation. Existing request posts update
after commit with the edited group details and pre-edit announcement channel.

Group destruction captures announced open requests and the group name/channel
before removing the target, then retires their Slack posts after destruction.
Shop cascades use this path. Delivery reloads each request so a resolution that
wins during cleanup preserves its success announcement. Slack failures are
reported without aborting deletion or blocking subsequent request updates.

Validation: 56 distinct focused and related Rails examples passed with no failures
or pending examples, using each example's latest result. Tests used Ruby 3.4.5,
MongoDB 7.0 as a replica set with disposable databases, Redis 7, and mocked Slack calls.
Coverage includes transactional reconciliation and rollback, simultaneous channel
edits, authenticated membership edits and shop deletion, fallback/override channels,
Slack failure isolation, the resolution/deletion boundary, and existing approval
and notification paths. All seven changed Ruby files passed syntax checks, and
`git diff --check` passed. Swagger regeneration succeeded with no artifact changes;
its 929 dry-run examples are schema generation, not executed test coverage.
Checkout, service/job and collection lifecycle inventories were updated. The
environment-variable inventory, collection/index schemas and API response schemas
are unchanged. No companion UI change or API-client publication is required.
Live Slack acceptance and production deployment were not performed.

## Announcement ownership and permission inventory — 2026-10-04

Group batch notifications reuse only a same-group request reconciled by the current
approval. Without one, they send a fresh group announcement and leave historical
request timestamps untouched. A reconciled request without a timestamp receives
the fresh post's timestamp; requests for other groups keep their own updates.
The canonical member-permission inventory now documents explicit group assignments,
durable child-tool grants, assignment/revocation paths, and authorization consumers.

Validation: 26 focused and related Rails examples passed with no failures or
pending examples using Ruby 3.4.5 and MongoDB 7.0 as a disposable replica set.
The notification regressions serialize queued arguments and cover approvals after
adding a child and changing channels, with no current request, an announced or
unannounced same-group request, and an unrelated group's request. Related coverage
includes checkout rollback/concurrency, scope boundaries, revoked assignments,
and volunteer eligibility. Slack calls were mocked; this was not a live Slack or
distributed-lock acceptance test. Both changed Ruby files passed syntax checks,
and `git diff --check` passed. Checkout, service/job, and member-permission
inventories were updated. The environment-variable inventory, collection/index
schemas, and API contracts are unchanged. No companion UI change or API-client
publication is required.
