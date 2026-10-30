# Internship packet

`GET /internship` starts a Summer 2027 packet without a DocuSeal account. The
student verifies their email and signs first. Parent and host receive separate
private links next; school and any separate work permit issuer sign last.
Corrected names in the document update the corresponding recipient name.

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
