# Aether

A Mac cleaning and care suite for macOS 14+, written in Swift and SwiftUI. Glass-orb UI, one aurora backdrop per section.

| Section | What it does |
|---|---|
| **Smart Scan** | One pass over junk, privacy traces, large files and startup items, with a one-click "clean safe junk" |
| **Mac Health** | Live CPU, memory, disk, battery and network, a health score, and what to fix |
| **System Junk** | Caches, logs, crash reports, Xcode and developer caches, Trash, old installers, Mail downloads, device backups |
| **Privacy** | Browser history, cookies and cache (Safari, Chrome, Edge, Brave, Arc, Firefox), recent items, shell history |
| **Large & Old Files** | Biggest files in your main folders and how long since you opened them |
| **Duplicates** | Byte-for-byte duplicate finder; always keeps at least one copy |
| **Space Lens** | Treemap of disk usage with drill-down |
| **Uninstaller** | Removes an app plus its leftover files; finds orphaned leftovers from apps already gone |
| **Startup Items** | Launch agents and login items, with code-signature checks |
| **Maintenance** | DNS flush, Spotlight reindex, Launch Services rebuild, Quick Look reset |
| **Menu bar** | Live stats and Quick Clean |

## Safety

Every deletion goes through one function, `Remover`, which enforces an allowlist (your home folder and `/Applications`), refuses protected folders (`~`, `~/Documents`, `~/Library`, ...), and resolves symlinks so a link can't point it outside the allowlist.

- Regenerable data (caches, logs) is deleted permanently.
- Anything you might want back (large files, duplicates, apps, leftovers, installers, backups) goes to the **Trash**.
- Items flagged *Review* start unselected. Orphaned-leftover matches are never preselected.
- Nothing is uploaded. There is no network code.

## Build

Command Line Tools are enough; Xcode is not required.

```sh
Scripts/build_app.sh             # -> build/Aether.app (ad-hoc signed)
Scripts/build_app.sh --install   # also copies it to /Applications
```

Engine checks (safety gate, treemap geometry, duplicate detection, catalog invariants):

```sh
swift run AetherCheck
```

(Command Line Tools ship no XCTest, so the checks are a plain executable.)

## Layout

```
Sources/AetherCore    scanning, sizing, safety gate, system sampling (no UI)
Sources/Aether        SwiftUI app: theme, models, one view file per section
Sources/AetherCheck   engine checks
Scripts/              build_app.sh, render-icon.mjs (the icon is Resources/AppIcon.svg)
```

## Permissions

Some locations (Trash, Mail downloads, device backups) need **Full Disk Access**; Aether shows a banner with a link to the setting. Admin-level maintenance tasks ask for your password through the standard macOS prompt.
