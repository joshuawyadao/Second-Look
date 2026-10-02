# Product brief

## Status

This document records the owner's initial concept. The repository contains documentation and development tooling; no app, account system, photo sharing, or approval workflow exists yet. The owner will provide a fuller brief before application development.

## Confirmed idea

Second Look is a task-list app intended to help someone who wants another person to double-check things before they leave. A user can designate a partner or another trusted person as a reviewer, send photos, and ask that person to check and approve the list.

A motivating example is checking that the house has been locked up before going out. The same idea could support other checklist items once their scope is defined. Review is performed by a designated person; automated image assessment has not been requested.

## Initial experience to explore

1. Make a list of things to check.
2. Complete the checks and take relevant photos.
3. Send the photos to the designated reviewer.
4. Receive the reviewer's response before heading out.

This is a concept flow, not a finalized specification. In particular, approval of individual items versus the entire list is undecided.

## Decisions for the fuller brief

- Initial platform, devices, and whether both participants need the app.
- One-time lists, reusable checklists, and reminders.
- Reviewer invitations, consent, number of reviewers, and access revocation.
- Photo capture versus existing uploads, item association, and the timing or freshness of evidence.
- Approval states, requests for another photo, edits after approval, and what happens when a reviewer is unavailable.
- Accounts, authentication, photo storage, retention, deletion, and access controls.
- Notifications, offline behavior, accessibility, visual design, and release scope.

## Development boundaries

Use invented data and synthetic images for public development. Real household photos and personal reviewer details do not belong in commits or public issues. Before implementing sharing, define who can see each photo and how access and deletion work. These are design requirements to resolve, not claims about protections already implemented.

Keep this document as the durable source of product direction. Use [Implementation-Plan.md](Implementation-Plan.md) for individual implementation tasks; replacing a task plan should not discard agreed product decisions.
