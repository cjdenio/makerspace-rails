# Authentication and phone session persistence

## Purpose

Public password and Firebase login endpoints establish Devise member sessions.
Phone users can stay signed in across browser/PWA/native app restarts; desktop
and tablet users retain the configured ordinary session idle timeout.

## Canonical URL

- `POST /api/members/sign_in`: password login or restoration with an empty body.
- `POST /api/auth/firebase_login`: exchange a verified provider token for a session.
- `POST /api/members/totp_sessions`: complete a pending login challenge.
- `POST /api/members/totp/setup` and `POST /api/members/totp/verify`: enroll TOTP.
- `DELETE /api/members/sign_out`: end the session, clear pending authentication,
  and invalidate remember cookies under the existing global logout policy.

The `/login` UI belongs to the companion React repository.

## Audience

Member portal users on browsers, installed PWAs, and Capacitor native applications.
Authentication endpoints are public so users without a session can sign in;
TOTP completion and enrollment require their existing temporary/member session.

## Authentication and token handling

Phone detection recognizes iPhone and Android-with-Mobile user agents, excluding
iPads, tablets, desktops, and unknown clients. Native HTTP sends the WebView user
agent. This is client classification, not hardware attestation: spoofed user agents
cannot be distinguished, and desktop-mode phones receive ordinary sessions.

The server gates cookie creation, restoration, and the idle-timeout exemption.
Devise's initial password hook cannot issue a cookie before TOTP. A phone opt-in
is held in the encrypted session, bound to the member and authenticatable salt,
for at most ten minutes; successful TOTP challenge or required enrollment completes
that pending choice. Failed codes grant no persistent credentials. Cancellation
uses logout; expired challenges, successful replacement authentication, and logout
clear pending choices. Failed login retries preserve the original choice and its
expiry. A successful replacement applies its own choice, including opt-out.
Member eligibility is checked again before TOTP completion.

`remember_for = 2.weeks` and `extend_remember_period = true` renew the window when
Devise restores a session through the remember cookie, not on every request.
Valid phone remember cookies bypass the ordinary idle timeout; opted-out phones
and desktops keep `devise_timeout_minutes` semantics. The ordinary session cookie
is not made persistent. Existing sessions are not automatically upgraded.
Nonempty password-login payloads require fresh credential authentication even
when a member session already exists. Failed password/provider attempts preserve
the browser's existing remember cookie; an authenticated replacement login clears
it before staging the new choice (including opt-out and pending TOTP).
Successful fresh password or provider authentication also discards the previous
account's TOTP challenge and expiry before evaluating the new account's TOTP requirements.
Failed credentials and empty-body restoration do not discard a pending challenge.
The pending-session gate still blocks provider login while the previous member
session is valid; successful provider login clears stale challenge fields left
after that session has been invalidated.

Remember cookies are signed, HttpOnly, SameSite=Lax, and Secure in production.
Password changes/resets and existing `session_token` rotations invalidate the
salt used by remembered credentials. Existing logout behavior invalidates all
remember cookies for that member, including when an ordinary session times out.
CSRF, role permissions, and TOTP access gates remain enforced.

The UI preference cookie `makerspace_stay_logged_in` contains only true/false and
lasts one year. It is not a credential and survives logout. The web cookie uses
path `/`, SameSite=Lax, and Secure on HTTPS. Native clients use Capacitor's cookie
API at the HTTPS portal origin with the same path and expiry. Android's app-owned
bridge sets Secure/SameSite=Lax and reads only preference/CSRF cookies from that
origin; iOS uses Capacitor's URL-aware API and platform cookie attributes.
Clearing browser/app data clears this preference.

## Identifiers and query parameters

Password login accepts `member.email`, `member.password`, and optional boolean
`member.rememberMe`. Firebase accepts `id_token` and optional boolean `rememberMe`.
JSON keys are normalized to snake_case by Rails. Missing choices are false.
TOTP completion accepts `code`; it never accepts a new persistence choice.
These inputs belong in JSON request bodies, not query strings or shareable links.

## Formats

API requests and responses use JSON. The React `/login` route renders the login UI.

## Response and error behavior

Successful login returns the existing member JSON. `202 {"totp_required":true}`
requires code entry; `totp_enrollment_required` on a successful member response
requires enrollment. Neither response issues persistent credentials before its
gate completes. Invalid credentials or expired sessions return 401; invalid TOTP
codes return 422. Provider requests without a token return 400. Executable API
contracts and generated Swagger describe these responses.

## Examples

Password-login request body (with the current session's CSRF header):

```json
{"member":{"email":"member@example.com","password":"example-only","rememberMe":true}}
```

A challenge responds `202 {"totp_required":true}`. Submit `{"code":"123456"}` to
the TOTP endpoint using the same session and current CSRF token. Session restoration
uses `POST /api/members/sign_in` with `{}` and existing cookies.

## Privacy considerations

Never store passwords, provider tokens, or remember credentials in URLs or
localStorage. The preference cookie contains no identity or authentication secret.
Login response member data must not be cached in the service worker. The warning
on the checkbox reminds users to disable persistence on shared devices.

## Operational configuration

Deploy Rails before the companion React web build and rebuilt native applications.
React's handwritten authentication requests carry the optional fields; generated
API client publication is not required. Transfer all web assets, including lazy
chunks, when serving React through Rails.

No new environment variables, collections, indexes, migrations, or backfills are
required. No email triggers or templates change.

## Verification

Run mobile session request specs, password/provider/TOTP/Home regressions, and
affected executable API specs, then regenerate Swagger. The fixture
`spec/fixtures/mobile_session_clients.json` must stay identical to React's
`tests/fixtures/mobile_session_clients.json`. Test restart by retaining only the
remember cookie; cover expiry, renewal, invalidation, and desktop timeout isolation.
Physical Android/iPhone acceptance must include native process restart and provider
callbacks; mocks do not establish real-device cookie persistence.
