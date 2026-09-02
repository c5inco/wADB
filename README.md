<img height="360" alt="image" src="https://github.com/user-attachments/assets/9929597d-4d11-4293-bbf5-df5f6fea6a25" />

# wADB

**wADB** (pronounced *wad-be*) is a tiny macOS menu-bar app that keeps the standard ADB server running so paired Android phones remain available for wireless debugging — without keeping Android Studio open.

Pair once by scanning a QR code, then ADB's native mDNS support reconnects the phone whenever the server starts. While enabled, wADB supervises the standard server at `127.0.0.1:5037` and restarts it if another app stops it. Android Studio, the `adb` command line, and every other ADB client see the same devices.

## Requirements

- macOS 14 or later
- Android SDK Platform-Tools (`adb`) — wADB finds your existing install and never installs or replaces it
- Your Mac and phone on the same Wi-Fi network
- **Wireless debugging** enabled in the phone's Developer options

## Getting started

1. Launch wADB. It lives in the menu bar — no Dock icon or main window — and starts supervising ADB immediately.
2. Allow **Local Network** access when macOS asks. Pairing and automatic reconnection need it.
3. Choose **Pair new device…** from the menu. On your phone, open **Settings → Developer options → Wireless debugging → Pair device with QR code** and scan the code.

The phone pairs and connects automatically. The menu lists live wireless ADB devices only; USB devices and emulators remain available to ADB clients but are not shown by wADB.

Choose **Stop ADB** to disable supervision and stop the shared server. This disconnects wireless devices, USB devices, and emulators for every ADB client. **Start ADB** starts supervision again. **Stop ADB** only lasts for the session: launching wADB always starts the ADB server, and if the server is already running it attaches to it and leaves it alone. Quitting wADB stops supervision but deliberately leaves the current ADB server and its connections running.

## Limitations and notes

- Local Wi-Fi only; there is no remote-network relay.
- If `adb` is missing, wADB shows an error explaining what to install — it won't install Platform-Tools for you.
- ADB is a shared system-wide server. While wADB supervision is enabled, it restarts the server if Android Studio or another client kills it.
- On Android 17+ with Platform-Tools 37+, ADB Wi-Fi 2.0 reconnects trusted devices automatically. wADB relies on that native behavior and keeps its server alive.

## Security and privacy

- QR pairing credentials are generated with the system's secure random source, handed to `adb pair` via stdin only — never argv, environment variables, logs, or disk — and wiped as soon as pairing succeeds, fails, expires, or the window closes.
- Only non-sensitive pairing hints are persisted: the last verified endpoint, Bonjour name and address, display name, and transport fingerprint. Connection status is always derived from the current ADB server and is never persisted.
- wADB uses your existing ADB server, keys, and pairings. There is no helper daemon, companion app, or third-party relay.
- **About wADB → Share Logs** creates a local, reviewable text report for support. Nothing is uploaded automatically. Before saving, wADB replaces known device details, network addresses, user paths, and common personal identifiers with stable placeholders. The confirmation explains what is included so users can choose whether to continue.

## Building from source

You'll need Xcode 26 (or a compatible toolchain). Open `wADB.xcodeproj`, select the **wADB** scheme, and build and run (⌘R) or test (⌘U) as usual.

The project is generated with [XcodeGen](https://github.com/yonaskolb/XcodeGen); `project.yml` is its source of truth. If you change `project.yml`, regenerate with:

```sh
xcodegen generate --spec project.yml
```

To build and test from the command line instead:

```sh
xcodebuild test -project wADB.xcodeproj -scheme wADB -configuration Debug
xcodebuild build -project wADB.xcodeproj -scheme wADB -configuration Debug
```

### Local deployment

For development deployments, the repository includes a script that builds with
the `xcodebuildmcp` CLI, gracefully stops the installed app and its owned
`track-devices` observer, installs the new bundle, and verifies the executable,
new process, and shared ADB server:

```sh
./scripts/deploy-local.sh
```

The script installs to `/Applications/wADB.app` and preserves the previous app
bundle in a temporary deployment directory under `/private/tmp`.

Local builds use ad-hoc signing by default. To persist an Apple Developer team
for builds from Xcode, copy the local signing template and replace the
placeholder; the resulting file is ignored by Git:

```sh
cp Config/Signing.local.xcconfig.example Config/Signing.local.xcconfig
```

For CI or a one-off signed deployment, pass the team identifier without
creating a local configuration file:

```sh
WADB_DEVELOPMENT_TEAM=YOURTEAMID ./scripts/deploy-local.sh
```

The implementation is intentionally small: an AppKit status-menu app, an ADB process manager with a self-recovering `track-devices` observer, Bonjour discovery for pairing, and minimal persisted multi-device state. A real QR scan is deliberately excluded from automated tests, since it would create a new pairing on a physical phone.

## Notarized GitHub releases

The `Notarized release` workflow runs on `vMAJOR.MINOR.PATCH` tag pushes
(for example, `v1.1.0`). The tagged commit must be in `main`'s history.
It runs tests, archives a universal app, signs with Developer ID, notarizes
and staples both the app and DMG, and checks signatures, Gatekeeper,
architectures, and bundle versions before publishing a GitHub Release.

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

The tag supplies `MARKETING_VERSION`, and the workflow run number supplies
`CURRENT_PROJECT_VERSION`. The resulting bundle metadata is also displayed
in About wADB. Local builds default to version `1.0.0`, build `1`.

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
notarization stops publication. A rerun does not overwrite an existing release;
inspect any existing draft/release before retrying publication.

`scripts/build-release.sh` contains the same pipeline for local use with the
above environment values plus `VERSION` and `BUILD_NUMBER`. **Running it uploads
the app and DMG to Apple.** Its `--validate-inputs` mode only checks version/build
syntax, without building, reading credentials, or contacting Apple. Release
outputs go under `dist/v<VERSION>-build-<BUILD_NUMBER>`; existing output paths
are refused. Temporary private-key files and the signing keychain are cleaned
up on exit, and the original keychain search list is restored.

## License

Licensed under the [Apache License, Version 2.0](LICENSE). See [NOTICE](NOTICE)
for copyright and third-party attribution.
