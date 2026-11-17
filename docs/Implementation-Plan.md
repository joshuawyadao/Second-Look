# Plan

Reproduce Second Look's recurring native snooze CI failure, fix the demonstrated cause with preserved deadline/persistence assertions, and prepare a reviewed green PR.

## Scope
- In: Isolated synthetic snooze reproduction, evidence-led test or app correction, relevant regression/diagnostic coverage, Verification documentation, current-source connected evidence where required and PR validation.
- Out: Hosted/private accounts, real media, notifications, physical devices, product redesign, paid resources, deployment and merging the PR.

## Action items
- [x] Read README, Product Brief/Spec, AGENTS, native workflow/runner and existing snooze test; record failed run43993314439 on main bd96fcb (Xcode16.4/iOS26.2).
- [x] Run the unchanged focused native scenario on a task-owned simulator with retained xcresult; distinguish local Xcode27.2/iOS26.5 evidence from hosted failure and minimize a reproducible trigger.
- [x] Present ranked falsifiable hypotheses after the loop exists; probe one variable at a time and identify the failing boundary before selecting a fix.
- [x] Add or update meaningful regression coverage at the real interaction/state boundary; preserve switch activation, future-date and exact save/reopen assertions.
- [x] Apply the smallest demonstrated correction and bounded failure diagnostics; avoid blind retries, blanket timeout increases and unrelated application changes.
- [ ] Run focused repeated native checks, repository/Swift suites and full native/Release validation, recording unavailable or failed checks honestly.
- [ ] Update docs/Verification.md with cause, exact commands, outcomes and limits; regenerate the four-case source-matched receipt if executable inputs change, preserving owned cleanup.
- [ ] Save/push, open the PR, run exact-head Codex and Brooks review, address actionable feedback and verify required CI Verify plus clean mergeability; leave unmerged.

## Open questions
None. The cause is an investigation item, not a product-choice blocker.

Baseline reproduction: the first command was rejected before build because `-retry-tests-on-failure` is a flag, not a Boolean-valued option. Corrected invocation omitted it. On local Xcode27.2/iOS26.5, the unchanged exact scenario completed3/3 successfully (33.579s,28.755s,34.658s); this does not reproduce or resolve the Xcode16.4/iOS26.2 CI failure. Ranked hypotheses before probes:1) full-row coordinate misses the actual native switch;2) keyboard/scroll geometry changes at tap;3) UI binding enables then resets. Probe one adds only tagged test-side frame/value/accessibility snapshots around the unchanged tap. No product correction yet.

Probe1 completed3/3 without failure on local English layout; the exposed switch is the whole370px row and contains a separate63px native switch descendant. Keyboard remains visible, row frame stays stable and value changes0→1 without resetting. Probe2 varies only test language/layout (`-testLanguage ar -testRegion US`) to test whether the fixed0.93 row coordinate depends on native control placement; it is not evidence that the original English CI run used RTL.

Probe2 changed the test language but the app retained an LTR control tree; the switch enabled normally and the test then failed to parse a mismatched localized date. This is a different harness failure, not reproduction of the CI symptom, and no date assertion is weakened. Probe3 keeps English date formatting and forces only the app native right-to-left layout using system launch defaults to test placement dependence.

Probe3 reproduced the exact switch-enable timeout in24.925s. The native switch is atx32–95 while the fixed row point is aboutx360; keyboard and row stay stable and value remains0. The controlled RTL change proves the test's coordinate-placement fault; it does not prove that the original English CI run used the same layout. Preserve a permanent RTL/future-deadline/save-reopen regression with the old tap first, then change only the action target to the actual native switch. All tagged diagnostics and temporary language experiments are removed. Product source and five-second enable assertion remain unchanged.

The first permanent regression attempt caught a fixture-precondition failure: AppleTextDirection alone left the modern native switch on the right, so the explicit mirrored-placement assertion failed before the old tap. Keep both system RTL defaults that the successful probe demonstrated; rerun old-coordinate red rather than counting this distinct fixture failure as the CI symptom.

Permanent regression red2 now reproduces the exact enable timeout in24.924s with mirrored placement proven. Correct only the tap target to the exposed nested native switch; keep existing scroll bounds, five-second state wait, future-date parsing/comparison and exact save/reopen checks. The correction applies to both default and mirrored variants. Application source, reminder model and persistence are unchanged.

Corrected focused verification: default snooze case passed3/3 (29.457s,29.152s,29.770s); mirrored case passed3/3 (29.588s,29.445s,29.493s). The executed tree differs from the saved test only by an explanatory comment; no behavioral edit followed those passes. Debug Swift241Core+46Transport and Release278 pass; repository88 pass. Independent scoped Brooks review reports no actionable finding, with original-English-CI causality and older toolchain compatibility kept explicit until hosted validation. Freeze executable/test source now, save, regenerate the required four-case connected receipt and finish native/Release/hosted gates.
