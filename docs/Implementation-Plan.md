# Plan

Reproduce Second Look's recurring native snooze CI failure, fix the demonstrated cause with preserved deadline/persistence assertions, and prepare a reviewed green PR.

## Scope
- In: Isolated synthetic snooze reproduction, evidence-led test or app correction, relevant regression/diagnostic coverage, Verification documentation, current-source connected evidence where required and PR validation.
- Out: Hosted/private accounts, real media, notifications, physical devices, product redesign, paid resources, deployment and merging the PR.

## Action items
- [x] Read README, Product Brief/Spec, AGENTS, native workflow/runner and existing snooze test; record failed run43993314439 on main bd96fcb (Xcode16.4/iOS26.2).
- [ ] Run the unchanged focused native scenario on a task-owned simulator with retained xcresult; distinguish local Xcode27.2/iOS26.5 evidence from hosted failure and minimize a reproducible trigger.
- [ ] Present ranked falsifiable hypotheses after the loop exists; probe one variable at a time and identify the failing boundary before selecting a fix.
- [ ] Add or update meaningful regression coverage at the real interaction/state boundary; preserve switch activation, future-date and exact save/reopen assertions.
- [ ] Apply the smallest demonstrated correction and bounded failure diagnostics; avoid blind retries, blanket timeout increases and unrelated application changes.
- [ ] Run focused repeated native checks, repository/Swift suites and full native/Release validation, recording unavailable or failed checks honestly.
- [ ] Update docs/Verification.md with cause, exact commands, outcomes and limits; regenerate the four-case source-matched receipt if executable inputs change, preserving owned cleanup.
- [ ] Save/push, open the PR, run exact-head Codex and Brooks review, address actionable feedback and verify required CI Verify plus clean mergeability; leave unmerged.

## Open questions
None. The cause is an investigation item, not a product-choice blocker.
