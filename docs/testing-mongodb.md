# MongoDB transactions in tests

Card assignment/release and repair-ticket mutations use real MongoDB transactions.
CI runs both RSpec and Playwright against MongoDB 7.0 configured as a single-node
replica set. This tests atomicity; it does not test replica failover.

## Local setup with Docker

From the Rails repository in Bash (Linux/macOS, or an appropriate Docker-enabled shell):

```sh
bash scripts/ci/start-mongo.sh
export RAILS_ENV=test
export MLAB_URI='mongodb://localhost:27017/makerspace_test?replicaSet=rs0'
export REQUIRE_MONGO_TRANSACTIONS=true
bundle exec ruby scripts/ci/verify-mongo-transactions.rb
bundle exec parallel_rspec spec/ -n 4
```

The bootstrap requires Docker and GNU `timeout` (on macOS install GNU coreutils
and put its `gnubin` directory on PATH). It creates the disposable container
`makerspace-ci-mongo` bound to local port 27017; it refuses to replace an existing
container or occupied port. It waits at most 60 seconds for connection,
initialization and a writable primary, printing container logs on failure. The
commit/rollback probe fails if transactions do not work and deletes its temporary
probe document. The normal Ruby dependencies, Redis and application environment
are still required. Supply UI assets under `app/assets/builds`; for RSpec only,
CI creates empty `makerspace-react.js` and `makerspace-react.css` stubs. E2E needs
the actual compiled UI. When finished, remove only this disposable container with
`docker rm -f -v makerspace-ci-mongo`.

RSpec workers share the replica set but use separate databases:
`makerspace_test`, `makerspace_test2`, `makerspace_test3`, `makerspace_test4`.
`TEST_ENV_NUMBER` is appended to the database name, preserving `replicaSet`,
`authSource` and other connection options. Parallel runs require an explicit
database name in `MLAB_URI`. DatabaseCleaner continues using deletion, not a
transaction around each example, so application transactions and concurrent
threads remain testable.

## Transaction-dependent examples

Tag examples (or narrowly scoped groups) that execute transactional operations
with `requires_transactions: true`. This includes requests that reach those
operations, even when the expected result is a conflict or not-found response.
Keep lookup, authorization, pre-transaction input validation and mocked
transaction-unavailable regressions untagged. Override inherited metadata with
`requires_transactions: false` where appropriate. Do not mock successful
transactions in integration tests.

With `REQUIRE_MONGO_TRANSACTIONS` absent or other than exact `true`, tagged
examples are pending on standalone MongoDB. Untagged examples still run.
Connection/authentication errors and errors within supported transactions always
fail. Set `REQUIRE_MONGO_TRANSACTIONS=true` to fail suite startup on unsupported
topology before DatabaseCleaner runs. GitHub Actions and CircleCI set it and run
the independent commit/rollback probe; E2E does not load the RSpec hooks.

CircleCI's build job starts its MongoDB 7.0 sidecar with `--replSet rs0 --bind_ip_all`.
After installing the bundle, `scripts/ci/initialize-mongo.rb` connects directly,
initializes the single member at `localhost:27017`, and waits up to 60 seconds for
a writable primary. Initialization failures stop the build and point to the
CircleCI MongoDB service logs. The job then runs the same commit/rollback probe
as GitHub Actions before indexing, integration tests, or RSpec. Its job-level
`MLAB_URI` includes `replicaSet=rs0`; `REQUIRE_MONGO_TRANSACTIONS=true` prevents
transaction-dependent coverage from silently skipping before publication.

Production transaction requirements are unchanged. No nontransactional write
fallback is provided.

Playwright's existing seed task also requires valid Braintree sandbox credentials
(`BT_MERCHANT_ID`, `BT_PUBLIC_KEY`, `BT_PRIVATE_KEY`). CI supplies those secrets;
dummy values are sufficient only for the mocked RSpec suite. `RAILS_DIR` points
Playwright's global setup at the Rails checkout when it runs from the UI directory.

## Implementation validation — 2026-09-26

- The full four-worker run exercised 2,651 examples with zero transaction-capability
  skips and three unrelated pending examples. Its 39 failures came from a local
  generated asset manifest and the host timezone; all 39 passed on targeted rerun
  after removing that manifest and using UTC. No application fixes were needed.
- Focused replica-set coverage passed 115 examples, including card and repair-ticket
  transactions. The expanded card rollback suite passed all 10 examples, including
  failure after actual deletion. Standalone coverage passed the same initial 115
  examples with 58 explicitly transaction-dependent examples pending; strict mode
  failed before running any examples, as intended.
- The independent probe verified real commit/rollback on a replica set and rejected
  standalone MongoDB. The bootstrap's command, initialization failure, 60-second
  timeout and log handling passed a mock-Docker shell harness.
- Local runs used Windows Ruby 3.4, MongoDB 8.0.12 and isolated Redis 8.0.5. The full
  run used the workflow's dummy settings and a reduced BCrypt cost only in an
  ignored local fixture harness. Focused runs also stubbed external Slack delivery.
  CI continues to use MongoDB 7.0 and Redis 7; real Docker startup still needs its
  GitHub Actions run. Local E2E preparation stopped at the existing Braintree seed
  requirement because sandbox credentials were unavailable.
