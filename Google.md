# Google token

This project uses Google for federated authentication (optional), drive, calendar, and resources.
In the Google Cloud Console API Library, select the project associated with GOOGLE_ID and enable:
* Google Drive API
* Google Docs API
* Google Calendar API
* Admin SDK API


You will need GOOGLE_ID, GOOGLE_SECRET, and GOOGLE_TOKEN to make API calls.
Also include environment secrets  GOOGLE_RESERVATIONS_CALENDAR_ID and optionally GOOGLE_CUSTOMER_ID

## Configure the OAuth consent screen
Under Google Auth Platform → Audience:
* Prefer Internal if the app is only used by your Workspace organization.
* Otherwise add the Workspace administrator as a test user.
* Avoid leaving an external app in Testing for production: those authorizations normally expire after seven days

3. Configure the OAuth client
Open Google Auth Platform → Clients and select the Web application client represented by GOOGLE_ID.
Add this authorized redirect URI:
https://developers.google.com/oauthplayground
If the existing client is not a Web application client, create one. In that case, update both GOOGLE_ID and GOOGLE_SECRET to the new client’s credentials. The refresh token must be generated with that same client ID and secret.
4. Configure OAuth Playground
Open the OAuth 2.0 Playground.
Click the gear icon and configure:
OAuth flow: Server-side
Access type: Offline
Force prompt: Consent Screen
Enable Use your own OAuth credentials
Enter the project’s OAuth client ID and client secret
Google requires offline access to return a refresh token, and forcing consent helps ensure a new refresh token is issued. Google OAuth server flow documentation
5. Authorize all project scopes
Under Step 1, use “Input your own scopes” and enter:
https://www.googleapis.com/auth/drive
https://www.googleapis.com/auth/admin.directory.resource.calendar
https://www.googleapis.com/auth/calendar
Then click Authorize APIs.

Sign in with a Google Workspace administrator or delegated administrator who:
* Can manage buildings and calendar resources.
* Is the data owner of the dedicated reservations calendar. Calendar event labels
  can only be managed by the calendar's data owner; an ACL `owner` role alone is
  insufficient.
* Has access to the Drive folders used by the portal.

Approve all requested permissions.

Exchange the authorization code

In Playground Step 2:
Click Exchange authorization code for tokens.
Copy the resulting Refresh token, not the access token.
Set the environment variables together:

GOOGLE_ID=<the OAuth client ID used in Playground>
GOOGLE_SECRET=<the matching client secret>
GOOGLE_TOKEN=<the new refresh token>
GOOGLE_RESERVATIONS_CALENDAR_ID=<dedicated calendar ID>
GOOGLE_CUSTOMER_ID=my_customer

Treat the client secret and refresh token as production secrets; do not commit them.

7. Restart and reconcile

Restart Rails and the background-job workers, then run:
```
bundle exec rake google_resources:reconcile
```
That task queues Directory resource and Calendar label synchronization for existing
shops and tools. Confirm the worker logs show successful resource creation or
matching and label creation, followed by successful Calendar synchronization when
making a test reservation.

## Editable email and notification templates

The application can export Google Docs as editable message templates. The Rails
service keeps the metadata and content from the last valid export in Redis. A bad,
empty, inaccessible, or unavailable document does not replace that last valid
content. If no valid export has ever been cached, the application uses the ERB or
text fallback compiled into `app/views`.

Set each variable below to a Google document ID (the value between `/d/` and
`/edit` in a Google Docs URL). The OAuth account identified by `GOOGLE_TOKEN` must
have edit permission for Restore default and Populate, and at least view permission
for normal rendering and Refresh. Template controls are available to administrators
under **System Settings → Templates**.

Placeholders use `{{placeholder_name}}`. Every template accepts these common
placeholders in addition to its template-specific placeholders:

`first_name`, `last_name`, `full_name`, `email`, `member_id`, `join_date`,
`expiration_date`, `slack_username`, `slack_id`, `profile_url`, `portal_url`,
`base_url`, and `open_house_schedule`.

For Slack links, keep the mrkdwn structure in the template and substitute the URL
and label separately, for example `<{{profile_url}}|{{full_name}}>`. Do not put a
preformatted Slack link into a single placeholder; separate substitution preserves
the trusted link structure while escaping member-controlled label text.

| Template | Environment variable | Template-specific placeholders |
|---|---|---|
| Password changed email | `EMAIL_PASSWORD_CHANGED_ID` | `member_firstname`, `url` |
| Welcome email | `EMAIL_WELCOME_ID` | `url` |
| Manual-registration welcome email | `EMAIL_WELCOME_MANUAL_ID` | `member_email`, `reset_url` |
| Member registered email | `EMAIL_MEMBER_REGISTERED_ID` | `member_name` |
| New subscription email | `EMAIL_NEW_SUBSCRIPTION_ID` | `member_name`, `friendly_type`, `quantity`, `next_billing_date`, `url` |
| Failed payment email | `EMAIL_FAILED_PAYMENT_ID` | `member_name`, `friendly_type`, `error_status`, `url` |
| Canceled subscription email | `EMAIL_CANCELED_SUBSCRIPTION_ID` | `member_name`, `friendly_type`, `url` |
| Household disbanded email, primary | `EMAIL_HOUSEHOLD_DISBANDED_PRIMARY_ID` | `support_email` |
| Household disbanded email, secondary | `EMAIL_HOUSEHOLD_DISBANDED_SECONDARY_ID` | `primary_member_name`, `support_email` |
| Reservation reminder | `DOC_RESERVATION_REMINDER_ID` | `reservation_title`, `reservation_time`, `resources`, `reservations_url` |
| Volunteer credit awarded | `DOC_VOLUNTEER_CREDIT_AWARDED_ID` | `credit_description`, `credit_value`, `year_total`, `credit_plural` |
| Volunteer discount earned nudge | `DOC_VOLUNTEER_CREDIT_DISCOUNT_EARNED_ID` | none |
| Volunteer discount progress nudge | `DOC_VOLUNTEER_CREDIT_DISCOUNT_PROGRESS_ID` | `credits_needed`, `credit_plural` |
| Volunteer credit reversed | `DOC_VOLUNTEER_CREDIT_REVERSED_ID` | `credit_description`, `credit_value`, `credit_plural`, `reason`, `reversed_by_name` |
| Volunteer Braintree review | `DOC_VOLUNTEER_BRAINTREE_REVIEW_ID` | `reversed_by_name`, `reason` |
| Volunteer discount applied, member | `DOC_VOLUNTEER_DISCOUNT_APPLIED_MEMBER_ID` | `amount`, `billing_cycles` |
| Volunteer discount applied, admin | `DOC_VOLUNTEER_DISCOUNT_APPLIED_ADMIN_ID` | `amount`, `billing_cycles`, `total_cycles`, `discount_description` |
| Volunteer discount without subscription | `DOC_VOLUNTEER_DISCOUNT_NO_SUBSCRIPTION_ID` | none |
| Volunteer discount error | `DOC_VOLUNTEER_DISCOUNT_ERROR_ID` | `error_message` |
| Household disbanded Slack DM, primary | `DOC_HOUSEHOLD_DISBANDED_PRIMARY_ID` | none |
| Household disbanded Slack DM, secondary | `DOC_HOUSEHOLD_DISBANDED_SECONDARY_ID` | `primary_member_name` |
| Household disbanded admin message | `DOC_HOUSEHOLD_DISBANDED_ADMIN_ID` | none |
| Member review orientation | `DOC_MEMBER_REVIEW_ORIENTATION_ID` | none |
| Member review no purchase | `DOC_MEMBER_REVIEW_NO_PURCHASE_ID` | none |
| Member review PayPal migration | `DOC_MEMBER_REVIEW_PAYPAL_ID` | none |
| Member review missing contract | `DOC_MEMBER_REVIEW_MISSING_CONTRACT_ID` | `contract_type`, `document_url` |
| Member review expired rental | `DOC_MEMBER_REVIEW_EXPIRED_RENTAL_ID` | `rental_numbers`, `renewal_url` |

Unknown placeholders make an export invalid, and the prior Redis copy remains in
place. Substitution values and final HTML are sanitized before use. Refresh updates
only the cache. Restore default overwrites a non-empty Google document with the
compiled fallback after an administrator confirms the warning. Populate is offered
only for an effectively empty document. Successful and failed menu actions are sent
to the portal audit log; Google permission errors are returned directly to the UI.
