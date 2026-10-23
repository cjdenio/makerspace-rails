# Makerspace Rails agent handbook

## 1. Repository purpose and boundaries

Rails manages members, access cards, billing, rentals, workshops, reservations,
volunteering, repair tickets, and integrations. It serves the API, public resources,
and the shell/assets for the separately built React portal.
Use Ruby 3.4 and Bundler from `Gemfile.lock`; start with `bundle install`.
Use disposable test databases. Preserve server authorization, authentication/TOTP/
CSRF, and the documentation obligations in section 4.

This and `makerspace-react-2026` are independent Git checkouts. Inspect
`git status --short`, preserve existing changes, and set an explicit working
directory for each command. Backend-only work does not require a sibling checkout;
RSpec can use the UI stubs described in section 5.
This is the canonical handbook; keep overlapping companion instructions aligned.

| Tool | Entry point |
| --- | --- |
| Codex | Root `AGENTS.md` via [native discovery](https://learn.chatgpt.com/docs/agent-configuration/agents-md). Sessions launched from the enclosing workspace must explicitly read the applicable repository handbook before working there. |
| Claude Code | [CLAUDE.md](CLAUDE.md) imports this file with unquoted `@AGENTS.md`, including for sessions without native AGENTS loading; no symlink is needed. See [memory imports](https://code.claude.com/docs/en/memory). |
| Cursor | Read root `AGENTS.md` directly using [Cursor rules](https://cursor.com/docs/rules); no additional Cursor rules file. |
| GitHub Copilot | [.github/copilot-instructions.md](.github/copilot-instructions.md) summarizes critical rules and directs readers here. Its link is not an automatic import; [support varies by surface](https://docs.github.com/en/copilot/reference/custom-instructions-support). |

## 2. Setup and common commands

Current stack: Ruby 3.4, Rails 8, Mongoid/MongoDB, Redis, and Sprockets serving
compiled React assets. [Gemfile](Gemfile), [Gemfile.lock](Gemfile.lock), and
[GitHub Actions CI](.github/workflows/ci.yml) are command/version references.
The lockfile records Ruby 3.4.5 and Bundler 4.0.18. From this repository root:

```sh
gem install bundler -v 4.0.18
bundle install
```

Recheck `BUNDLED WITH` when the lockfile changes. Keep dependency changes scoped.
MongoDB/Redis must be reachable and application environment values configured before
boot. Start with [sample.env](sample.env), then [environment-vars.MD](docs/environment-vars.MD)
and CI's per-job environment blocks. CI dummy credentials support mocked tests;
they are not working integration secrets.

### Environment selection

[config/application.rb](config/application.rb) explicitly loads `production.env`
for `RAILS_ENV=production`, `development.env` for `RAILS_ENV=development` unless
`TEST_MAIL` is present, and `test.env` otherwise (including development mail preview).
`dotenv-rails` is also installed; `.env` alone is not the complete loading story.
Set `RAILS_ENV` in the launching shell before boot and inspect effective settings
without logging secrets. Ignored environment files stay local.

PowerShell, after configuring development services and environment values:

```powershell
$env:RAILS_ENV = 'development'
bundle exec rails s -b 127.0.0.1 -p 3002
```

Bash equivalent:

```sh
export RAILS_ENV=development
bundle exec rails s -b 127.0.0.1 -p 3002
```

Port 3002 matches React's fixed development proxy; `bundle exec rails s` normally
uses 3000. For Rails-served E2E use test configuration and port 3035 instead.

| Command | Use / prerequisite |
| --- | --- |
| `bundle exec rspec <spec-path>` | Focused RSpec; replace the placeholder with an actual path under `spec/`. |
| `bundle exec parallel_rspec spec/ -n 4` | Full suite with four isolated worker databases; see section 5. |
| `bundle exec ruby scripts/ci/verify-mongo-transactions.rb` | Real commit/rollback probe against a disposable test database. |
| `bundle exec rake rswag:specs:swaggerize` | Regenerate API artifact after updating/running affected executable API specs. |
| `bundle exec rails assets:precompile` | Asset check with production configuration and complete built UI; mirror CI's `compile-production` environment. |
| `git diff --check` | Whitespace validation, including documentation-only work. |

There is no root Compose quick start. The [devcontainer](.devcontainer/devcontainer.json)
uses [.devcontainer/docker-compose.yml](.devcontainer/docker-compose.yml), Docker,
Compose, a root `.env`, and a populated `ui/` checkout expected by its Dockerfile.
It does not provision every secret or verify transaction readiness. See the
qualified [README setup](README.md#development-container); configuration repairs
are separate from documenting what currently exists.

## 3. Architecture and implementation conventions

### Current layout

| Area | Start here |
| --- | --- |
| Routing and requests | [config/routes.rb](config/routes.rb), [app/controllers](app/controllers), controller concerns, [ApplicationController](app/controllers/application_controller.rb). |
| Persistence | [app/models](app/models), [config/mongoid.yml](config/mongoid.yml), model fields/relations/indexes and [collection inventory](docs/mongodb-collections.MD). |
| Output contracts | [app/serializers](app/serializers); presenters such as [fix_ticket_presenter.rb](app/services/fix_ticket_presenter.rb) live in `app/services`. Some controllers render hashes directly. |
| Policies/business operations | [app/services](app/services), including `reservation_policy.rb`, `fix_ticket_policy.rb`, and `card_management.rb`; access helpers also live in controllers/models. |
| Background work | [app/jobs](app/jobs), [app/mailers](app/mailers), templates in `app/views`, [lib/tasks](lib/tasks), and [config/schedule.rb](config/schedule.rb). |
| Integration helpers | [app/helpers](app/helpers), [lib/service](lib/service), and `app/services/service` for payments, Slack, Google, access, and related operations. |
| Tests/API spec | [spec](spec), shared fixtures/helpers in [spec/support](spec/support), executable contracts in [spec/api](spec/api). |
| UI integration | `app/views/layouts/application.html.erb`, `app/assets/config/manifest.js`, `app/assets/builds/`, and [asset configuration](config/initializers/assets.rb). |

Mongoid is the persistence layer. ActiveRecord is disabled; do not assume SQL
migrations, schema files, transactional fixtures, or SQL-backed factories.
Inspect embedded/top-level documents, collection overrides, indexes, and callbacks.
Use operational tasks for index work only when their data effects are part of the
task; a spec is not a production rollout.

### Practices for changes

- Follow local Ruby style/service boundaries. Keep controllers focused on request,
  authorization, and response behavior; reuse domain policies/services.
- Enforce permissions on the server per resource. Preserve shop/tool scope,
  admin/board distinctions, membership eligibility, and public/member visibility.
  React hiding an action or a caller supplying an ID does not authorize a request.
- Preserve Devise cookies, TOTP challenge/enrollment gates, CSRF, and provider auth.
  Test unauthenticated, ordinary-member, privileged, and out-of-scope requests
  when changing access.
- [JSON key transformation](config/initializers/json_param_key_transformer.rb)
  underscores JSON input (preserving `cf-turnstile-response`) and configures
  ActiveModelSerializers with `camel_lower`. Direct hashes/presenters can differ.
  Preserve endpoint-specific envelopes, casing, status/errors, pagination headers,
  and public representations; inspect actual request specs.
- Public `/api/config` values must remain safe to expose. Keep secrets server-side
  and preserve React/native session and configuration contracts.
- Preserve atomic card/ticket operations and failure semantics. Do not replace
  required MongoDB transactions with an unsafe standalone-database fallback.
- Rails 8 gems coexist with older framework defaults in `config/application.rb`.
  Document discrepancies and scope upgrades separately; do not silently change
  application behavior to match generic Rails conventions.

## 4. Task-specific documentation

### Authoritative documentation-maintenance table

Documentation updates are part of implementation, including those required by an
already-authorized task. Apply every relevant row when behavior changes.
This consolidates the obligations formerly repeated in the documentation agent;
[agents/docs-agent.md](agents/docs-agent.md) refers here.

| Change | Required documentation |
| --- | --- |
| Email behavior | Update [email.MD](docs/email.MD) whenever sending code changes: triggers, recipients, subjects, template selection, and fallbacks. |
| Environment variables | Update [environment-vars.MD](docs/environment-vars.MD) for additions, removals, renames, requirements, defaults, and fallbacks in application, configuration, executables, or tasks. |
| Collections or indexes | Update [mongodb-collections.MD](docs/mongodb-collections.MD) for names/overrides, additions/removals/renames/repurposing, lifecycle and index changes; distinguish embedded documents from top-level collections. |
| Public resources | Update [public-resources.MD](docs/public-resources.MD) and linked feature documentation for public/deep-linkable API or rendered routes: additions/removals/renames, methods, authentication, formats, and parameters. |
| Jobs, tasks, or supporting services | Keep [jobs-tasks-services.MD](docs/jobs-tasks-services.MD) in sync in the same change for additions, removals, renames, rescheduling, and other job/task/service changes: admin job inventory, recurring production work, invocation, purpose, side effects, status tracking, and failure behavior. Include synchronous request-time services and supporting modules regardless of directory or namespace, including `lib/` helpers and associated controller concerns/initializer hooks; this obligation is not limited to scheduled work or `app/services/`. Cover every job returned by `GET /api/admin/system_configs` or accepted by `POST /api/admin/system_configs/run_job`, all `config/schedule.rb` work, other tasks identified in source as recurring in production, and manual production commands. |
| Member statuses or permissions | Update [member-statuses.md](docs/member-statuses.md) and/or [member-permissions.md](docs/member-permissions.md) for additions/removals/renames, semantics, and consumers. Maintain the status mutation-path appendix for endpoints, webhooks, callbacks, jobs, tasks, and every path that starts/stops changing an existing member's status. |
| API contracts | Update executable [spec/api](spec/api) specifications for endpoint additions/changes/removals, including routes, authentication/authorization, parameters, request/response bodies, and status codes. Run affected examples, regenerate with `bundle exec rake rswag:specs:swaggerize`, and include [swagger/v1/swagger.json](swagger/v1/swagger.json) in the change. |
| Operator and user instructions (wiki) | When a change adds, removes, or alters a member-, approver-, Resource Manager-, board-, or admin-facing flow or operation (screens, buttons, messages, Slack commands, statuses, permissions, eligibility, notifications, troubleshooting steps), update the matching page in the wiki repository [WikiPages](https://github.com/ManchesterMakerspace/WikiPages) so the flow and operation stay understood. See "Wiki updates" below. |

### Wiki updates

The [WikiPages](https://github.com/ManchesterMakerspace/WikiPages) repository holds
the content of wiki.manchestermakerspace.org (Wiki.js Git storage, bi-directional,
branch `master`). Pages live at their wiki path (for example
`digital-makerspace/approvers/check-out-a-member.md`) with a Wiki.js front matter
header; screenshots are in the repository root as `checkout-<name>.png` and are
linked as `/checkout-<name>.png{width=...}`.

- Treat wiki updates as part of the change. Find the affected pages (search the
  repository for the screen, button, or message names), update them in the same
  piece of work, and add a page when a new flow has none. Describe what the portal
  actually does, using its on-screen labels, and add the member-facing fix to the
  troubleshooting page when a new error or eligibility message is introduced.
- The repository is **public**, and a push to `master` publishes at once. Never put
  real member names, emails, IDs, or credentials in pages or screenshots; use test
  data. Keep drafts and unresolved notes out of `master`.
- `git fetch` first and merge or rebase if the wiki changed, because wiki edits are
  pushed to the repository. Open a pull request, or ask the maintainer before
  pushing to `master`.
- Pages must not describe unreleased behavior as live. If the feature is not yet
  deployed, hold the page or section until it is, and say so in the completion note.
- In completion/PR notes, list the wiki pages changed, or explain why none applied.

Read feature references by task, not as a mandatory full-document sweep:

| Task | References |
| --- | --- |
| Cards/NFC or assignment | [Card assignment](docs/card-assignment.md), [MongoDB tests](docs/testing-mongodb.md), member permissions/statuses above. |
| Checkouts, tools, shops | [Checkout](docs/checkout.MD), [tool groups](docs/tool-groups-validation.MD), [public catalog](docs/public-catalog.md). |
| Reservations/query performance | [Reservations](docs/reservations.MD), [performance](docs/reservation-performance.MD). |
| Repairs/bounties | [Fix tickets](docs/fix-tickets.MD), [volunteer public resources](docs/volunteer-public-resources.MD). |
| Rental links/shortcodes | [Rental spots](docs/rental-spots.MD), [shortcodes](docs/shortcodes.md), [resolution](docs/shortcode-resolution.MD). |

Keep filename casing (`.MD` versus `.md`) exact for Linux. Update this handbook and
Copilot summary together when guidance changes. In completion/PR notes, identify
inventories updated or explain why none applied, and explicitly state whether
the environment-variable inventory changed.

## 5. Testing and completion criteria

Start with `bundle exec rspec <spec-path>` for affected behavior. Expand to related
request/API/service/job examples for shared behavior, authorization, and contracts;
use `bundle exec parallel_rspec spec/ -n 4` for broad changes, dependencies, or
framework/build changes. Asset changes also need the compile check in section 2.
Application suites are unnecessary for a documentation-only edit.

### Test environment and assets

Use the `rspec` CI job's fixtures with Redis and disposable MongoDB data.
[rails_helper.rb](spec/rails_helper.rb) forces test mode; DatabaseCleaner uses
deletion before/after examples, not SQL fixture rollback. Parallel workers use
`TEST_ENV_NUMBER` for separate databases (`makerspace_test`, `makerspace_test2`,
`makerspace_test3`, `makerspace_test4`) through
[TestDatabaseUri](lib/service/test_database_uri.rb), preserving URI options.
Set an explicit test database name in `MLAB_URI`; never point tests at valued data.
Separate runs must not share worker databases. Redis is also required; database
isolation does not imply external-service or Redis isolation.

View-rendering specs need UI assets. For backend-only work without compiled UI,
create CI's two **empty stubs**, preserving existing real assets. PowerShell:

```powershell
New-Item -ItemType Directory -Force -Path app/assets/builds | Out-Null
foreach ($assetName in @('makerspace-react.js', 'makerspace-react.css')) {
  $assetPath = Join-Path 'app/assets/builds' $assetName
  if (-not (Test-Path -LiteralPath $assetPath)) { New-Item -ItemType File -Path $assetPath | Out-Null }
}
```

Bash:

```sh
mkdir -p app/assets/builds
touch app/assets/builds/makerspace-react.js app/assets/builds/makerspace-react.css
```

Stubs are for RSpec only. E2E/production compilation need complete React assets,
including async chunks and nested assets. Stub rendering does not validate the UI.
Check for stale generated manifests/assets if Sprockets fails; keep generated files
out of unrelated changes.

### Transaction coverage

Read [testing-mongodb.md](docs/testing-mongodb.md). CI uses MongoDB 7.0 as a replica
set and Redis 7. In Docker-enabled Bash, `bash scripts/ci/start-mongo.sh` creates
disposable `makerspace-ci-mongo` on port 27017 and initializes `rs0`.
It needs GNU `timeout`; use a consistent WSL/Linux environment on Windows or
provision a replica set separately. It refuses to replace an existing container.

PowerShell settings for an already running local replica set:

```powershell
$env:RAILS_ENV = 'test'
$env:MLAB_URI = 'mongodb://localhost:27017/makerspace_test?replicaSet=rs0'
$env:REDIS_URL = 'redis://localhost:6379/0'
$env:REQUIRE_MONGO_TRANSACTIONS = 'true'
bundle exec ruby scripts/ci/verify-mongo-transactions.rb
```

Bash equivalent:

```sh
export RAILS_ENV=test
export MLAB_URI='mongodb://localhost:27017/makerspace_test?replicaSet=rs0'
export REDIS_URL=redis://localhost:6379/0
export REQUIRE_MONGO_TRANSACTIONS=true
bundle exec ruby scripts/ci/verify-mongo-transactions.rb
```

The probe needs the bundle/exported URI, writes/cleans a temporary document, and
verifies commit/rollback independently of RSpec. Other application settings from
CI/the inventory are still needed for RSpec and Rails boot.
Tag actual transaction-dependent examples with `requires_transactions: true`,
including requests reaching those operations. Leave lookup, authorization,
pre-transaction validation, and mocked transaction-unavailable regressions untagged;
use `requires_transactions: false` to override inherited metadata when appropriate.
Do not mock successful transactions in integration coverage.

Without exact `REQUIRE_MONGO_TRANSACTIONS=true`, tagged examples can be pending on
standalone MongoDB. Strict mode fails suite startup for unsupported topology.
Connection/authentication failures and transaction errors are real failures.
**Pending transaction examples are not exercised coverage.** Report them explicitly.

Finish with changes, checks actually run, failures/unavailable prerequisites,
pending coverage, documentation updates (including environment inventory status),
and companion-repository/release requirements. Documentation-only work needs command,
link/casing, obligation, and companion checks plus `git diff --check`.

## 6. Cross-repository changes

Inspect both checkouts/handbooks for features crossing the boundary. Trace Rails
routes/controllers/policies/serializers/specs through React wrappers, types,
capabilities, and screens. Shared auth needs password/TOTP/session/CSRF tests on
both sides; public resources also need visibility/format tests.
For endpoint changes, follow the API row in section 4 and check UI consumers.
Swagger generation does not publish `makerspace-ts-api-client`:
[lib/tasks/publish.rake](lib/tasks/publish.rake) describes a separate release workflow.
Record required client publication/dependency upgrades and deployment order.

Build React with Node 22/Yarn Classic and `yarn build`, then transfer the complete
`dist/` tree into `app/assets/builds/`. The [React handbook](../makerspace-react-2026/AGENTS.md#6-cross-repository-changes)
provides PowerShell/Bash examples; standalone checkouts can consult the
[React repository](https://github.com/ManchesterMakerspace/makerspace-react-2026).

Current GitHub Actions builds React, runs Jest/RSpec, compiles production assets,
and runs root-config Playwright in the UI checkout. E2E uses Rails on 3035,
`APP_URL=http://localhost:3035`, absolute `RAILS_DIR`, real Braintree sandbox
credentials, disposable seeded data, Redis, and a verified MongoDB replica set.
React global setup runs `bundle exec rake db:db_reset`; `RAILS_CONTAINER` uses its
container's environment without forcing test mode. Follow React's prerequisites
before running `npx playwright test` there.

## 7. Operational constraints and common pitfalls

Tests/builds differ from resets, production jobs, backfills, restores, and publishing.
Read a task's implementation and operational inventory before invoking it.
`db:db_reset` deletes/reseeds data and can interact with Braintree sandbox fixtures;
guards do not replace selecting disposable databases and credentials.
Use appropriate mocks/sandbox services for Slack, mail, Google, billing, and access.
Do not run production jobs or release tasks as routine validation.

The older [integration task](lib/tasks/integration.rake) fetches a pinned React
commit (`REACT_COMMIT` accepts a full SHA override), copies selected assets,
resets/seeds data, starts Rails, and invokes `yarn e2e`. Current React has no such
script. This differs from GitHub Actions Playwright; do not use it as the default
local E2E recipe. [CircleCI](.circleci/config.yml) and [Travis](.travis.yml) remain
historical/alternate definitions with publishing steps; their presence does not
establish that external CI services or automatic publication are active.
Keep unrelated workflow/configuration repairs out of documentation changes.

For an index change, inspect Mongoid definitions and relevant task/model specs,
update the collection inventory, and describe any separately required data rollout.
For a job change, test job/service and failure/idempotency behavior, then apply the
jobs row plus email/environment/status rows as relevant. Neither task requires
a React checkout unless its API or UI behavior changes.
