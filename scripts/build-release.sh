#!/bin/bash
# Native Xcode tools keep CI independent of locally installed wrappers.
set -euo pipefail
set +x
umask 077

die() { echo "error: $*" >&2; exit 1; }
version="${VERSION:-}"
build_number="${BUILD_NUMBER:-}"
[[ "$version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] \
    || die 'VERSION must be a numeric release version, e.g. 1.1.0'
[[ "$build_number" =~ ^[1-9][0-9]*$ ]] || die 'BUILD_NUMBER must be a positive integer'
if [[ "${1:-}" == "--validate-inputs" ]]; then exit 0; fi
[[ $# -eq 0 ]] || die 'Only --validate-inputs is supported'

for name in APPLE_TEAM_ID DEVELOPER_ID_P12_BASE64 DEVELOPER_ID_P12_PASSWORD \
    CI_KEYCHAIN_PASSWORD ASC_API_KEY_P8_BASE64 ASC_API_KEY_ID; do
    [[ -n "${!name:-}" ]] || die "Missing required environment variable: $name"
done
for tool in xcodebuild xcrun security ditto hdiutil codesign spctl lipo jq shasum; do
    command -v "$tool" >/dev/null || die "Missing tool: $tool"
done
xcode_major="$(xcodebuild -version | awk '/^Xcode / {split($2, v, "."); print v[1]}')"
[[ "$xcode_major" =~ ^[0-9]+$ && "$xcode_major" -ge 26 ]] \
    || die 'Individual API keys require Xcode 26 or newer'

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"
output="$repo_root/dist/v$version-build-$build_number"
[[ ! -e "$output" ]] || die "Output already exists: $output (refusing to overwrite)"
mkdir -p "$output/logs"
scratch="$(mktemp -d "${RUNNER_TEMP:-/private/tmp}/wadb-release.XXXXXX")"
keychain="$scratch/signing.keychain-db"
certificate="$scratch/certificate.p12"
api_key="$scratch/AuthKey.p8"
original_keychains=()
while IFS= read -r entry; do
    entry="${entry#*\"}"
    entry="${entry%\"*}"
    [[ -z "$entry" ]] || original_keychains+=("$entry")
done < <(security list-keychains -d user)
search_list_changed=0
cleanup() {
    if [[ "$search_list_changed" -eq 1 && ${#original_keychains[@]} -gt 0 ]]; then
        security list-keychains -d user -s "${original_keychains[@]}" || true
    fi
    security delete-keychain "$keychain" >/dev/null 2>&1 || true
    rm -f "$certificate" "$api_key"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Run tests before importing any signing material.
xcodebuild test -project wADB.xcodeproj -scheme wADB -configuration Debug \
    -destination 'platform=macOS' -derivedDataPath "$scratch/tests" \
    CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= \
    2>&1 | tee "$output/logs/tests.log"

printf '%s' "$DEVELOPER_ID_P12_BASE64" | base64 --decode > "$certificate"
printf '%s' "$ASC_API_KEY_P8_BASE64" | base64 --decode > "$api_key"
chmod 600 "$certificate" "$api_key"
security create-keychain -p "$CI_KEYCHAIN_PASSWORD" "$keychain"
security set-keychain-settings -lut 21600 "$keychain"
security unlock-keychain -p "$CI_KEYCHAIN_PASSWORD" "$keychain"
security import "$certificate" -P "$DEVELOPER_ID_P12_PASSWORD" \
    -t cert -f pkcs12 -k "$keychain" -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: \
    -s -k "$CI_KEYCHAIN_PASSWORD" "$keychain" >/dev/null
[[ ${#original_keychains[@]} -gt 0 ]] || die 'No original user keychains found'
search_list_changed=1
security list-keychains -d user -s "$keychain" "${original_keychains[@]}"

xcodebuild archive -project wADB.xcodeproj -scheme wADB -configuration Release \
    -destination 'generic/platform=macOS' -archivePath "$scratch/wADB.xcarchive" \
    -derivedDataPath "$scratch/release" \
    DEVELOPMENT_TEAM="$APPLE_TEAM_ID" CODE_SIGN_STYLE=Manual \
    'CODE_SIGN_IDENTITY=Developer ID Application' CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
    OTHER_CODE_SIGN_FLAGS="--timestamp --keychain $keychain" \
    ENABLE_HARDENED_RUNTIME=YES ONLY_ACTIVE_ARCH=NO 'ARCHS=arm64 x86_64' \
    MARKETING_VERSION="$version" CURRENT_PROJECT_VERSION="$build_number" \
    2>&1 | tee "$output/logs/build.log"

app="$scratch/wADB.xcarchive/Products/Applications/wADB.app"
[[ -d "$app" ]] || die 'Archive did not contain wADB.app'
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")" == "$version" ]] \
    || die 'Built release version does not match requested version'
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Contents/Info.plist")" == "$build_number" ]] \
    || die 'Built build number does not match requested build number'
lipo "$app/Contents/MacOS/wADB" -verify_arch arm64 x86_64
codesign --verify --deep --strict --verbose=2 "$app"
codesign -d --entitlements :- "$app" > "$output/logs/entitlements.plist" 2>/dev/null
if /usr/libexec/PlistBuddy -c 'Print :com.apple.security.get-task-allow' \
    "$output/logs/entitlements.plist" 2>/dev/null | grep -qi true; then
    die 'Distribution app contains get-task-allow'
fi

notarize() {
    local artifact="$1" label="$2" result submission
    result="$output/logs/$label-notary.json"
    # Individual API key: intentionally NO --issuer argument.
    if ! xcrun notarytool submit "$artifact" --key "$api_key" \
        --key-id "$ASC_API_KEY_ID" --wait --timeout 30m --output-format json > "$result"; then
        echo "Notarization command failed; checking submission log." >&2
    fi
    submission="$(jq -r '.id // empty' "$result" 2>/dev/null || true)"
    if [[ -n "$submission" ]]; then
        xcrun notarytool log "$submission" --key "$api_key" --key-id "$ASC_API_KEY_ID" \
            "$output/logs/$label-notary-log.json" || true
    fi
    jq -e '.status == "Accepted"' "$result" >/dev/null \
        || die "Notarization not accepted; see $result"
}

ditto -c -k --keepParent "$app" "$scratch/wADB.zip"
notarize "$scratch/wADB.zip" app
xcrun stapler staple "$app"
xcrun stapler validate "$app"
spctl --assess --type execute --verbose=2 "$app"

mkdir "$scratch/dmg"
ditto "$app" "$scratch/dmg/wADB.app"
ln -s /Applications "$scratch/dmg/Applications"
dmg="$output/wADB-$version-mac-universal.dmg"
hdiutil create -volname wADB -srcfolder "$scratch/dmg" -format UDZO "$dmg"
codesign --sign 'Developer ID Application' --keychain "$keychain" --timestamp "$dmg"
notarize "$dmg" dmg
xcrun stapler staple "$dmg"
xcrun stapler validate "$dmg"
codesign --verify --strict --verbose=2 "$dmg"
spctl --assess --type open --context context:primary-signature --verbose=2 "$dmg"
(cd "$output" && shasum -a 256 "$(basename "$dmg")" > "$(basename "$dmg").sha256")
echo "Validated release: $dmg"
