# disk-viz

Native macOS disk usage visualization built with Swift and SwiftUI.

The app scans a directory, renders its contents as a squarified treemap, and lets
you drill into large directories, collapse directories to compare siblings, and
delete files or folders from a native context menu.

## Features

- Native SwiftUI macOS app, with no JavaScript, Electron, Vite, or web runtime.
- Streaming filesystem scan with progress updates while results are discovered.
- Squarified treemap visualization with file-type colors and size-based shading.
- Breadcrumb navigation and Escape-to-parent drill-up behavior.
- Directory collapse state persisted with `UserDefaults`.
- Native directory picker and native delete confirmation.

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
