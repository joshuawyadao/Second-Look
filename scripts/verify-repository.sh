#!/bin/sh
set -eu

REPO_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$REPO_ROOT"
export PYTHONDONTWRITEBYTECODE=1

python3 scripts/verify_repository.py
python3 -m unittest discover -s tests -p 'test_*.py'
git diff --check
git diff --cached --check
