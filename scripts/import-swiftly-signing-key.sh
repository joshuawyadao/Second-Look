#!/usr/bin/env bash
set -euo pipefail

: "${GNUPGHOME:?Set GNUPGHOME to the job-owned keyring}"

# Swift.org's Automatic Signing Key #4 signs the Linux Swiftly bootstrap.
expected_fingerprint=E813C892820A6FA13755B268F167DF1ACF9CE069
key_file=$(mktemp "$GNUPGHOME/secondlook-swiftly-key.XXXXXXXX")
trap 'rm -f -- "$key_file"' EXIT

curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
  --connect-timeout 10 --max-time 60 \
  'https://www.swift.org/keys/automatic-signing-key-4.asc' --output "$key_file"

# Include each primary fingerprint and ignore subkey fingerprints. Multiple
# primary keys produce multiple lines, so only the one pinned key can match.
actual_fingerprint=$(
  gpg --no-options --batch --with-colons --show-keys "$key_file" |
    awk -F: '$1 == "pub" { primary = 1; next } $1 == "fpr" && primary { print $10; primary = 0 }'
)
if [[ $actual_fingerprint != "$expected_fingerprint" ]]; then
  printf '%s\n' 'Swiftly installer signing key fingerprint mismatch.' >&2
  exit 1
fi

gpg --no-options --batch --import "$key_file"
