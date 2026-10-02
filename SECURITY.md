# Security policy

## Supported version

Security fixes apply to the latest commit on `main`. The repository contains a native local foundation, documentation, and development tooling. No connected service or distributed app has been released. Debug-only identities and service responses are simulations; local role checks are not production authentication.

## Private reporting

Use [GitHub private vulnerability reporting](https://github.com/joshuawyadao/Second-Look/security/advisories/new). Do not post vulnerability details or sensitive data in a public issue.

Include the affected commit, likely impact, and minimal reproduction steps with invented data. Exclude personal photos, addresses, reviewer identities, credentials, and private paths. If private reporting is unavailable, open a sanitized issue asking for a private contact channel without disclosing the vulnerability.

## Scope

Credential exposure, unintended data publication, unsafe repository tooling, and dependency compromise are in scope today. Local persistence integrity, accidental inclusion of demo authorization controls in Release, and incorrect disclosure of checklist information are also in scope. Real media access, reviewer authentication, and revocation require the connected milestones; they are not implemented yet.

Ordinary defects and feature requests belong in public issues with sanitized examples. Local repository verification checks selected filenames and links; it is not a complete security audit.
