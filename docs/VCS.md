# Valley Christian Sign

This fork starts from DocuSeal Community 3.3.4. It adds recipient spreadsheet import, user roles, scheduled email reminders, formulas, conditional-field controls, SMS invitations, phone verification, template creation APIs, and embedded editors. VCS branding uses the September 2026 brand guide. DocuSeal attribution remains in interactive interfaces.

The [modification reference](fork-changes.md) records implementation locations, release history, and configuration limits.

## Internship documents

`/internship` provides account-free intake for the Summer 2027 student/parent MOU, host MOU, and CDE B1-1. Each signer verifies their email. The student signs first, the parent and host sign next, and school staff finish the packet. After the student finishes, the parent can sign on the same device with their own email verification or use the email invitation later. Production assigns both school and work permit issuer responsibilities to Benjamin Mull. Other deployments can assign a separate issuer.

The [internship guide](internship.md) covers field mapping, private document storage, recipient configuration, activation, and isolated verification. Intake accepts no packets until the private configuration is enabled.

## Recipient spreadsheets

Choose **Upload list**, upload CSV or XLSX, and review the rows. Confirm the import to create submissions. Email delivery is an explicit choice at confirmation.

For one role, use `email`, `name`, and optional `phone` columns. Add field names as columns to prefill values. A phone-verified template requires an E.164 `phone` value.

For multiple roles, prefix each column with the role name and a period. For example, `Student.email`, `Student.name`, and `Parent.email` create both recipients for one row.

The limit is 1,000 rows and 5 MB. Duplicate groups and invalid rows block the whole import. XLSX formulas must be replaced with values. Each confirmation creates recipients once. Pending delivery work is retried by the reminder scheduler after an interruption. Upload previews expire after one hour and are removed after two hours when delivery has completed.

## Permissions

Admins manage users, settings, templates, and submissions. Editors create templates and send documents. Viewers read templates and submissions. Every role remains restricted to its account.

## Email and SMS

Configure Resend under **Settings > Email**. The API key is encrypted in the database. A blank API key preserves the saved key. Resend takes precedence over the optional SMTP fallback.

Configure a Twilio account SID, auth token, and E.164 sender under **Settings > SMS**. SMS remains unavailable until these credentials exist. Phone verification is enforced on the server before signing and protected document access.

Email reminders use the intervals saved under **Settings > Notifications**. The deployment runs a scan every five minutes. Completed, declined, archived, and expired submissions are skipped. Sequential recipients are reminded only when their turn is active.

## Formulas

Formulas support field references such as `{{field-uuid}}`, arithmetic operators `+ - * / ^`, parentheses, `round(n, d)`, `abs(n)`, `today()`, and `datedif(start, end, "y")`. Date differences support `y`, `m`, and `d`. Date formulas return an ISO date. Text formulas interpolate field values. The server uses a bounded interpreter and does not execute Ruby or JavaScript.

## Template creation API

Authenticate with the existing `X-Auth-Token` API key. The endpoints are `POST /api/templates/html`, `/api/templates/pdf`, and `/api/templates/docx`.

HTML requests contain `name` and `documents`, where each document has `name` and `html`. PDF and DOCX documents have `name` and `file`, with base64 file content. Requests accept one to ten documents. Each decoded document is limited to 20 MB. HTML input is limited to 2 MB and renders with external resources and scripts blocked. Embed supported images as data URLs.

The fork supports field tags such as `{{Signature;type=signature;role=Signer;required=true}}`. Supported tag types are `text`, `signature`, `initials`, `date`, `number`, and `checkbox`. The tag is removed from the PDF and replaced by an editable field at its location. PDF AcroForm fields are retained when no explicit tags exist. These endpoints do not promise complete compatibility with proprietary upstream Pro APIs.

## Embed forms and editors

Load `/js/docuseal.js` from this service and render `<docuseal-form src="https://sign.valleychristianai.com/s/SUBMITTER_SLUG"></docuseal-form>`. A shared template can use its `/d/TEMPLATE_SLUG` link. The script adds the explicit embed flag.

Signing frames permit the VCS domains by default. Set `VCS_EMBED_ORIGINS` to a space-separated list of additional HTTPS origins when needed. Public signing still uses browser cookies for verification and CSRF protection.

To embed an existing-template editor, call `POST /api/embed_tokens` with `template_id` and an exact HTTPS `origin`. Render `<docuseal-builder src="RETURNED_SRC"></docuseal-builder>`. Mint the token on your backend. Tokens expire after one hour and allow changes only to the specified template. The editor hides account-wide custom fields and send controls. It does not grant account settings access or create a persistent login session.

## Certificates and SSO

The fork supports the existing local signing certificate workflow. A certificate trusted by public PDF readers must come from a trusted certificate authority. This fork does not impersonate DocuSeal's hosted certificate service. SSO remains excluded from this work.

## Verification and deployment

Run `deploy/verify_features.rb` with Rails runner only against an isolated database with `VCS_ISOLATED_TEST=true`. Run `deploy/verify_embedding.rb` the same way. Run `bundle exec ruby deploy/verify_resend_adapter.rb` to verify MIME conversion without sending email.

Build the pinned production image with `docker build -f deploy/Dockerfile.vcs -t valley-docuseal:COMMIT .`. The build compiles frontend assets from this source and adds Chromium for HTML conversion.

Production retains the existing PostgreSQL and document volumes. The service uses immutable release containers and a dedicated proxy. Pushes to the canonical `master` branch are checked every minute. Read [the automatic release procedure](../deploy/autodeploy.md) before production work.

Preserve `.env`, signing certificates, the original Compose app, and all shared data. Run the verified backup script before a manual rollout. Schema changes require a separate compatible migration procedure. This fork adds no schema migration.

The `user/501/com.incubator.docuseal.reminders` launchd job invokes the installed `reminders.sh` every five minutes. It selects the active container from deployment state and queues reminder and import-recovery work in that release's Sidekiq runtime.
