# Contributing to Second Look

Read the [README](README.md) and [product brief](docs/Product-Brief.md) first. Second Look currently contains repository tooling and an initial concept. Platform, architecture, and feature details await the owner's fuller brief.

## Propose a change

Search existing issues and use the bug or feature request form for a focused problem and observable outcome. Discuss major dependencies, external services, account requirements, and photo-sharing or storage decisions before building around them. Describe proposed features as planned until they are implemented and verified.

## Development workflow

1. Create a descriptive feature branch from `main`, using a fork if needed.
2. Keep changes focused and preserve unrelated work.
3. Add or update meaningful tests when executable behavior changes.
4. Update relevant documentation, keeping durable requirements in the product brief and task tracking in `docs/Implementation-Plan.md`.
5. Run `./scripts/verify-repository.sh` and any future component checks documented in [Verification.md](docs/Verification.md).
6. Open a pull request using the template. Resolve feedback and wait for `CI Verify` before merging.

## Public examples and reporting

Use synthetic data and images that you have the right to publish. Do not commit real household photos, addresses, schedules, personal messages, reviewer details, credentials, local databases, or device logs. Use the ignored `local-data/`, `photos/`, or `uploads/` folders for private local material; these are not app storage APIs.

Report security concerns through [SECURITY.md](SECURITY.md), and follow the [Code of Conduct](CODE_OF_CONDUCT.md). Development does not require a particular coding assistant or personal skill installation.
