# VCS fork delivery record

The installed baseline is DocuSeal Community 3.3.4 at upstream tag `13a1835c`.
The production service runs in Docker Compose on `valley-big-mac` and stores documents in a named volume and metadata in PostgreSQL.

## Acceptance checks

- An authorized editor can preview and import CSV and XLSX recipients once. Invalid rows create no submissions.
- Viewers cannot edit templates, send requests, manage users, or change service settings.
- A reminder scan skips completed, declined, archived, and expired invitations and does not queue the same reminder twice.
- Formula arithmetic and conditional fields produce the expected saved values. Formula input cannot execute application code.
- SMS and phone verification use encrypted provider credentials and enforce OTP before signing or downloading documents.
- The template API creates documents from HTML, PDF, and DOCX. Field tags become editable fields.
- Embedded forms and editors use explicit origins and scoped short-lived editor tokens.
- Resend preserves recipients, reply addresses, HTML, text, and attachments. A test uses Resend's delivery simulator.
- Browser checks cover the login, dashboard, recipient import, settings, and signing pages.
- A synthetic document produces a cryptographically valid signed PDF after deployment.

## Execution

1. Ground deployment and feature boundaries. Complete.
2. Implement independent feature modules and VCS views. In progress.
3. Run isolated behavior checks and independent security review. In progress.
4. Correct failures and run the complete check again.
5. Publish the fork and deploy the tested image after a verified backup.
6. Check production health, branding, delivery, and PDF signatures.

## Decisions

The fork starts from the installed tag to avoid combining feature work with an upgrade.
The VCS palette comes from the September 2026 brand guide. The interface uses its approved Arial fallback.
The interface retains upstream DocuSeal attribution and links the fork source.
A private uploaded blob holds each import preview. A database row lock makes confirmation single-use.
Resend uses an ActionMailer adapter so every existing mailer keeps the same message construction.
Production data and credentials never enter the source repository.

## Throughput checkpoint

The remaining work is integration verification, review fixes, and deployment. Browser design work and backend review run independently. The longest dependent step is building and testing the final Docker image. Each verification result must identify whether it used the isolated database or production.
