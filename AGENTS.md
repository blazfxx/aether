# Aether: how to build, test and release (for AI agents and people)

Aether is a Mac cleaning and care suite in Swift and SwiftUI (macOS 14+). Command Line Tools are enough; Xcode is not needed.

## Where you can build

- **On a Mac:**
  - `swift build -c release --product Aether`
  - `swift run AetherCheck`: the engine checks (safety gate, treemap geometry, duplicate detection, catalog invariants). There is no XCTest
    in the Command Line Tools, which is why the checks are a plain executable. They must pass before any change to `AetherCore` merges.
  - `Scripts/build_app.sh` makes `build/Aether.app` (ad-hoc signed); `--install` also copies it to `/Applications`.
- **On Linux (the VPS) you cannot compile it.** Push to `main` and read the macOS CI run (`.github/workflows/ci.yml`, macos-15 because `Package.swift` needs Swift 6 tools):
  `gh run list -R blazfxx/aether`, then `gh run view <id> --log-failed`.

## Layout

- `Sources/AetherCore`: the engine, no UI. `Remover.swift` is the only code that deletes; everything goes through it
  (allowlist: home folder and `/Applications`; refuses `~`, `~/Documents`, `~/Library` and similar; resolves symlinks first).
  Do not add another delete path. Regenerable data (caches, logs) is deleted; anything a person might want back goes to the Trash.
- `Sources/Aether`: the SwiftUI app (one view per section, `Theme.swift` for the glass-orb look and aurora backdrops).
- `Sources/AetherCheck`: the engine checks.
- `Resources/AppIcon.svg` and `Resources/AppIcon.iconset`; `Scripts/render-icon.mjs` renders one from the other
  (`PLAYWRIGHT=<playwright-core/index.mjs> CHROME=<chrome> node Scripts/render-icon.mjs` from `Scripts/`).
  The same drawing as `AetherIcon` in the Blobby repo (`packages/brand`).

## Rules for changes

- Network use is limited to downloads that ask whether something newer exists: Aether's own releases on GitHub (`ReleaseFeed`),
  and other apps' versions from the App Store lookup or the app's own Sparkle feed (`AppUpdateChecker`). Never send anything about the
  user's files, folders or Mac, and never add other network calls. HTTPS only; no cookies.
- Items flagged Review start unselected; orphaned-leftover matches are never preselected.
- Some locations need Full Disk Access; show the banner rather than failing silently. Admin tasks use the standard macOS password prompt.
- Add a check to `AetherCheck` for every new rule in `Remover` or the catalog.

## Updates

- `SelfUpdater` (app) checks GitHub at launch and every 4 hours, downloads `Aether-X.Y.Z-macos.zip`, and `UpdateInstaller.stage` refuses anything that is
  not Aether (bundle ID), not the announced version, or has an invalid code signature. It also checks `<zip>.sha256` when the release has one.
  The swap runs in a separate `sh` after Aether quits and restores the old copy if it fails. Only copies in `/Applications` or `~/Applications`
  replace themselves; a developer build never does.
- Releases must stay named `Aether-X.Y.Z-macos.zip` with `Aether.app` at the top level, or the updater won't find them.
- To test the updater end to end: `AETHER_VERSION=1.0.0 Scripts/build_app.sh`, copy the app into `~/Applications`, launch it.
- The Uninstaller's Updates tab only *opens* the App Store page or the vendor's download; Aether never installs other apps' updates.

## Remembered choices

`SelectionMemory` stores what the user ticked or unticked (by path) so the next scan starts the same way. Every screen that offers
tick boxes for removable items should go through it, and "clean safe items" paths must respect it.

## Scanning rules (learned the hard way)

- Walk folders with `BulkDir` (`getattrlistbulk`), not `FileManager.enumerator` or per-file `resourceValues`. It scans a whole home folder
  (1.6 million items) in about 13 s; the Foundation walk took many minutes. `swift run AetherCheck --bench` prints the timings on this Mac.
- Never open a folder whose entry is `isDataless` (stored only in iCloud). Opening it makes macOS fetch the listing and can block for minutes.
- A thread blocked in `open()` cannot be interrupted, for example while macOS waits for the user to answer a privacy prompt.
  So async scan entry points return through a `ResultGate` that a stop request or time limit can finish early. Do not `await` the worker threads.
- Every scanning screen must show progress and a Stop button, and say so when nothing has moved for a few seconds (`ScanningView` does this).
- Reset a `ScanProgress` before reusing it, or an earlier Stop will cancel the next scan.

## Releasing

Tag `vX.Y.Z` (matching `VERSION` in `Scripts/build_app.sh`): `.github/workflows/release.yml` builds and attaches `Aether-X.Y.Z-macos.zip`. By hand, a release is: bump `VERSION` in `Scripts/build_app.sh`, run `Scripts/build_app.sh`, zip `build/Aether.app` with
`ditto -c -k --keepParent`, and attach it to a GitHub release (the Lantern and Erebus repos do this from a tag with a `release.yml`).
In the Blobby Launcher, Aether is listed as "coming soon" for macOS only (`UPCOMING` in `@blob/brand`).
