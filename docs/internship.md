# Internship packet

## Deployment status

The portal is at `https://sign.valleychristianai.com/internship`.
The initial implementation is in [PR #3](https://github.com/Valley-Christian-Startup-Incubator/docuseal/pull/3).
On October 30, 2026, the operator confirmed that Benjamin Mull handles both the
MOU school countersignatures and the authorized work permit issuer section.
Production provisioning assigns both responsibilities to him in one signing role.

The two MOUs name Benjamin Mull as the school representative. His work email
is listed on the [official VCS contact page](https://www.vcs.net/8thgradecountdown).
The work permit has a separate section marked "For authorized work permit issuer
use ONLY". The school representative and issuer are separate responsibilities,
even when one person performs both. Intake accepts packets only when its private
configuration is enabled. Otherwise the public page shows a setup notice.

## Signing behavior

`GET /internship` starts a Summer 2027 packet without a DocuSeal account. The
student verifies their email and signs first. Parent and host receive separate
private links next; school and any separate work permit issuer sign last.
Corrected names in the document update the corresponding recipient name.

After signing, the student can choose **Parent signs now** and pass the same
device to their parent or guardian. The parent verifies their own email before
viewing and signing their sections. The normal email invitation remains available
for signing later. The handoff clears the student's verification cookies and
does not grant access to the parent's form.

The handoff requires a completed, verified student in an active internship packet.
The server selects that packet's pending parent. A visitor cannot select a parent
from another packet or use the handoff for school or host signing. The option
disappears when the parent finishes or declines.

The packet combines the student/parent MOU, host MOU, and CDE B1-1, preserving
the supplied document text. The field blueprint has 58 fields across six pages.
Repeated names and signatures share values. Only each field's assigned role
can edit it. The SSN field is optional; it is not collected on the intake page.
Completed PDFs require verification, and emails do not attach the documents.

## Provision

Keep the originals and converted PDFs in private storage outside this public
repository. Convert the two DOCX files to `student.pdf` and `host.pdf`; retain
the supplied CDE PDF filename. Copy `deploy/internship_blueprint.json` into that
directory as `blueprint.json`. Its document hashes must match all three PDFs.

Run `bundle exec rails runner deploy/provision_internship.rb` in the active
release with these environment variables:

- `VCS_INTERNSHIP_DIR`: private directory containing the blueprint and PDFs.
- `VCS_INTERNSHIP_SCHOOL_EMAIL`: authorized MOU school countersigner.
- `VCS_INTERNSHIP_SCHOOL_NAME`: recipient display name.
- `VCS_INTERNSHIP_ISSUER_EMAIL` and `VCS_INTERNSHIP_ISSUER_NAME`: optional separate
  authorized work permit issuer. Omit when the school countersigner does both.
- `VCS_INTERNSHIP_ENABLE=true`: activate intake after verifying signer routing.

Take a database/document-volume backup before production provisioning. Confirm
school and issuer assignments before creating the production template. The
script refuses blueprint or signer-topology changes on an existing template;
create a reviewed template version for those changes. Without an enabled,
configured template the public route shows a setup notice and accepts no intake.

## Verify

Provision an isolated instance with synthetic recipient addresses, then run:

```sh
VCS_ISOLATED_TEST=true bundle exec rails runner deploy/verify_internship.rb
```

The check uses fake background email jobs, exercises CSRF and email OTP,
checks role ownership and signing order, completes all roles, and generates
the three signed PDFs plus audit trail. `VCS_INTERNSHIP_OUTPUT_DIR` optionally
saves synthetic output PDFs for placement review. Use HTTPS in browser tests
because production verification cookies are secure.

Initial release verification passed 36 checks with the school representative also
acting as issuer, and 38 checks with a separate issuer. Both configurations produced
three signed PDFs totaling six pages and an audit trail. Independent Chromium
verification covered intake, validation, email OTP, and the real signing form.
These checks used synthetic contacts and fake email jobs in isolated databases.

The same-device handoff adds checks for CSRF, student verification, completion
eligibility, parent selection, and the parent's own OTP. Staff-page and event-log
export regression checks bring the suite to 51 checks with the school
representative also acting as issuer.

Participants download the three completed PDFs from their signing page. Staff
open the completed packet to download its **Audit Log** PDF or the **Download
Event Log** CSV. Both staff views require account-scoped read access. The CSV
contains event timestamps, signer identities, IP addresses, and user agents.
It excludes form field values and protects spreadsheet cells from formula injection.

## Implementation

| Responsibility | Source |
| --- | --- |
| Public GET and POST, validation responses, privacy headers | [InternshipsController](../app/controllers/internships_controller.rb) |
| Session-bound start tokens, replay protection, contact routing, prefill, name detection | [Vcs::InternshipPacket](../lib/vcs/internship_packet.rb) |
| Intake and setup notice | [Views](../app/views/internships), [stylesheet](../public/internship.css) |
| Same-device parent handoff | [Handoff section](../app/views/internships/_parent_signing.html.erb), [completion page](../app/views/submit_form/completed.html.erb) |
| Document hashes, role ownership, field positions | [Field blueprint](../deploy/internship_blueprint.json) |
| Private template creation and activation | [Provisioning script](../deploy/provision_internship.rb) |
| HTTP signing-order enforcement | [SubmitFormController](../app/controllers/submit_form_controller.rb) |
| Signer name updates after field validation | [SubmitValues](../lib/submitters/submit_values.rb) |
| Reproducible signing and access checks | [Verification script](../deploy/verify_internship.rb) |
