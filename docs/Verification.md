# Verification

## Run locally

Prerequisites: Git, Python 3.10 or newer, and a POSIX shell. Run from the repository root on macOS, Linux, or WSL:

```sh
./scripts/verify-repository.sh
```

The wrapper checks the repository, runs the verifier's regression tests, and checks staged and unstaged diffs for whitespace errors. It requires no third-party Python packages.

## Current coverage

- Required public repository documents and configuration files exist and are nonempty.
- Tracked and unignored files stay inside the repository; escaping symlinks fail.
- Common private-data paths, credential filenames, and generated caches are rejected when included in the Git inventory, even if force-added.
- Relative inline Markdown links point to existing paths inside the repository.
- Focused regression tests exercise valid documents, missing documents, broken links, accidentally tracked private files, and escaping symlinks.

The verifier inspects filenames and local links. It is not a complete secret scanner, does not inspect photo contents, and does not validate external URLs, Markdown anchors, or every Markdown syntax variant. Review the staged diff before publishing.

## Continuous integration

[CI Verify](https://github.com/joshuawyadao/Second-Look/actions/workflows/ci.yml) runs the same command on pushes to `main`, pull requests, and manual dispatch. It uses Ubuntu 24.04, a commit-pinned checkout action, read-only repository permissions, and no stored checkout credentials. Dependabot checks GitHub Actions updates weekly.

Repository rules require a pull request, resolved review conversations, and the `CI Verify` status for `main`, and block deletion and force pushes. No additional human approval is required for this solo-maintainer baseline. Squash merging is enabled and merged branches are deleted automatically.

## Application coverage

There is no application to build or test yet. When the platform and first feature are chosen, add the relevant build, lint, and application tests to this workflow. Future tests should cover reviewer authorization, photo access, review state changes, and failure or retry behavior once those contracts are defined. Repository checks do not validate those planned behaviors.
