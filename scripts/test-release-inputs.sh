#!/bin/bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
for version in 1.0.0 0.1.0 12.34.56; do
    VERSION="$version" BUILD_NUMBER=42 bash scripts/build-release.sh --validate-inputs
done
for version in '' 1.0 v1.0.0 1.0.0-beta 01.0.0 '../1.0.0' '1.0.0;echo bad'; do
    if VERSION="$version" BUILD_NUMBER=42 bash scripts/build-release.sh --validate-inputs 2>/dev/null; then
        echo "Incorrectly accepted version: $version" >&2
        exit 1
    fi
done
for build in '' 0 -1 01 1.5 abc; do
    if VERSION=1.0.0 BUILD_NUMBER="$build" bash scripts/build-release.sh --validate-inputs 2>/dev/null; then
        echo "Incorrectly accepted build: $build" >&2
        exit 1
    fi
done
echo 'Release input validation: 16 cases passed'
