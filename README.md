# Makerspace Rails
Application to handle member management at the Manchester Makerspace.  Connects with
key fob system for facility entry and Braintree API for payment processing.

# Development

Use Ruby 3.4 and the Bundler version under `BUNDLED WITH` in
[Gemfile.lock](Gemfile.lock) (currently 4.0.18). From this checkout:

```sh
gem install bundler -v 4.0.18
bundle install
```

Provide MongoDB, Redis, and local environment values using [sample.env](sample.env),
the [environment inventory](docs/environment-vars.MD), and the per-job fixtures in
[GitHub Actions CI](.github/workflows/ci.yml). Keep secrets out of Git. Dummy CI
credentials are for mocked tests; integration flows need appropriate sandbox values.

Set `RAILS_ENV` before boot: [config/application.rb](config/application.rb) explicitly
loads `production.env` in production, `development.env` in development unless
`TEST_MAIL` is present, and `test.env` otherwise. `dotenv-rails` is also installed;
the devcontainer's `.env` file is not the entire environment-loading mechanism.

PowerShell:

```powershell
$env:RAILS_ENV = 'development'
bundle exec rails s -b 127.0.0.1 -p 3002
```

Bash:

```sh
export RAILS_ENV=development
bundle exec rails s -b 127.0.0.1 -p 3002
```

Port 3002 matches React's development proxy. Rails' default server port is 3000;
the Rails-backed E2E workflow instead uses test mode and port 3035. This app uses
Mongoid, not ActiveRecord migrations. See [AGENTS.md](AGENTS.md) for architecture,
setup details, validation, documentation obligations, and coding-tool entry points.

### Wiki URLs

Set `WIKI_URL` to the public wiki base URL, without a required trailing slash:

```env
WIKI_URL=https://wiki.manchestermakerspace.org
```

The React footer uses this runtime value. Shops and tools may store an explicit
Wiki URL. When blank, shop links default to
`<WIKI_URL>/workshops/<slugified-shop-name>` and tool links default to
`<WIKI_URL>/workshops/<slugified-shop-name>#<slugified-tool-name>`. Slugs are
lowercase and punctuation/whitespace are converted to hyphens.

Authenticated members can browse these links at `/workshops`. Disabled shops
are restricted to admins and board members. Hidden tools are shown only to
admins/board, the shop's resource managers, or members with an active checkout
for that tool.

Shops and tools can also store an optional Google Drive folder ID. The workshop
page uses shop IDs for an embedded Documentation tab and tool IDs for links to
their Drive folders.

### Slack public channel cache

Public Slack channel metadata is cached in Redis under
`slack:public_channel:<normalized-name>`. Each value contains the channel ID,
name, topic, and purpose and expires after 3000 hours. Shop/tool and Slack portal
setting saves remove leading `#` characters from channel names. A cache miss
during a channel-name change opportunistically pages through
`conversations.list`, caching every public channel encountered until the
requested name is found.

Refresh the complete public-channel cache manually with:

```sh
bundle exec rake slack:refresh_public_channel_cache
```

`config/schedule.rb` runs this rake task monthly. The configured Slack token
must include permission to list public conversations.

## Development container

There is no root-level Compose file. Existing container configuration lives in
[.devcontainer/devcontainer.json](.devcontainer/devcontainer.json) and
[.devcontainer/docker-compose.yml](.devcontainer/docker-compose.yml). It defines
`web`, MongoDB, and Redis services, mounts this checkout at `/app`, reads root
`.env`, and exposes Rails on port 3000.

This setup requires Docker/Compose (Docker Desktop with an appropriate backend on
Windows), a devcontainer-capable editor if using the JSON entry point, application
environment values, and a populated `ui/` directory with the React checkout.
[dev.Dockerfile](.devcontainer/dev.Dockerfile) runs Yarn from `/app/ui`; it does not
clone React or run `yarn build`. Prepare the complete compiled UI under
`app/assets/builds/` separately. Verify MongoDB transaction readiness and database
selection before tests; the Compose file does not perform the CI replica-set probe.

This describes the existing configuration and its prerequisites, not a verified
one-command quick start. Container/configuration repairs are separate work. For
host development or disposable test services, use the handbook and
[MongoDB test setup](docs/testing-mongodb.md).

# Importing an archived db or Restoring production to development
First dump production to a local backup folder
```
mongodump --uri "<uri for prod db>" -o ./dump
```
Then restore to development server
```
mongorestore --uri "<uri for dev db>" dump/ --drop
```


# Testing
RSpec covers backend models, services, requests/API contracts, and jobs. With the
CI fixture environment, Redis, disposable MongoDB databases, and UI assets ready:

```sh
bundle exec rspec <spec-path>
bundle exec parallel_rspec spec/ -n 4
```

Replace `<spec-path>` with the affected spec file/directory; start focused and
expand for shared behavior, auth/contracts, dependencies, and builds.
See [MongoDB transaction test setup](docs/testing-mongodb.md) for the replica set
and worker databases. Use `REQUIRE_MONGO_TRANSACTIONS=true` and run
`bundle exec ruby scripts/ci/verify-mongo-transactions.rb` to verify real commit
and rollback. Tagged examples pending on standalone MongoDB are not exercised
transaction coverage. RSpec can use CI's empty JS/CSS stubs in `app/assets/builds/`;
the [handbook](AGENTS.md#5-testing-and-completion-criteria) explains safe preparation
without needing a React checkout.

Current [GitHub Actions](.github/workflows/ci.yml) builds React, runs Jest and
four-worker RSpec, checks production asset compilation, and runs Playwright from
the UI checkout. E2E uses complete compiled React assets served by Rails on 3035,
`APP_URL`, absolute `RAILS_DIR`, a verified replica set, Redis, and real Braintree
sandbox credentials. It resets/seeds disposable test data. Follow the
[React handbook](../makerspace-react-2026/AGENTS.md#5-testing-and-completion-criteria)
(or the [React repository](https://github.com/ManchesterMakerspace/makerspace-react-2026))
before running `npx playwright test` in that checkout. `RAILS_CONTAINER` uses its
container environment without automatically forcing test mode.

The older `bundle exec rake integration` task remains in
[lib/tasks/integration.rake](lib/tasks/integration.rake). It fetches a pinned React
commit (overridable through `REACT_COMMIT` with a full SHA), copies selected assets,
resets/seeds data, starts Rails, and invokes `yarn e2e`. The current React manifest
has no `e2e` script; this is not the default local Playwright recipe.
[CircleCI](.circleci/config.yml) still references that integration task; it and
[Travis](.travis.yml) retain older test/publication definitions. Their presence
does not prove those external services or publication flows are active.

For development mail previews, set `RAILS_ENV=development` and `TEST_MAIL=true`
in the launching environment, then run `bundle exec rails s`. This selects the
test environment file for preview data; use disposable data and consult the
[email inventory](docs/email.MD) and environment inventory for delivery settings
and `MAILTRAP_API_TOKEN`. Use `$env:TEST_MAIL = 'true'` in PowerShell or
`export TEST_MAIL=true` in Bash; do not include delivery credentials in source.

# Swagger
For API changes, update executable specs under `spec/api/`, run affected examples,
then regenerate with `bundle exec rake rswag:specs:swaggerize` and include
`swagger/v1/swagger.json`. Start a configured development server with
`bundle exec rails s` and visit `/api-docs` for the interactive specification.
Publishing the separately maintained TypeScript API client is a separate release
workflow; Swagger generation does not publish it.

# Documentation

- [Agent handbook and canonical documentation-maintenance table](AGENTS.md#authoritative-documentation-maintenance-table)
- [Public resources inventory](docs/public-resources.MD)
- [Member statuses](docs/member-statuses.md)
- [MongoDB member-permissions reference](docs/member-permissions.md)
- [Shop and tool reservations](docs/reservations.MD) — includes the public
  `GET /reservations/agenda` display and JSON feed contract.
- [Public rental-spot API](docs/rental-spots.MD) — unauthenticated JSON for QR
  and deep-link experiences.
- [Public volunteer resources](docs/volunteer-public-resources.MD) — bounty feeds
  and the volunteer leaderboard.

# CONTRIBUTIONS

Bug reports and pull requests are welcome on GitHub at https://github.com/ManchesterMakerspace/makerspace-interface. This project is intended to be a safe, welcoming space for collaboration, and contributors are expected to adhere to the Contributor Covenant code of conduct.

Use the current GitHub Actions checks and task-appropriate validation in the
handbook. Keep operational inventories and API specs synchronized with code changes.

# LICENSE

The app is available as open source under the terms of the MIT License.
