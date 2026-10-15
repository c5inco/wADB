<img height="360" alt="image" src="https://github.com/user-attachments/assets/9929597d-4d11-4293-bbf5-df5f6fea6a25" />

# wADB

**wADB** (pronounced *wad-be*) is a tiny macOS menu-bar app that keeps the standard ADB server (`127.0.0.1:5037`) running so paired Android phones stay available for wireless debugging without keeping Android Studio open.

Pair once by scanning a QR code; ADB's native mDNS support (including ADB Wi-Fi 2.0 on Android 17+ with Platform-Tools 37+) reconnects trusted phones whenever the server runs. Because wADB supervises the shared system-wide ADB server and restarts it if another client stops it, Android Studio, the `adb` CLI, and all other ADB tools see the same devices.

## Requirements

- macOS 14 or later
- Android SDK Platform-Tools (`adb`); wADB uses your existing installation and does not install or replace it
- Mac and phone on the same local Wi-Fi network (no remote relay)
- **Wireless debugging** enabled in the phone's Developer options

## Getting started

1. Launch wADB. It lives in the menu bar (no Dock icon) and starts supervising ADB immediately.
2. Allow **Local Network** access when macOS prompts so Bonjour discovery and reconnection work.
3. Choose **Pair new device…** from the menu, then on your phone open **Settings → Developer options → Wireless debugging → Pair device with QR code** and scan the code.

The menu lists active wireless ADB devices only (USB devices and emulators remain available to ADB clients as usual).

- **Stop ADB / Start ADB** toggles supervision and stops or restarts the shared ADB server for the current session (disconnecting all ADB devices across clients while stopped).
- **Quit wADB** stops supervision while leaving the running ADB server and its active connections intact.

## Security and privacy

- **Ephemeral pairing secrets:** QR credentials are generated with the system CSPRNG, piped to `adb pair` via `stdin` only (never argv, environment variables, logs, or disk), and wiped as soon as pairing finishes or the window closes.
- **Minimal persisted state:** Only non-sensitive pairing hints are saved (last verified endpoint, Bonjour name/address, display name, and transport fingerprint). Connection status always comes live from the ADB server.
- **No external services:** wADB uses your existing ADB server, keys, and pairings with no helper daemon, companion app, or relay.
- **Redacted support logs:** **About wADB → Share Logs** writes a local, reviewable text report with device details, IP addresses, and user paths replaced by placeholders. Nothing is uploaded automatically.

## Building from source

Requires Xcode 26 (or a compatible toolchain). `project.yml` is the [XcodeGen](https://github.com/yonaskolb/XcodeGen) source of truth:

```sh
xcodegen generate --spec project.yml
xcodebuild test -project wADB.xcodeproj -scheme wADB -configuration Debug
xcodebuild build -project wADB.xcodeproj -scheme wADB -configuration Debug
```

### Local deployment

Build, stop the running app and its `track-devices` observer, and install to `/Applications/wADB.app` (backing up the previous bundle in `/private/tmp`):

```sh
./scripts/deploy-local.sh
```

Local builds use ad-hoc signing by default. To sign with an Apple Developer team:

```sh
cp Config/Signing.local.xcconfig.example Config/Signing.local.xcconfig
# or pass the team ID for a one-off / CI build:
WADB_DEVELOPMENT_TEAM=YOURTEAMID ./scripts/deploy-local.sh
```

## Releases

Published builds are signed with Developer ID, notarized, and stapled, so
Gatekeeper accepts the DMG without warnings. Pushing a `vMAJOR.MINOR.PATCH` tag
on a commit in `main` runs the `Notarized release` workflow, which tests,
builds, notarizes, and publishes a GitHub Release with the DMG and a `.sha256`
checksum. Environment setup, secrets, versioning, and the local release script
are documented in [docs/RELEASING.md](docs/RELEASING.md).

## License

Licensed under the [Apache License, Version 2.0](LICENSE). See [NOTICE](NOTICE)
for copyright and third-party attribution.
