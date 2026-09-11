# Releasing wADB

This document covers the notarized GitHub release pipeline. It is intended for
maintainers; users and contributors building locally should follow the README.

## Overview

The `Notarized release` workflow (`.github/workflows/release.yml`) runs on
`vMAJOR.MINOR.PATCH` tag pushes (for example, `v1.1.0`). The tagged commit must
be in `main`'s history. It runs tests, archives a universal app, signs with
Developer ID, notarizes and staples both the app and DMG, and checks
signatures, Gatekeeper, architectures, and bundle versions before publishing a
GitHub Release.

## One-time setup

Create a GitHub environment named `release-signing`, restricted to tags
matching `v*`. Protect release-tag creation with repository rules; optionally
require environment approval. Never expose the signing environment to PR jobs.

Configure these **environment secrets**:

| Name | Value |
| --- | --- |
| `DEVELOPER_ID_P12_BASE64` | Base64-encoded Developer ID Application certificate **and private key**, exported as `.p12` |
| `DEVELOPER_ID_P12_PASSWORD` | Password used when exporting that `.p12` |
| `CI_KEYCHAIN_PASSWORD` | Random password for the temporary CI keychain |
| `ASC_API_KEY_P8_BASE64` | Base64-encoded App Store Connect **Individual** API private key |
| `ASC_API_KEY_ID` | That Individual key's ID |

Configure `APPLE_TEAM_ID` under **environment variables**. Credentials and
personal signing overrides must not be committed. The workflow uses Xcode 26.6
and intentionally omits `--issuer`; Individual keys require Xcode 26 or later.
There is no `ASC_API_ISSUER_ID` requirement.

## Versioning

The tag supplies `MARKETING_VERSION`, and the workflow run number supplies
`CURRENT_PROJECT_VERSION`. The resulting bundle metadata is also displayed
in About wADB. Local builds default to version `1.0.0`, build `1`.

## Cutting a release

After merging the workflow and desired changes into `main`, choose an unused
version and push only that tag:

```sh
git switch main
git pull --ff-only
git tag -a v1.1.0 -m "wADB 1.1.0"
git push origin v1.1.0
```

The download is `wADB-1.1.0-mac-universal.dmg`, with a `.sha256` checksum.
Release logs are retained as Actions artifacts for 14 days, including Apple's
submission IDs and available notarization logs. An unsuccessful or timed-out
notarization stops publication. **A rerun does not overwrite an existing
release**; inspect any existing draft/release before retrying publication.

## Local release builds

`scripts/build-release.sh` contains the same pipeline for local use with the
above environment values plus `VERSION` and `BUILD_NUMBER`. **Running it uploads
the app and DMG to Apple.** Its `--validate-inputs` mode only checks version/build
syntax, without building, reading credentials, or contacting Apple. Release
outputs go under `dist/v<VERSION>-build-<BUILD_NUMBER>`; existing output paths
are refused. Temporary private-key files and the signing keychain are cleaned
up on exit, and the original keychain search list is restored.
