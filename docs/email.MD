# Email sent by the Rails interface

<!-- markdownlint-disable MD013 -->

This document inventories email that the Rails application can initiate. “Template” below means the Action Mailer view used to build the message; where an editable Google Doc is supported, the environment-variable name selecting that document is also shown.

## Delivery and suppression rules

- Application mail is sent from `SMTP_FROM` (default `contact@manchestermakerspace.org`). Production delivers through Gmail when `GMAIL_USERNAME` is present, otherwise generic SMTP when `SMTP_USERNAME` is present; without either provider, delivery is disabled. See [the environment-variable inventory](environment-vars.MD) for configuration details.
- Most messages are queued with `deliver_later`. Admin-created-member welcomes use `deliver_now`; the controller therefore waits for that message to be processed.
- A member with direct notifications suppressed (for example a revoked member) receives no mail through `ApplicationMailer`.
- A household secondary does not ordinarily receive `MemberMailer` messages. The password-changed, admin-password-reset, signed-document, and household-disbanded actions are exceptions. Billing and rental messages are not filtered merely because the recipient is a household secondary.
- `silence_emails` suppresses `MarketingMailer` mail, but does **not** suppress transactional member, billing, or rental mail.
- Devise password-reset mail inherits directly from `Devise::Mailer`, rather than `ApplicationMailer`, and consequently does not use the application suppression callback.

## Editable-template behavior

The mailers marked **editable** ask `Service::EmailTemplate` for HTML exported from the Google Doc named by the listed environment variable. A valid export is cached in Redis. If the variable/document is unavailable or invalid, most mailers fall back to their conventional Action Mailer view. The household-disbanded mailer explicitly asks the template service to render its packaged external-template fallback and always sends the result through `shared/google_doc_email`.

Common member and portal placeholders, plus the per-template placeholders listed in `Service::EmailTemplate::TEMPLATE_DEFINITIONS`, are interpolated into editable documents. The subject lines are fixed in Ruby and are not controlled by the Google Doc.

## Signup, account, and membership email

| Circumstance | Recipient and subject | Template |
| --- | --- | --- |
| A visitor submits an email to begin self-registration (`RegistrationsController#new`), or an unused `RegistrationToken` is created. Existing member addresses are rejected by the self-registration endpoint rather than emailed. | The submitted address; **Welcome to Manchester Makerspace!** | **Editable:** `EMAIL_WELCOME_ID` (`welcome_email`). Falls back to `member_mailer/welcome_email`; a packaged default also exists for restoring the external document. |
| The visitor completes self-registration and the pending member record is created. This is a second, distinct signup email and CCs `contact@manchestermakerspace.org`. | New pending member; **Thank you for registering _Full Name_** | **Editable:** `EMAIL_MEMBER_REGISTERED_ID` (`member_registered`). Falls back to `member_mailer/member_registered`. |
| An administrator creates a member. Rails generates and stores a Devise reset token and immediately sends the welcome/set-password link. | New member; **Welcome to Manchester Makerspace!** | **Editable:** `EMAIL_WELCOME_MANUAL_ID` (`welcome_email_manual_register`). Falls back to `member_mailer/welcome_email_manual_register`. |
| An administrator uses “send password reset,” or a member uses the normal Devise password-recovery flow. Devise only sends when its recoverable lookup/validation permits it. | Member; Devise's reset-password subject (normally **Reset password instructions**). | `devise/mailer/reset_password_instructions`; not an editable Google Doc. |
| An administrator directly sets a member's password. This is a notification after the password has already changed, not a reset link. | Member; **Your Manchester Makerspace password has been changed** | **Editable:** `EMAIL_PASSWORD_CHANGED_ID` (`password_changed`). Falls back to `member_mailer/password_changed`. Devise's automatic password-change notification is not enabled, so ordinary password changes do not independently send this message. |
| An authenticated member changes their own password directly. | **No email is sent.** The change is recorded in the audit log only. | None. |
| A member successfully signs the membership contract or rental agreement and the background upload job verifies the document. If a retry finds a Drive file tagged with this upload job's ID, it reads back that archived PDF for the attachment instead of uploading (or rendering) another copy, then sends this message. A same-day file from an earlier signing does not qualify. | Signing member, with the signed PDF attached; **Manchester Makerspace - Signed _Document Type_** | `member_mailer/send_document`; not editable. |
| The weekly/admin-runnable member review actually executes (in production its Rake task proceeds only on Sunday) and finds that a member with a linked Slack identity lacks a signed Member Contract or Rental Agreement. One email is queued for each applicable missing contract. Members without a linked `SlackUser` are included in the management report but are not emailed by this task. | Member missing the contract; **Action Required - Manchester Makerspace** | `member_mailer/request_document`; not editable. The view names the missing `Member Contract` or `Rental Agreement` and links to that member's profile. Normal `ApplicationMailer` notification and household-secondary suppression still applies. |
| A household membership is disbanded. Each former secondary and the primary receive separate transactional messages. | Each affected member; **Manchester Makerspace Household Membership Update** | **Editable:** primary uses `EMAIL_HOUSEHOLD_DISBANDED_PRIMARY_ID`; secondary uses `EMAIL_HOUSEHOLD_DISBANDED_SECONDARY_ID`. Packaged fallbacks are `external_templates/household_disbanded_primary_email` and `external_templates/household_disbanded_secondary_email`, rendered through `shared/google_doc_email`. |
| A first key fob/access card is assigned. | **No email is sent by fob activation itself.** The card activates a pending member, settles already-paid open membership invoices, and queues member provisioning. Any receipt was sent when payment was submitted/processed, rather than when the fob later activates membership. | None. |
| `MembershipExpirationNoticeJob` runs daily and finds an active member with no Braintree subscription (`subscription_id` blank and `subscription` not true, including via a covering household subscription) and no active Earned Membership, whose `expirationTime` falls exactly 3 days out. Existing subscription-driven renewal/failed-payment emails never reach this population, since there's no subscription for Braintree to send a webhook about. | Member; **Your Manchester Makerspace membership expires soon**. A member with a linked `SlackUser` also receives a matching Slack DM. | **Editable:** `EMAIL_MEMBERSHIP_EXPIRING_SOON_ID` (`membership_expiring_soon`), falling back to `external_templates/membership_expiring_soon`, rendered through `shared/google_doc_email`. Sent at most once per expiration (tracked via `membership_expiring_soon_notice_sent_for`, which resets automatically on renewal). The Slack DM text is fixed in Ruby, not the Google Doc. |
| The same job finds a member in the same non-subscribed, non-earned population whose `expirationTime` fell exactly 1 day ago. | Member; **Your Manchester Makerspace membership has expired**. A member with a linked `SlackUser` also receives a matching Slack DM. | **Editable:** `EMAIL_MEMBERSHIP_EXPIRED_ID` (`membership_expired`), falling back to `external_templates/membership_expired`, rendered through `shared/google_doc_email`. Sent at most once per expiration (tracked via `membership_expired_notice_sent_for`). The Slack DM text is fixed in Ruby, not the Google Doc. |

`MemberMailer#contract_updated` (updated code-of-conduct attachment) and `MemberMailer#admin_password_reset` (a legacy custom reset-link message) have conventional views, but there is currently no production call site. `MarketingMailer#request_signup` similarly has a conventional `marketing_mailer/request_signup` view but is currently used only by previews/tests. They must not be treated as automatically sent lifecycle messages unless a production caller is added.

## Payments, subscriptions, refunds, and disputes

| Circumstance | Recipient and subject | Template |
| --- | --- | --- |
| A new Braintree subscription is successfully created for a membership or rental. A receipt is also queued for the initial transaction. | Member; **Subscription to Manchester Makerspace** | **Editable:** `EMAIL_NEW_SUBSCRIPTION_ID` (`new_subscription`), falling back to `billing_mailer/new_subscription`. |
| A one-time transaction is submitted successfully, or a successful subscription-charge/settlement webhook is processed. | Member; **Receipt from Manchester Makerspace** | `billing_mailer/receipt`; not editable. Duplicate webhook handling is designed not to issue an additional receipt. |
| Braintree reports `SubscriptionChargedUnsuccessfully`. This happens on the first failed recurring attempt and again for any later unsuccessful-attempt webhook Braintree sends. Rails does not select a different template based on “first” versus “second” failure. | Member; **Failed payment to Manchester Makerspace** | **Editable:** `EMAIL_FAILED_PAYMENT_ID` (`failed_payment`), falling back to `billing_mailer/failed_payment`. The Braintree transaction status is inserted as `error_status`. |
| Braintree reports `SubscriptionWentPastDue`, commonly after unsuccessful retries. This is a separate event and sends another failed-payment message with `error_status` set to `past_due`. | Member; **Failed payment to Manchester Makerspace** | The same editable/fallback failed-payment template as above. |
| Braintree reports `TransactionSettlementDeclined` for a transaction attached to an invoice. Rails reverses the invoice operation and emails the failure status. | Member; **Failed payment to Manchester Makerspace** | The same editable/fallback failed-payment template as above. |
| Braintree cancels/expires a subscription, including cancellation after repeated payment failures, or application cancellation processing otherwise completes. Rails infers failure-driven cancellation when a last failed transaction was recorded and adds “after repeated failed payment attempts” to the message. | Member; **Canceled Manchester Makerspace Subscription** | **Editable:** `EMAIL_CANCELED_SUBSCRIPTION_ID` (`canceled_subscription`), falling back to `billing_mailer/canceled_subscription`. There is no special cancellation template solely for payment failures. |
| A non-subscription rental invoice is created, or a one-off fee/shop-charge invoice is created. Recurring membership invoices do not send this message. | Member; **Makerspace dues require your attention** | `billing_mailer/new_invoice`; not editable. |
| A member requests a refund. | Member; **Refund Requested for transaction _ID_** | `billing_mailer/refund_requested`; not editable. |
| An administrator successfully processes a refund through the transaction service. | Member; **Refund Approved for transaction _ID_** | `billing_mailer/refund`; not editable. |
| Braintree reports that a dispute was opened, won, or lost for a known invoice transaction. | Member; respectively **Dispute opened/won/lost for payment to Manchester Makerspace** | Respectively `billing_mailer/dispute_requested`, `billing_mailer/dispute_won`, or `billing_mailer/dispute_lost`; none is editable. An unknown transaction produces an operational notification, not member email. |

### Failed-payment sequence

There is no Rails counter that maps attempt one and attempt two to different email bodies. The observable sequence is driven by Braintree webhook kinds:

1. Every charged-unsuccessfully notification sends the normal failed-payment email with that attempt's status.
2. A went-past-due notification sends the same email again, labeled `past_due`.
3. A later canceled/expired notification sends the canceled-subscription email. If an unsuccessful attempt was previously recorded on the invoice, the cancellation text identifies repeated failed attempts as the reason.

The exact number of emails before cancellation therefore depends on which webhook events Braintree emits and delivers, rather than on an application rule such as “first failure template / second failure template.”

## Rental workflow email

| Circumstance | Recipient and subject | Template |
| --- | --- | --- |
| A member submits a rental request requiring approval. | `contact@manchestermakerspace.org`; **Rental Request Pending Approval — _Member_ / _Spot_** | `rental_mailer/rental_request_pending`. This operational email is not addressed to the member. |
| An administrator approves a rental request. | Member; **Your Rental Request Has Been Approved — Manchester Makerspace** | `rental_mailer/rental_request_approved`. |
| A member or administrator claims an available rental directly. | Member; **Rental Claimed — Payment Required — Manchester Makerspace** | `rental_mailer/rental_claimed`. The subsequently created invoice can also generate the new-invoice email documented above. |
| An administrator denies a pending rental request. | Member; **Update on Your Rental Request — Manchester Makerspace** | `rental_mailer/rental_request_denied`. |
| A member schedules cancellation/vacating, or cancellation is scheduled through the rental model. | Member; **Rental Cancellation Confirmation — Manchester Makerspace** | `rental_mailer/rental_vacating`. |
| A member/admin ends a rental, or the recurring vacating check reaches its effective end. | Member; **Your Rental Has Ended — Manchester Makerspace** | `rental_mailer/rental_ended`. |

All rental templates above are conventional Action Mailer HTML views and are not editable Google Docs.

## Not email

Several editable text templates registered beside the email templates—reservation reminders, volunteer-credit notices, member-review notices, and household-disbanded admin notices—are used to compose Slack messages. Their `DOC_*` variables and templates do not imply that Rails sends email for those events.

## Repair tickets

Tickets add no email notifications or email fallback. Ticket notifications are Slack DMs/channel messages. Reporter point nominations remain pending until independent approval; approval invokes existing volunteer-credit notification/accounting behavior with generic “Helpful tool report” text and no source-ticket identity mapping in shared messages.
