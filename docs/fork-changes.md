# VCS fork modifications

Valley Christian Startup Incubator maintains this fork for
`sign.valleychristianai.com`. Its starting point is DocuSeal Community 3.3.4,
upstream commit `13a1835c006e218e2e48ede3eb153812bd025a05`.

This fork implements the capabilities described below in the Community codebase.
It does not install proprietary DocuSeal Pro code or grant an upstream Pro
license. The AGPL license and DocuSeal attribution requirements remain in effect.
The upstream README continues below the VCS introduction in the root README;
its Pro feature list describes upstream packaging. This reference and the
[VCS usage guide](VCS.md) describe the fork.

## Changes from upstream

| Area | VCS behavior | Main implementation |
| --- | --- | --- |
| Branding | Official VCS logo, colors, favicon, and service identity | [Brand assets and provenance](../public/branding/README.md), [styles](../public/vcs-brand.css) |
| Recipient import | CSV and XLSX review, validation, prefill, and replay-safe confirmation | [RecipientImport](../lib/vcs/recipient_import.rb), [BulkImportsController](../app/controllers/bulk_imports_controller.rb), [ImportDelivery](../lib/vcs/import_delivery.rb) |
| User permissions | Account-scoped admin, editor, and viewer permissions | [Ability](../lib/ability.rb) |
| Email | Resend API delivery, encrypted settings, MIME conversion, and stable delivery identity | [ResendDelivery](../lib/vcs/resend_delivery.rb), [MailIdentity](../lib/vcs/mail_identity.rb) |
| Reminders | Scheduled scans skip finished or inactive packets and respect signing order | [Scheduler](../deploy/reminders.sh), [launchd job](../deploy/com.incubator.docuseal.reminders.plist) |
| SMS | Twilio invitations and server-enforced phone verification | [SMS adapter](../lib/vcs/sms.rb), [verification controller](../app/controllers/submit_form_phone_verifications_controller.rb) |
| Fields | Conditional-field controls and bounded numeric, date, and text formulas | [Formula interpreter](../lib/vcs/formula.rb), [field validation](../lib/submitters/submit_values.rb) |
| Template APIs | HTML, PDF, and DOCX conversion with positioned field tags | [HTML renderer](../lib/vcs/html_pdf.rb), [field tags](../lib/vcs/field_tags.rb), [API controllers](../app/controllers/api) |
| Embedding | Signing forms and template-scoped editor tokens restricted to an exact origin | [EmbedTokens](../lib/vcs/embed_tokens.rb), [builder controller](../app/controllers/embed_builders_controller.rb), [authentication](../app/controllers/concerns/vcs_embed_authentication.rb) |
| Internship intake | Account-free intake, email verification, private role-specific signatures, and repeated-value prefill | [Internship implementation and setup](internship.md) |
| Releases | Canonical-master watcher, immutable containers, retained assets, health checks, and rollback | [Release procedure](../deploy/autodeploy.md), [deployer](../deploy/autodeploy.py), [image](../deploy/Dockerfile.vcs) |

## Configuration limits

The following configuration status was verified on October 30, 2026.

Resend is configured for production. Credentials remain in encrypted settings
or private runtime configuration outside Git. SMTP remains an optional fallback.
Twilio credentials are not configured, so SMS delivery is unavailable.

SSO is excluded. Trusted signing certificates still require a certificate from
a trusted certificate authority. The new APIs support the documented requests;
they do not promise complete compatibility with proprietary upstream Pro APIs.

The internship route supports one packet per student and an optional same-device
parent handoff with separate email verification. The operator confirmed Benjamin
Mull for both school and work permit issuer responsibilities. Blank source
documents stay in private storage. Git contains the field blueprint and
provisioning code. The [internship guide](internship.md#deployment-status)
records the signer assignment, activation requirements, and verification results.

## Release history

| Date | Change | Review |
| --- | --- | --- |
| 2026-10-30 | VCS branding, self-hosted features, Resend, embedding, and automatic releases | [PR #1](https://github.com/Valley-Christian-Startup-Incubator/docuseal/pull/1), `e4e1ebaf` |
| 2026-10-30 | Exclude compressed mutable manifests from retained browser assets | [PR #2](https://github.com/Valley-Christian-Startup-Incubator/docuseal/pull/2), `72c7e0bf` |
| 2026-10-30 | Internship portal, 58 mapped fields, private signer routing, and HTTP signing-order enforcement | [PR #3](https://github.com/Valley-Christian-Startup-Incubator/docuseal/pull/3), `e4fa0792` |

## Verification reference

The [usage guide](VCS.md#verification-and-deployment) and
[internship guide](internship.md#verify) describe how to run the checks.
Database checks require an isolated database and `VCS_ISOLATED_TEST=true`.

| Scope | Check |
| --- | --- |
| Imports, permissions, formulas, APIs, and phone verification | [verify_features.rb](../deploy/verify_features.rb) |
| Embedded-editor tokens and access boundaries | [verify_embedding.rb](../deploy/verify_embedding.rb) |
| Resend MIME conversion without delivery | [verify_resend_adapter.rb](../deploy/verify_resend_adapter.rb) |
| Internship routing, access, signed documents, and audit | [verify_internship.rb](../deploy/verify_internship.rb) |
| Release ownership, assets, cutover, and rollback | [autodeploy_test.py](../deploy/autodeploy_test.py) |

Later changes belong in this release history. Configuration status belongs in
the relevant feature guide. Secrets, completed forms, and recipient data stay
outside this repository.
