# disk-viz

Native macOS disk usage visualization built with Swift and SwiftUI.

The app scans the startup disk by default, renders each folder as a proportional
treemap, and keeps an exact list of the largest files found anywhere in the scan.
Other mounted volumes are available as explicit opt-in scan sources.

## Features

- Native SwiftUI macOS app, with no JavaScript, Electron, Vite, or web runtime.
- Startup-disk-first source picker with attached volumes kept opt-in.
- Volume-safe traversal that avoids external mounts and duplicate macOS APFS roots.
- Streaming folder, file, byte, and inaccessible-folder counters with Stop support.
- Squarified immediate-child treemap with breadcrumb and Escape-to-parent navigation.
- Live top-100 largest-files panel, including files deeper than the rendered tree.
- Finder reveal, path copy, and confirmed, recoverable Move to Trash actions.
- Preview-first cleanup dashboard with approximate opportunities for old Downloads,
  old DMG installers, developer caches, Xcode DerivedData, Docker, unavailable
  simulators, and Trash.
- Nothing is preselected. Filesystem cleanup moves only explicitly selected items
  to Trash, and DiskViz never empties Trash for you.
- Docker cleanup requires a separate permanent-action confirmation, excludes
  volumes, and leaves Docker disk-image resizing to Docker Desktop because lowering
  the maximum can destroy Docker data.

## Run

```bash
./script/build_and_run.sh
```

The script builds the Swift package, stages `dist/DiskViz.app`, and launches it
as a normal macOS app bundle.

You can pass an initial scan path for testing or focused scans:

```bash
./script/build_and_run.sh /Users/me/Projects
```

Useful variants:

```bash
./script/build_and_run.sh --verify
./script/build_and_run.sh --verify /Users/me/Projects
./script/build_and_run.sh --logs
./script/build_and_run.sh --debug
```

DiskViz reports folders macOS does not allow it to read. Grant the built app Full
Disk Access in System Settings if you want the most complete startup-disk result.

## Releases

GitHub releases are prepared locally as universal macOS apps and signed with
`Developer ID Application: Valentina Halasi (22YY6H28G3)`. The release pipeline
requires hardened runtime, a secure timestamp, Apple notarization, a stapled
ticket, Gatekeeper validation, and matching local/GitHub SHA-256 digests. It has
no unsigned or unnotarized publication path.

One-time setup stores the notarization credential in Keychain and enables
immutable GitHub Releases:

```bash
./script/release.sh setup-notary
./script/release.sh enable-immutable-releases
./script/release.sh doctor
```

`setup-notary` asks for the Apple ID and lets `notarytool` securely prompt for
the app-specific password. Do not put that password in the repository, shell
history, environment variables, or command arguments.

Prepare a release without changing GitHub:

```bash
./script/release.sh prepare 1.0.0
```

This runs tests, builds `arm64` and `x86_64`, signs the completed app, notarizes
and staples it, and writes the canonical ZIP, `SHA256SUMS`, and release manifest
to `release-artifacts/v1.0.0/`.

After reviewing those local artifacts, publish with:

```bash
./script/release.sh publish 1.0.0
```

Publication requires two explicit confirmations. It creates the annotated tag
locally, pushes only that tag, uploads a draft, verifies asset digests, publishes
the immutable release, and verifies GitHub's signed release attestation.

Verification can be safely resumed without changing a published release:

```bash
./script/release.sh verify 1.0.0
```
