# Second Look

[![CI Verify](https://github.com/joshuawyadao/Second-Look/actions/workflows/ci.yml/badge.svg)](https://github.com/joshuawyadao/Second-Look/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

Second Look is a planned task-list app for getting a second pair of eyes on the things you want to double-check before heading out.

The idea is to make a list, send photos to a partner or another designated reviewer, and let them check and approve it. For example, someone who tends to forget whether they locked up could share a photo for a trusted person to review before they leave.

> **Status: repository setup and initial product concept.** No application is implemented yet. The fuller product brief, supported platforms, and technology stack are still to be decided.

## Project information

- [Product brief](docs/Product-Brief.md): the confirmed idea and decisions still to come.
- [Verification](docs/Verification.md): local repository checks, CI coverage, and limits.
- [Contributing](CONTRIBUTING.md): how to propose and verify changes.
- [Current implementation plan](docs/Implementation-Plan.md): replaceable tracking for the latest task.

## Work locally

Install Git and Python 3.10 or newer, then run:

```sh
git clone https://github.com/joshuawyadao/Second-Look.git
cd Second-Look
./scripts/verify-repository.sh
```

These checks run on macOS and Linux; Windows contributors can use WSL. Python is used only for repository tooling and does not imply an application technology choice. No API keys or package installation are needed.

## Public development

Use synthetic examples in commits, issues, and screenshots. Keep personal photos, household details, addresses, credentials, and private reviewer information out of this public repository. The ignored `local-data/`, `photos/`, and `uploads/` folders are local workspace conventions, not an implemented app storage design.

Changes to `main` use feature branches and pull requests with `CI Verify`. See [SECURITY.md](SECURITY.md) for private vulnerability reporting and the [Code of Conduct](CODE_OF_CONDUCT.md) for participation guidelines.

## License

Original project code and documentation are available under the [MIT License](LICENSE), except where a separate notice applies. Contributor Covenant attribution is retained in the Code of Conduct.
