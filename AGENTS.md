# Working on Second Look

Second Look is a public, early-stage task-list and human photo-review app concept. Read `README.md`, `docs/Product-Brief.md`, and relevant docs before changing the project. No application stack or platform has been selected; do not treat proposed behavior as implemented.

- Keep work within the current request. The owner will provide more product details; do not invent requirements or introduce an app framework before that direction is established.
- Preserve durable product decisions in `docs/Product-Brief.md`. Use `docs/Implementation-Plan.md` for replaceable task tracking and update verification docs when tooling changes.
- Run `./scripts/verify-repository.sh` for repository changes. Add meaningful tests for changed executable behavior and document any coverage limits. Add application checks when application code exists.
- Use synthetic fixtures. Do not publish credentials, personal photos, household details, private reviewer data, or local artifacts. Treat future photo access, reviewer permissions, and evidence freshness as explicit contracts to design and test.
- Stage only task-owned files and keep Git operations sequential. After the initial bootstrap, use feature branches and pull requests for `main`; do not merge without an explicit user request.
- When delegating, assign bounded responsibilities and file ownership, accommodate other contributors' edits, and integrate results before finishing.

These instructions are tool-neutral; contributing does not require proprietary tools or personal skills.
