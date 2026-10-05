# Working on Second Look

Second Look is a native iPhone local foundation for private two-person checklists and human photo review. Read `README.md`, `docs/Product-Brief.md`, `docs/Product-Spec.md`, and relevant docs before changes. The October 2, 2026 handoff is preserved in those canonical docs and `docs/Roadmap.md`.

- Respect milestone boundaries. Milestones 0–1 contain local storage and Debug-only simulated roles/evidence/services. Backend authentication, real photos, remote uploads, push, real deletion, and distribution are later work. Do not describe simulated behavior as connected functionality.
- Keep domain rules and atomic persistence in the dependency-free `SecondLookCore` package; keep platform/UI code in `SecondLook/`. The checked-in Xcode project is the native workflow. iOS 17 is a provisional target, not verified device support.
- Keep synthetic fixtures, role selection, and service response controls behind `SECONDLOOK_DEMO`, separate from Release identity/storage. Never use a role picker as authorization. Preserve exact submission-version checks, fixed run roles, snapshot isolation, and terminal closure.
- Run `./scripts/verify-repository.sh`, `swift test`, and `./scripts/verify-native.sh` for relevant app changes. Discover available simulator destinations. Document failed or unavailable checks honestly and add meaningful behavior tests.
- Preserve durable decisions in canonical product/architecture/decision docs. `docs/Implementation-Plan.md` is replaceable task tracking. Update `docs/Verification.md` with actual evidence and limitations.
- Use synthetic fixtures only. Never publish credentials, household photos, private participant data, local app state, or generated build/test artifacts. There is no default age-based photo expiry; reminders and optional unreviewed timeout are independent and no scheduler runs in M1.
- Stage only task-owned files and keep Git operations sequential. Use feature branches and pull requests for protected `main`; do not open a PR or merge unless requested. Keep meaningful local checkpoints and push the intended existing remote at final save when authorized.
- Delegate bounded responsibilities with explicit ownership, preserve others' edits, and integrate results. Do not assign unrelated project specialists to this app.

These instructions are tool-neutral; contributions do not require proprietary tools or personal skills.
