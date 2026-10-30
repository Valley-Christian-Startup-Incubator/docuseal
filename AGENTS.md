# Valley Christian Sign

When you say you will implement something, implement it and verify the result.

For interface design, consult Claude. If Claude is at its weekly limit, consult Astra.

For production operations, read [the automatic release procedure](deploy/autodeploy.md). Use its watcher and proxy route. Preserve the original Compose app, database, document volume, active release, previous release, and background queues. The watched branch is `master`.

Before changing recipient import, permissions, formulas, phone verification, email delivery, or embedding, run the applicable checks in `deploy/` against an isolated database. `VCS_ISOLATED_TEST=true` is required. Production credentials stay outside the repository.

Keep the AGPL license and required DocuSeal interface attribution. Read [the fork reference](docs/VCS.md) for supported behavior and integration limits.
