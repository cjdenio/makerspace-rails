# Reservation read performance

Reservation modal builds and reservation evaluations use a short-lived
`ReservationReadContext`. It shares candidate tools, active checkout IDs,
prerequisite names and invoice options within one operation. It is not stored in
Redis, a session, or Slack private metadata. Create/update evaluation constructs
fresh context inside the existing reservation locks, after the member reload.

Slack selected-tool validation and rendering share the same candidate list.
Fee snapshots accept the already-loaded resources and batch distinct enabled fee
options, while retaining historical snapshots and legacy fee-free rules. Policy
and authorization decisions remain in the existing Ruby services.

## Timing events

The Rails log receives JSON records with `event: "reservation_timing"`, a fixed
`operation`, `resource_count`, `outcome` (`success`, `rejected`, or `error`), and
monotonic `elapsed_ms`. No request payloads or identifiers are included.

Operations:

- `slack_modal_build`: building/rendering a view; during updates this can reuse
  data already fetched by validation.
- `slack_modal_update`: the update handler, including validation and Slack I/O.
- `slack_views_open` and `slack_views_update`: Slack API calls only.
- `reservation_preview`: shared portal preview logic, including response assembly.
- `reservation_evaluate`: the shared evaluator used by previews and locked writes.

Nested timings overlap and must not be summed. A successful evaluation means
validation passed, not that persistence or a later Slack API call succeeded.
These timings do not include HTTP queueing, authentication, or every controller
lookup. Use end-to-end request latency to assess Slack's three-second deadline.

## Reproducing the benchmark

Provide an authorized test database through the existing `MLAB_URI` environment
variable, then run:

```sh
bundle exec rspec spec/benchmarks/reservation_reads_spec.rb --tag benchmark --format progress
```

The `benchmark` tag is excluded by default in `spec_helper`, including when CI
discovers the file through `parallel_rspec spec/ -n 4`. Naming the file alone
does not opt in; the explicit `--tag benchmark` flag is required. The ordinary
query-count regression specs remain part of the default suite.

This uses the normal test suite's database safety check and DatabaseCleaner:
the test database is cleared. Do not run concurrently with other tests against
the same database. Do not commit connection credentials.

The benchmark uses 1, 25, and 100 selected tools with a shared prerequisite and
fee option, a current ordinary member, and active checkouts. Each operation has
one warm-up followed by ten measurements. Fixture creation is outside the timed
region. Mongo driver monitoring counts actual read commands, including `getMore`,
and records database command duration without retaining command payloads.

`RESERVATION_BENCHMARK` lines report read counts, collection breakdowns, elapsed
and database p50/p95 milliseconds. Percentiles use nearest rank; with ten samples
p95 is the maximum. Slack API calls are mocked; the portal measurement invokes
the shared preview service, excluding HTTP/authentication/serialization overhead.
The dataset contains no existing reservations or blackouts. These are comparative
microbenchmarks, not production latency guarantees.

## Measured comparison (2026-09-17)

Windows, Ruby 3.4, the supplied Atlas `devtest` database; identical fixture sizes
and ten measurements per operation before and after the change (baseline commit
`6bd423bf`). No index changes
were made between runs. Both runs reported the existing missing required tools
unique index in this test database. Network conditions varied between sequential
runs, so use command-count reductions alongside elapsed-time comparisons.

All timing columns are milliseconds, shown as **before → after**.

| Operation | Tools | Read commands | Total p50 | Total p95 | Database p50 | Database p95 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Modal build | 1 | 4 → 4 | 172.1 → 126.4 | 182.9 → 142.2 | 156.0 → 119.6 | 167.7 → 136.0 |
| Modal update | 1 | 8 → 6 | 335.2 → 189.1 | 379.6 → 206.2 | 297.0 → 180.5 | 324.8 → 196.7 |
| Portal preview service | 1 | 13 → 11 | 462.1 → 360.0 | 511.5 → 394.8 | 420.6 → 342.5 | 452.4 → 379.0 |
| Modal build | 25 | 28 → 4 | 1022.8 → 143.0 | 1145.7 → 159.1 | 917.5 → 133.5 | 1016.5 → 148.4 |
| Modal update | 25 | 32 → 6 | 1297.0 → 217.7 | 1378.3 → 239.0 | 1138.9 → 204.3 | 1243.0 → 224.3 |
| Portal preview service | 25 | 61 → 35 | 2410.6 → 1154.1 | 2679.2 → 1200.3 | 2127.4 → 1095.1 | 2327.0 → 1137.7 |
| Modal build | 100 | 105 → 5 | 3853.1 → 218.8 | 4416.6 → 221.1 | 3473.6 → 182.5 | 3932.6 → 191.0 |
| Modal update | 100 | 110 → 7 | 4187.0 → 282.2 | 4541.0 → 295.3 | 3750.6 → 249.6 | 3999.5 → 266.2 |
| Portal preview service | 100 | 212 → 111 | 8240.8 → 3994.7 | 9011.1 → 4253.8 | 7354.6 → 3646.6 | 7963.7 → 3855.1 |

The 100-tool after-change modal reads include one checkout cursor `getMore`.
Each modal build/update now issues one candidate query, one active-checkout query,
one supplemental prerequisite-name query and one fee-option query. Updates also
fetch the shop and member. Portal evaluation reuses its selected tools, needs no
supplemental names for this eligible fixture, and issues one fee-option query.
Its remaining 103 reservation-history/conflict reads at 100 tools explain why
the portal preview still exceeds three seconds in this benchmark. Slack network
latency was not measured; API calls were mocked in both runs.

Validation covered 194 distinct database-backed examples, including the three
benchmark scenarios, plus 15 standalone fee-pricing examples. All passed after
updating the existing interaction mock to accept the request-local context.
Coverage includes query-count bounds, pending/expired/board eligibility, invalid
selections, historical and legacy fees, and checkout revocation/price changes
between preview and lock acquisition.

## Remaining work

The shared evaluator still reads reservation session history per resource.
This change does not redesign history/conflict queries or asynchronous Slack
acknowledgement. Those costs remain visible separately from catalog/fee reads.
No public API contract, collection, environment variable, or recurring job changed.
