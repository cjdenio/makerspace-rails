# Makerspace Rails instructions summary

Read [the canonical AGENTS.md](../AGENTS.md) before working. This file is a
self-contained summary, not an automatic import. Copilot support varies by surface.
Update overlapping instructions here whenever the canonical handbook changes.

- Stack: Ruby 3.4, Bundler from `Gemfile.lock`, Rails 8, Mongoid/MongoDB, Redis,
  and compiled React assets. Run `bundle install`. Inspect Git status, preserve
  existing changes, and use explicit working directories. React is independent
  and unnecessary for unrelated backend work.
- Set `RAILS_ENV` before boot. `config/application.rb` selects `production.env`,
  `development.env`, or `test.env`; `TEST_MAIL` affects development loading.
  Consult the environment inventory and CI fixtures. Keep secrets local.
- Use `bundle exec rspec <spec-path>` first, expanding for shared behavior,
  authentication, contracts, dependencies, and builds. Full suite:
  `bundle exec parallel_rspec spec/ -n 4`. Asset integration also needs
  `bundle exec rails assets:precompile` with CI-like configuration and real UI assets.
- Tests require disposable databases, Redis, and UI assets (CI's two empty stubs
  suffice for RSpec only). Mongoid uses deletion cleanup and worker-specific test
  databases, not SQL migrations or ActiveRecord transactional fixtures.
- For transaction coverage use a MongoDB replica set, an explicit test database in
  `MLAB_URI`, and `REQUIRE_MONGO_TRANSACTIONS=true`. Run
  `bundle exec ruby scripts/ci/verify-mongo-transactions.rb`. Tag actual transactional
  examples with `requires_transactions: true`; pending tests are not exercised coverage.
- Preserve server-enforced resource authorization, public/member visibility,
  cookie authentication, TOTP, CSRF, existing JSON key transformations, and
  endpoint-specific serialization. UI visibility does not authorize a request.
- Apply the [authoritative documentation table](../AGENTS.md#authoritative-documentation-maintenance-table)
  for email, environment variables, collections/indexes, public resources,
  jobs/tasks/services, member statuses/permissions, and API contracts.
  Required docs updates belong in implementation, including already-authorized tasks.
- Keep [the job/task/service inventory](../docs/jobs-tasks-services.MD) in sync
  in the same change when adding, changing, renaming, or removing supporting
  services. Include synchronous request-time modules regardless of directory or
  namespace (`lib/` helpers, controller concerns, and initializer hooks), not only
  scheduled jobs or `app/services/`. Document purpose, invocation context, side
  effects, status tracking, and failure behavior.
- For endpoint changes, update executable `spec/api` specs, run affected examples,
  run `bundle exec rake rswag:specs:swaggerize`, and include
  `swagger/v1/swagger.json`. TypeScript client publication is a separate release.
- Data resets, production jobs, backfills, restores, and publishing are not routine
  validation. Use mocks/sandbox services. Rails-backed Playwright needs real
  Braintree sandbox credentials and resets disposable data; `RAILS_CONTAINER`
  does not force test mode. Follow both handbooks for shared changes.
- Documentation-only validation: static command/link/casing checks, companion
  consistency, and `git diff --check`; no application suite is required. Finish with
  changes, actual checks, failures/missing prerequisites, docs/inventory updates
  (explicitly environment-variable inventory status), and companion/release needs.
