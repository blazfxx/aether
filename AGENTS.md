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

- No network code. Nothing is uploaded.
- Items flagged Review start unselected; orphaned-leftover matches are never preselected.
- Some locations need Full Disk Access; show the banner rather than failing silently. Admin tasks use the standard macOS password prompt.
- Add a check to `AetherCheck` for every new rule in `Remover` or the catalog.

## Releasing

Not set up yet. A release should: bump `VERSION` in `Scripts/build_app.sh`, run `Scripts/build_app.sh`, zip `build/Aether.app` with
`ditto -c -k --keepParent`, and attach it to a GitHub release (the Lantern and Erebus repos do this from a tag with a `release.yml`).
In the Blobby Launcher, Aether is listed as "coming soon" for macOS only (`UPCOMING` in `@blob/brand`).
