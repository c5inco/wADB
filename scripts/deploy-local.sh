#!/bin/bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
project_path="$repo_root/wADB.xcodeproj"
derived_data_path="$repo_root/DerivedData"
built_app="$derived_data_path/Build/Products/Debug/wADB.app"
installed_app="/Applications/wADB.app"
installed_executable="$installed_app/Contents/MacOS/wADB"
bundle_id="local.c5inco.wADB"
development_team="${WADB_DEVELOPMENT_TEAM:-}"
build_options=()
if [[ -n "$development_team" ]]; then
    build_options+=(--extra-args "DEVELOPMENT_TEAM=$development_team")
fi

deploy_dir=""
backup_app=""
deployment_complete=0

die() {
    echo "error: $*" >&2
    exit 1
}

process_is_running() {
    kill -0 "$1" 2>/dev/null
}

wait_for_exit() {
    local pid="$1"
    local attempts="${2:-50}"
    local attempt
    for ((attempt = 0; attempt < attempts; attempt++)); do
        if ! process_is_running "$pid"; then
            return 0
        fi
        sleep 0.1
    done
    return 1
}

wadb_pid() {
    ps -axo pid=,command= | awk -v executable="$installed_executable" \
        '$2 == executable && NF == 2 { print $1 }'
}

tracker_children() {
    local parent_pid="$1"
    ps -axo pid=,ppid=,command= | awk -v parent="$parent_pid" '
        $2 == parent && $0 ~ /\/platform-tools\/adb track-devices -l$/ { print $1 }
    '
}

tracker_still_matches() {
    ps -p "$1" -o command= 2>/dev/null \
        | grep -Eq '/platform-tools/adb track-devices -l$'
}

listener_pid() {
    lsof -nP -t -iTCP:5037 -sTCP:LISTEN 2>/dev/null | head -n 1 || true
}

restore_on_failure() {
    local status=$?
    trap - EXIT
    if [[ $status -ne 0 && $deployment_complete -eq 0 && -n "$backup_app" && -d "$backup_app" ]]; then
        echo "Deployment failed; restoring the previous app bundle." >&2
        if [[ -e "$installed_app" ]]; then
            mv "$installed_app" "$deploy_dir/failed-wADB.app" || true
        fi
        mv "$backup_app" "$installed_app" || true
    fi
    exit "$status"
}

trap restore_on_failure EXIT

for tool in xcodebuildmcp osascript ditto shasum lsof open ps awk grep; do
    command -v "$tool" >/dev/null 2>&1 || die "required tool not found: $tool"
done

echo "Building wADB with XcodeBuildMCP..."
xcodebuildmcp macos build \
    --project-path "$project_path" \
    --scheme wADB \
    --configuration Debug \
    --derived-data-path "$derived_data_path" \
    --prefer-xcodebuild true \
    "${build_options[@]}"

[[ -d "$built_app" ]] || die "build succeeded but app bundle was not found at $built_app"

deploy_dir="$(mktemp -d /private/tmp/wadb-deploy.XXXXXX)"
staged_app="$deploy_dir/staged-wADB.app"
ditto "$built_app" "$staged_app"

built_hash="$(shasum -a 256 "$built_app/Contents/MacOS/wADB" | awk '{ print $1 }')"
staged_hash="$(shasum -a 256 "$staged_app/Contents/MacOS/wADB" | awk '{ print $1 }')"
[[ "$built_hash" == "$staged_hash" ]] || die "staged executable does not match the build"

old_wadb_pid="$(wadb_pid)"
if [[ "$old_wadb_pid" == *$'\n'* ]]; then
    die "multiple installed wADB processes are running; refusing an ambiguous deployment"
fi

old_tracker_pids=""
if [[ -n "$old_wadb_pid" ]]; then
    old_tracker_pids="$(tracker_children "$old_wadb_pid")"
fi
adb_pid_before="$(listener_pid)"

if [[ -n "$old_wadb_pid" ]]; then
    echo "Requesting graceful quit from wADB PID $old_wadb_pid..."
    if ! osascript -e "tell application id \"$bundle_id\" to quit" >/dev/null; then
        echo "Graceful quit request failed; waiting before exact-PID fallback." >&2
    fi

    if ! wait_for_exit "$old_wadb_pid"; then
        echo "Graceful quit timed out; terminating wADB PID $old_wadb_pid." >&2
        kill -TERM "$old_wadb_pid"
        wait_for_exit "$old_wadb_pid" 30 \
            || die "wADB PID $old_wadb_pid did not terminate"
    fi
fi

for tracker_pid in $old_tracker_pids; do
    if process_is_running "$tracker_pid" && tracker_still_matches "$tracker_pid"; then
        echo "Terminating leftover wADB tracker PID $tracker_pid..."
        kill -TERM "$tracker_pid"
        wait_for_exit "$tracker_pid" 30 \
            || die "tracker PID $tracker_pid did not terminate"
    fi
done

if [[ -d "$installed_app" ]]; then
    backup_app="$deploy_dir/previous-wADB.app"
    mv "$installed_app" "$backup_app"
fi
mv "$staged_app" "$installed_app"

installed_hash="$(shasum -a 256 "$installed_executable" | awk '{ print $1 }')"
[[ "$built_hash" == "$installed_hash" ]] || die "installed executable does not match the build"

echo "Launching installed wADB..."
open -a "$installed_app"

new_wadb_pid=""
for ((attempt = 0; attempt < 50; attempt++)); do
    new_wadb_pid="$(wadb_pid)"
    if [[ -n "$new_wadb_pid" && "$new_wadb_pid" != "$old_wadb_pid" ]]; then
        break
    fi
    sleep 0.1
done

[[ -n "$new_wadb_pid" ]] || die "installed wADB did not launch"
[[ "$new_wadb_pid" != "$old_wadb_pid" ]] || die "Launch Services reused the old wADB process"

adb_pid_after="$(listener_pid)"
if [[ -n "$adb_pid_before" && "$adb_pid_after" != "$adb_pid_before" ]]; then
    echo "warning: ADB listener changed from PID $adb_pid_before to ${adb_pid_after:-none}" >&2
fi

deployment_complete=1
echo "Deployment complete."
echo "  wADB PID: $new_wadb_pid"
echo "  ADB 5037 PID: ${adb_pid_after:-none}"
echo "  Executable SHA-256: $installed_hash"
if [[ -n "$backup_app" ]]; then
    echo "  Previous bundle: $backup_app"
fi
