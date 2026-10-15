# Environment variables

<!-- markdownlint-disable MD013 -->

This inventory is derived from executable environment access in `app/`,
`config/`, `lib/`, `bin/`, `Rakefile`, and the top-level container/process
files. It describes behavior, not merely the entries in `sample.env`.

“Secret” means the value must not be logged or committed. Google document,
folder, spreadsheet, customer, project, and Slack channel/team IDs are treated
as identifiers rather than credentials. An optional variable can still be
required to use the feature or task named in its purpose.

## Mandatory variables

Checkout Required sheet generation also consumes the existing `APP_DOMAIN`
through `ShortUrl.base_url`. The configured origin takes precedence; absent or
blank configuration uses the validated request authority. Invalid/loopback origins
prevent sheet generation with 503; the UI never substitutes a long URL. This
adds no environment variables and changes no requirements, defaults or fallbacks.

| Variable | Secret? | Development | Test | Production | Purpose | Source |
| --- | --- | --- | --- | --- | --- | --- |
| `APP_DOMAIN` | No | Optional for application/mail URLs; absent uses `http://localhost:${PORT:-3002}`. Public shortcode resolution can use the validated request host. Volunteer reviewer DMs require a valid configured non-loopback domain because their background link builder has no request-host fallback. | Same application/mail and shortcode behavior; reviewer-link tests must provide a valid non-loopback domain. | **Required** by `ENV.fetch`; no default. The image build argument defaults to `members.manchestermakerspace.org`, but that build-time value is not persisted as a runtime variable. | Canonical application/mail URL and allowed host. Public shortcode resolution can fall back to the validated request host when absent/blank. Proposed shop RM review DMs build absolute `/volunteer?task=:id` or `/volunteer?event=:id` links through `ShortUrl.base_url`; missing/invalid configuration makes these background deliveries fail and remain retryable, with no localhost or request-host fallback. | [production config](../config/environments/production.rb), [shortcode resolver](../app/controllers/shortcode_resolutions_controller.rb), [short URL service](../app/services/short_url.rb), [volunteer reviewer notifications](../app/services/volunteer_approver_notification.rb) |
| `MLAB_URI` | Yes | Required for the default Mongoid client; no application default. | Required for the default client; `TEST_ENV_NUMBER` is appended to the database name, preserving URI query options. | Required for the default Mongoid client; no application default. | MongoDB connection URI, including the backup task. It also overrides `mongo.uri` for the checkins extraction tool; that tool needs neither when reading `--input-file`. | [checkins extraction tool](../tools/analysis/checkins-extract.py) |
| `SECRET_KEY_BASE` | Yes | Optional; defaults to the literal development key in `config/secrets.yml`. | Optional; defaults to the literal test key. | Required for secure Rails signing; the configuration supplies no fallback. `SECRET_KEY_BASE_DUMMY=1` is used only while Docker precompiles assets. | Rails cookie/message signing key. | [secrets config](../config/secrets.yml) |

## Optional variables

Unless a row says otherwise, an unset value has the same behavior in
development, test, and production: the named integration or override remains
unconfigured. “No default” means Ruby receives `nil`/an empty string; it does
not imply that the feature will work without the value.

| Variable | Secret? | Development | Test | Production | Purpose | Source |
| --- | --- | --- | --- | --- | --- | --- |
| `BACKUPS_FOLDER` | No | No default; required when the backup task uploads its archive. | Same. | Same. | Google Drive destination folder for database backups. This is the consumed spelling; `BACKUP_FOLDER` in `sample.env` is not read. | [Google Drive service](../app/services/service/google_drive.rb) |
| `BGCOLOR` | No | No default; absent leaves normal page styling. | Same. | Same. | Legacy HTML body background override. | [application layout](../app/views/layouts/application.html.erb) |
| `BT_ENV` | No | No gateway default; absent also marks the UI as development. | Same. | Same; normally `production` for the live gateway/UI label. | Braintree SDK environment. | — |
| `BT_MERCHANT_ID` | No | No default; required for Braintree operations. | Same. | Same. | Braintree merchant identifier. | [Braintree gateway](../lib/service/braintree_gateway.rb) |
| `BT_PRIVATE_KEY` | Yes | No default; required for Braintree operations. | Same. | Same. | Braintree private API key. | [Braintree gateway](../lib/service/braintree_gateway.rb) |
| `BT_PUBLIC_KEY` | No | No default; required for Braintree operations. | Same. | Same. | Braintree public API key. | [Braintree gateway](../lib/service/braintree_gateway.rb) |
| `BUNDLE_GEMFILE` | No | Defaults via `\|\|=` to the repository `Gemfile`. | Same. | Same. | Bundler Gemfile path used by boot and generated executables. | — |
| `CHANNEL_NEW_SIGNUPS` | No | No default; absent gives invitees full-member behavior. | Same. | Same. | Slack signup channel name/ID; when set, invitees start as single-channel guests. | [Slack connector](../lib/service/slack_connector.rb) |
| `CODE_CONDUCT_FOLDER` | No | No default; required by the document workflow. Non-production Google Drive code substitutes `SIGNATURES_FOLDER` for destination IDs. | Same. | No default; used as given. | Destination for signed code-of-conduct documents. | — |
| `CODE_CONDUCT_ID` | No | No default; required by the document workflow. | Same. | Same. | Google Drive source document ID for the code of conduct. | — |
| `CONTRACT_ID` | No | No default; required by the document workflow. | Same. | Same. | Google Drive source document ID for membership contracts. | — |
| `EMAIL`, `MEMBER_ID`, `NAME` | No | No defaults; the member-access Rake task selects the first supplied selector in this order. | Same. | Same. | Select a member for access audit/revocation tasks. | [member-access task](../lib/tasks/member_access.rake) |
| `ENVIRONMENT` | No | Docker build argument defaults to `production`. | Same. | Same. | Sets image `RAILS_ENV` and `RACK_ENV`; it is also an `AppDomainUrl` environment hint if supplied at runtime. | — |
| `FIREBASE_API_KEY` | No | Empty string when absent. | Same. | Same. | Browser Firebase configuration; needed for Firebase sign-in. | [client config](../app/controllers/client_config_controller.rb) |
| `FIREBASE_AUTH_DOMAIN` | No | Defaults to `<FIREBASE_PROJECT_ID>.firebaseapp.com` when project ID is set; otherwise empty. | Same. | Same. | Browser Firebase auth domain. | [client config](../app/controllers/client_config_controller.rb) |
| `FIREBASE_AUTH_TYPE` | No | Defaults to `signInWithPopup`. | Same. | Same. | Browser Firebase authentication method. | [client config](../app/controllers/client_config_controller.rb) |
| `FIREBASE_PROJECT_ID` | No | Empty when absent, disabling usable Firebase configuration. | Same. | Same. | Firebase project used by browser config and server token verification. | — |
| `GDRIVE_INVITES_ENABLED` | No | Enabled only for the exact string `true`; otherwise Drive invite/revoke calls are skipped. | Same. | Same. | Feature flag for Google Drive member permissions. | — |
| `GMAIL_PASSWORD` | Yes | No default; needed with `GMAIL_USERNAME`. | Not read by test mail config. | No default; needed with `GMAIL_USERNAME`. | Gmail SMTP password. | — |
| `GMAIL_USERNAME` | No | Selects Gmail when present (after Mailtrap); absent falls through to generic/local SMTP. | Not read by test mail config. | Selects Gmail when present; absent falls through to generic SMTP or disables delivery. | Gmail SMTP account. | — |
| `GOOGLE_CUSTOMER_ID` | No | Blank or absent defaults to `my_customer`. | Same. | Same. | Google Workspace customer selector. | [Workspace service](../app/services/service/google_workspace.rb) |
| `GOOGLE_ID` | No | No default; required by Google Drive/Workspace features and document/upload tasks. | Same. | Same. | Google OAuth client ID. | — |
| `GOOGLE_RESERVATIONS_CALENDAR_ID` | No | No default. When blank, every reservation still enqueues a calendar-sync job; synchronization raises immediately, is attempted up to five times (the initial attempt plus four retries), and marks the reservation's calendar sync as failed. | Same. | Same. | Google Calendar ID for reservations. It is required for successful synchronization; a missing ID does not skip the sync. | [reservation calendar](../app/services/service/reservation_calendar.rb), [sync job](../app/jobs/reservation_calendar_sync_job.rb) |
| `GOOGLE_SECRET` | Yes | No default; required with the other Google OAuth credentials. | Same. | Same. | Google OAuth client secret. | — |
| `GOOGLE_TOKEN` | Yes | No default; required with the other Google OAuth credentials. | Same. | Same. | Google OAuth refresh token. | — |
| `GOOGLE_TRANSFER_SHARE` | No | No default; needed when Drive invitations/access management are enabled. | Same. | Same. | Google Drive folder to which members receive writer access. | — |
| `HONEYBADGER_API_KEY` | Yes | No default; absent leaves Honeybadger without an API key. | Same. | Same. | Honeybadger error-reporting credential. | [Honeybadger config](../config/honeybadger.yml) |
| `ITEMS_PER_PAGE` | No | Unset, blank, nonnumeric, or less than `2` defaults to `50`; otherwise the positive integer is used. | Same. | Same. | Default pagination size. | [pagination concern](../app/controllers/concerns/fast_query.rb) |
| `LOG_TESTS` | No | Not read. | Unset keeps the normal test logger; `true` logs to stdout, any other nonempty value is a log-file path. | Not read. | Test logging destination. | [test config](../config/environments/test.rb) |
| `MAILTRAP_ACCOUNT_ID` | No | Mailtrap is selected only when this and `MAILTRAP_API_TOKEN` are present. If inbox lookup fails, the error is logged; Gmail and generic SMTP are **not** selected afterward. | Not read. | Not read. | Mailtrap account used to discover an inbox. | [development config](../config/environments/development.rb) |
| `MAILTRAP_API_TOKEN` | Yes | Required with the account ID to select Mailtrap; no default. If inbox lookup fails, the error is logged and execution does **not** fall through to another mail provider. | Not read. | Not read. | Mailtrap API credential. | [development config](../config/environments/development.rb) |
| `MAILTRAP_WEBHOOK_SIGNATURE` | Yes | Unset or blank disables signature validation, so unsigned webhook payloads are accepted and processed. | Same. | Same. | Mailtrap webhook signing secret; set it to require valid signatures. | [Mailtrap controller](../app/controllers/mailtrap_controller.rb) |
| `MEMBER_CONTRACT_FOLDER` | No | No default; required by the document workflow, with `SIGNATURES_FOLDER` substituted as the non-production destination. | Same. | No default; used as given. | Destination for signed membership contracts. | — |
| `NODE_ENV` | No | Webpack executables set it to `development` with `\|\|=`. | Same when those executables run. | Same unless supplied. | JavaScript build environment. | — |
| `NPM_TOKEN` | Yes | No default; required only by the publish task's npm step. | Same. | Same. | npm publishing credential interpolated by the shell. | [publish task](../lib/tasks/publish.rake) |
| `OPEN_HOUSE_SCHEDULE` | No | No default; produces a blank external-template placeholder. | Same. | Same. | Text supplied to email-template `open_house_schedule`. | [email template](../lib/service/email_template.rb) |
| `OTP_SECRET_KEY` | Yes | No default or credentials fallback; TOTP encryption/decryption raises when absent. | Same. | Same. | TOTP encryption key, decoded from Base64 and truncated to 32 bytes. | [TOTP service](../app/services/totp_service.rb) |
| `PASSPHRASE` | Yes | No default; required by the publish task. | Same. | Same. | GitHub password/token embedded in authenticated clone URLs. | [publish task](../lib/tasks/publish.rake) |
| `PAYPAL_CLIENT_ID` | No | Defaults to `sandbox_client_id`. | Defaults to `sandbox_client_id`. | No default; required for working live PayPal operations. | PayPal REST client ID. | [PayPal config](../config/paypal.yml) |
| `PAYPAL_SANDBOX` | No | No default. | No default. | Not read by the production PayPal section. | Sandbox payer email address. | [PayPal config](../config/paypal.yml) |
| `PAYPAL_SECRET` | Yes | Defaults to `sandbox_client_secret`. | Defaults to `sandbox_client_secret`. | No default; required for working live PayPal operations. | PayPal REST client secret. | [PayPal config](../config/paypal.yml) |
| `PIDFILE` | No | No pidfile directive when absent. | Same. | Same. | Puma PID file path. | [Puma config](../config/puma.rb) |
| `PORT` | No | Puma defaults to `3000`; Rails development/test URL helpers default to `3002`; Procfile defaults to `3000`. | Same URL-helper and Puma defaults. | Puma/Procfile default to `3000`. | Listening port and local URL-helper port. | — |
| `RACK_ENV` | No | PayPal loader and Procfile default to `development`; webpack uses it as a fallback for `RAILS_ENV`. | No general default outside the launching process. | Docker sets it from `ENVIRONMENT` (whose build default is `production`). | Rack/process environment and an application URL environment hint. | — |
| `RAILS_ENV` | No | Rails tooling normally supplies it; webpack falls back to `RACK_ENV`, then `development`. | Rails test tooling supplies `test`. | Docker sets it from `ENVIRONMENT` (build default `production`). | Rails environment selection and URL environment hint. | — |
| `RAILS_LOG_TO_STDERR` | No | Presence sends Rails logs to stderr and enables error-handler stderr output. | Presence sends Rails logs to stderr. | Only the shared error handler reads it. | stderr logging switch; any present value enables it. | — |
| `RAILS_LOG_TO_STDOUT` | No | Presence sends Rails logs to stdout (and wins after stderr config). | Same. | Presence sends Rails logs to stdout. | stdout logging switch; any present value enables it. | — |
| `RAILS_MAX_THREADS` | No | Defaults to `3`. | Same. | Same. | Puma minimum and maximum thread count. | [Puma config](../config/puma.rb) |
| `RAILS_SERVE_STATIC_FILES` | No | Development already enables public files, so the fallback check normally has no effect. | Test always enables public files. | Presence enables Rails public-file serving; Docker images set it to `true`. | Static-file serving switch. | — |
| `REACT_BRANCH` | No | Docker build argument defaults to `master`. | Same. | Same. | UI repository branch cloned while building the image. | [Dockerfile](../Dockerfile) |
| `REACT_COMMIT` | No | Integration task defaults to `fc1c252d42add1e85f913c19c6df2fb50d8d3d63`. | Same. | Same. | UI commit checked out by the integration Rake task. | [integration task](../lib/tasks/integration.rake) |
| `REACT_REPO_URL` | No | Required Docker build argument; no default. | Same. | Same. | UI Git repository cloned while building the image. | [Dockerfile](../Dockerfile) |
| `REQUIRE_MONGO_TRANSACTIONS` | No | Not used by the application. | Exact `true` fails RSpec suite startup unless MongoDB supports transactions; otherwise tagged examples may skip on standalone. CI sets `true`. | Not used by the application. | Required transaction coverage in CI. | [MongoDB test setup](testing-mongodb.md) |
| `REDIS_URL` | Yes | Initializer/cable defaults to `redis://localhost:6379/0` and `/1`; the Rails cache config passes an absent value through to the store. | Same; parallel tests replace the initializer URI path with `TEST_ENV_NUMBER`. | Same defaults in initializer/cable; production cache config passes an absent value through. | Redis connection for application data, Action Cable, caching, and external templates. | — |
| `RENTAL_AGREEMENT_FOLDER` | No | No default; required by the document workflow, with `SIGNATURES_FOLDER` substituted as the non-production destination. | Same. | No default; used as given. | Destination for signed rental agreements. | — |
| `RENTAL_AGREEMENT_ID` | No | No default; required by the document workflow. | Same. | Same. | Google Drive source document ID for rental agreements. | — |
| `RESERVATION_TOKEN` | Yes | Used only as a fallback when the `reservation_token` SystemConfig value is blank. The endpoints are public only when both values are blank. | Same. | Same. | Optional bearer-like query token protecting reservation agendas; Admin Settings/SystemConfig takes precedence over this environment variable. | [reservation agendas](../app/controllers/reservation_agendas_controller.rb) |
| `RESOURCES_FOLDER` | No | No default; needed when Drive invitations/access management are enabled. | Same. | Same. | Google Drive member-resources folder. | — |
| `SECRET_KEY_BASE_DUMMY` | No | Docker supplies `1` only to the asset-precompile command. | Same. | Same. | Allows Rails asset precompilation without exposing a real production signing key. | [Dockerfile](../Dockerfile) |
| `SIGNATURES_FOLDER` | No | No default; substitutes for each signed-document destination folder. | Same. | Ignored for destination selection. | Safe non-production Google Drive destination. | — |
| `SKIP_EMAILVALIDATION` | No | Presence bypasses email deliverability validation. | Same. | Same. | Email-validation bypass flag. | [email validator](../app/validators/email_deliverability_validator.rb) |
| `SLACK_ADMIN_TOKEN` | Yes | No default; used for privileged Slack calls and as fallback when no bot token exists. | Same. | Same. | Slack user/admin OAuth token. | — |
| `SLACK_BOT_TOKEN` | Yes | No default; preferred for ordinary Slack API calls. | Same. | Same. | Slack bot OAuth token. | [Slack connector](../lib/service/slack_connector.rb) |
| `SLACK_ENV` | No | Anything except `production` redirects new messages to `test_channel` and marks the UI as development. | Same. | Must equal `production` for real channels and production UI labeling. | Slack safety environment. Volunteer reminder receipts retain the returned conversation ID and production/test destination mode; in-place edits and duplicate cleanup use that ID only when the saved mode matches the current mode. | [Slack connector](../lib/service/slack_connector.rb) |
| `SLACK_INVITES_ENABLED` | No | Enabled only for exact `true`; also requires an admin token. | Same. | Same. | Slack member-invitation feature flag. | — |
| `SLACK_PROFILE_STATUS` | No | Blank/absent defaults to `Xf084350PJ8K`. | Same. | Same. | Slack custom-profile field ID synchronized by the profile task/service. | [profile sync](../lib/service/slack_profile_sync.rb) |
| `SLACK_SIGNING_SECRET` | Yes | When blank, slash commands fail open and accept unsigned requests, events fail closed, and interactions accept unsigned requests only in development. | When blank, slash commands fail open and accept unsigned requests, while events and interactions fail closed. | When blank, slash commands fail open and accept unsigned requests, while events and interactions fail closed. Unsigned commands can enqueue checkout or volunteer jobs, so configure this secret in every deployed environment. | Signing secret for Slack command, event, and interaction requests; the three endpoints do not have identical missing-secret behavior. | [commands](../app/controllers/slack/commands_controller.rb), [events](../app/controllers/slack/events_controller.rb), [interactions](../app/controllers/slack/interactions_controller.rb) |
| `SLACK_TEAM_ID` | No | No default; the connector can discover/store the team ID through other flows. | Same. | Same. | Explicit Slack workspace/team ID. | [Slack connector](../lib/service/slack_connector.rb) |
| `SMTP_ADDRESS` | No | No default; used only when `SMTP_USERNAME` selects generic SMTP. | Not read by test mail config. | Same as development. | Generic SMTP host/address. | — |
| `SMTP_FROM` | No | Defaults to `contact@manchestermakerspace.org`. | Same. | Same. | Default sender address for application and Devise mail. | — |
| `SMTP_PASSWORD` | Yes | No default; used only with generic SMTP. | Not read by test mail config. | Same as development. | Generic SMTP password. | — |
| `SMTP_PORT` | No | Defaults to `587` when generic SMTP is selected. | Not read by test mail config. | Same as development. | Generic SMTP port. | — |
| `SMTP_USERNAME` | No | Selects generic SMTP when present after Mailtrap/Gmail; absent falls back to localhost SMTP. | Not read by test mail config. | Selects generic SMTP after Gmail; absent disables production delivery. | Generic SMTP username. | — |
| `TEST_ENV_NUMBER` | No | When present, changes the Redis database path. | Numeric suffix appended to the MongoDB database name (not URI options); also selects the Redis database. | Same Redis behavior if supplied. | Parallel-test database suffix. | — |
| `TEST_MAIL` | No | Presence selects the test mailer path in application/Devise setup. | No special behavior. | No special behavior. | Development mail-testing switch. | — |
| `TURNSTILE_SECRET` | Yes | Unset or blank bypasses verification. When configured, an outer or Faraday timeout also fails open and accepts the registration; other request/response failures fail closed. | Same. | Same. | Cloudflare Turnstile server secret. Configuring it normally enables challenge verification, but registrations are still accepted whenever the verification request times out. | [Turnstile verifier](../app/services/service/turnstile_verifier.rb) |
| `TURNSTILE_SITE_KEY` | No | Empty/blank disables client Turnstile configuration. | Same. | Same. | Public Cloudflare Turnstile site key. | [client config](../app/controllers/client_config_controller.rb) |
| `USERNAME` | No | No default; required by the publish task. | Same. | Same. | GitHub username for authenticated publish-task clones. | [publish task](../lib/tasks/publish.rake) |
| `VOLUNTEER_BOUNTY_TOKEN` | Yes | Defaults to an empty string; relevant only when token protection is enabled. | Same. | Same. | Token protecting volunteer bounty/leaderboard data. | — |
| `VOLUNTEER_BOUNTY_TOKEN_ENABLED` | No | Defaults to `false`; enabled only for exact `true`. | Same. | Same. | Enables volunteer bounty token checks. | — |
| `VOLUNTEER_SPREADSHEET` | No | No default; required for volunteering spreadsheet operations. | Same. | Same. | Google Sheets document ID for volunteer records. | [volunteering Drive service](../lib/service/google_drive/volunteering.rb) |
| `VOLUNTEER_TASK_MAX_CREDIT` | No | Defaults to `2.0`. | Same. | Same. | Maximum credit assigned to a volunteer task. | [volunteer task model](../app/models/volunteer_task.rb) |
| `WIKI_URL` | No | Blank/absent defaults to `https://wiki.manchestermakerspace.org`; trailing slashes are removed. | Same. | Same. | Public wiki base URL. | [wiki URL builder](../app/services/wiki_url_builder.rb) |

### External email-template document IDs

The following optional, non-secret Google document IDs are looked up
dynamically through `ENV[env_key]` from
[`TEMPLATE_ENV_KEYS`](../lib/service/email_template.rb). Each has no default.
It is required only when its named externally editable template is refreshed,
rendered without a cached copy, populated, or restored. Callers that request a
fallback can use the repository template when retrieval fails.

| Variable | Variable | Variable |
| --- | --- | --- |
| `EMAIL_PASSWORD_CHANGED_ID` | `EMAIL_WELCOME_ID` | `EMAIL_WELCOME_MANUAL_ID` |
| `EMAIL_MEMBER_REGISTERED_ID` | `EMAIL_NEW_SUBSCRIPTION_ID` | `EMAIL_FAILED_PAYMENT_ID` |
| `EMAIL_CANCELED_SUBSCRIPTION_ID` | `EMAIL_HOUSEHOLD_DISBANDED_PRIMARY_ID` | `EMAIL_HOUSEHOLD_DISBANDED_SECONDARY_ID` |
| `DOC_RESERVATION_REMINDER_ID` | `DOC_VOLUNTEER_CREDIT_AWARDED_ID` | `DOC_VOLUNTEER_CREDIT_DISCOUNT_EARNED_ID` |
| `DOC_VOLUNTEER_CREDIT_DISCOUNT_PROGRESS_ID` | `DOC_VOLUNTEER_CREDIT_REVERSED_ID` | `DOC_VOLUNTEER_BRAINTREE_REVIEW_ID` |
| `DOC_VOLUNTEER_DISCOUNT_APPLIED_MEMBER_ID` | `DOC_VOLUNTEER_DISCOUNT_APPLIED_ADMIN_ID` | `DOC_VOLUNTEER_DISCOUNT_NO_SUBSCRIPTION_ID` |
| `DOC_VOLUNTEER_DISCOUNT_ERROR_ID` | `DOC_HOUSEHOLD_DISBANDED_PRIMARY_ID` | `DOC_HOUSEHOLD_DISBANDED_SECONDARY_ID` |
| `DOC_HOUSEHOLD_DISBANDED_ADMIN_ID` | `DOC_MEMBER_REVIEW_ORIENTATION_ID` | `DOC_MEMBER_REVIEW_NO_PURCHASE_ID` |
| `DOC_MEMBER_REVIEW_PAYPAL_ID` | `DOC_MEMBER_REVIEW_MISSING_CONTRACT_ID` | `DOC_MEMBER_REVIEW_EXPIRED_RENTAL_ID` |
| `EMAIL_MEMBERSHIP_EXPIRING_SOON_ID` | `EMAIL_MEMBERSHIP_EXPIRED_ID` | |

Comment-only environment examples are intentionally excluded because
executable code does not retrieve them.

## Repair ticket channel

| Variable | Secret | Required/default | Behavior |
| --- | --- | --- | --- |
| `SLACK_TICKETS_CHANNEL` | No | Optional; blank disables central publication | Initial channel ID or name, overridable under System settings → Slack (stored as `slack_channel_tickets`). A saved blank override disables publication even when this environment variable is set; no default channel is used. Channel for every new ticket and threaded updates, including full notes. Bounties broadcast replies. Independent of public visibility and per-ticket shop announcements. Bot must be able to post/read its messages. Existing `SLACK_ENV` development redirection applies. |

`ticket_open_limit` is a positive-integer SystemConfig setting, default 10, editable only by admins; it is not an environment variable. /fix always requires SLACK_SIGNING_SECRET, including development.
