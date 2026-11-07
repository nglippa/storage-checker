# Storage Monitor 2.3.0 marketing images

**2.3.0 build 11 — exact-source offscreen captures.**

These images render the real SwiftUI/AppKit views from the exact source commit used to build `Storage-Monitor-2.3.0-focus-filtering-candidate.dmg`. They use a fictional creative/developer workspace. File names, sizes, storage readings and project names are demonstration data, not a scan of a real person's Mac.

The app from the DMG was not launched. Native windows were never ordered, focused or activated. The capture process forbids activation and renders into offscreen bitmaps. These are source-rendered app views, not desktop screenshots of the running distribution binary. They do not certify native interaction or release acceptance.

- `originals/`: clean app-view captures at 2× resolution, without marketing copy.
- `marketing/`: the same captures on consistent presentation backgrounds with captions outside the app.
- `contact-sheet.png`: a numbered overview for choosing images.
- `shots.json`: filenames, captions, appearance and dimensions.
- `capture/`: reproducible capture code, demo fixture description, source provenance and render logs.

## Provenance

- DMG: `/Users/nicholaslippa/Downloads/Storage-Monitor-2.3.0-focus-filtering-candidate.dmg`.
- App version/build verified from its read-only-mounted Info.plist: **2.3.0 / 11**.
- DMG SHA-256: `f63adf3e207ff6cd9ad11ecbb9220e2187f6d11da06fb7a69faf634e9a645748`.
- Packaged viewer SHA-256: `263ae102463727eec8226305f87963d631984dc10c651354c91e180f1bbd9d1a`.
- Both hashes match the committed package receipt at `artifacts/structured-explorer-integration/focus-filtering/package-2.3.0/receipt.json`.
- Exact source commit: `a98fa0f487df0bcbf4501ea4b9fbfc2e2069c479`.
- Source tree: `73fd16a37e57a05c136bc194429d234892ca8eb3`.
- Capture build uses `STORAGE_MONITOR_DISTRIBUTION`. In an isolated generated copy of `StorageMonitorApp.swift`, the app's entry-point annotation is removed and `ViewerStore` constructs its live monitor using the existing injectable source initializer with a fictional 154.80 GB free / 1,000 GB total reading. `capture/prepare-source.py` records these two exact wiring substitutions. The real view implementations, monitor implementation and remaining candidate source are unchanged. This supplies consistent demo inputs without reading host capacity or showing an unavailable-reading placeholder.
- The candidate remains a local, ad-hoc-signed package. No release, install or deployment is implied.

## Reproduction

From the repository root, run `sh artifacts/marketing-2.3.0/capture/build-and-render.sh`. It exports the candidate source commit and creates a disposable database from the included schema under `/private/tmp/storage-marketing-230`. The Python script replaces all data in that disposable database with fictional demo data. The identity script creates empty placeholder files under `/private/tmp/Storage Monitor Demo 230` so Inspector identity checks refer to the correct disposable items; the displayed historical sizes remain fictional, and no large files are allocated. The shell script compiles the exact-source views and captures them without displaying any window. Appearance is applied only to the nonactivating capture process, as the real app does for its own windows.

## Image guide

Each filename is present in both `originals/` and `marketing/`. The clean versions are useful for your own layouts; presentation versions are 3,200 × 2,400 PNGs. Suggested starting images: 01, 02, 03, 13 and 14.

| File | Use case | Appearance |
|---|---|---|
| `01-storage-overview-dark.png` | Capacity and full-disk Living Tree overview | Dark |
| `02-storage-atlas-light.png` | Storage Atlas with proportional folder areas | Light |
| `03-developer-workspace.png` | Project folders and selected-folder Inspector | Dark |
| `04-media-library.png` | Movie-library exploration | Light |
| `05-largest-files.png` | Largest-file ranking | Dark |
| `06-largest-folders.png` | Largest-folder ranking | Light |
| `07-find-movies.png` | Name-prefix search, compact results viewport | Dark |
| `08-size-filter-dim.png` | Dim folders below 1 GB | Dark |
| `09-size-filter-hide.png` | Hide folders below 5 GB | Light |
| `10-path-to-root.png` | Highlight the selected folder's ancestry | Dark |
| `11-focus-on-folder.png` | Focus on a selected subtree | Light |
| `12-isolate-a-branch.png` | Isolate one branch of the hierarchy | Dark |
| `13-storage-history.png` | Recorded capacity chart and change history | Light |
| `14-recorded-change.png` | Selected recorded change with explanation Inspector | Light |
| `15-compact-explorer.png` | Compact Living Tree with Inspector hidden | Light |

Compile `capture/compose.swift` with `xcrun swiftc`, the macOS 26.5 SDK, target `arm64-apple-macos14.0` and a module cache under `/private/tmp`. Run the resulting executable with this asset folder as its argument to generate the presentation images and contact sheet from the clean originals. This step adds no content inside the app views.

## Verification limits

**NOT VERIFIED:** distribution app launch; native keyboard, mouse and trackpad delivery; displayed-window behavior; VoiceOver; installation and background monitoring registration. Those require separate authorized native acceptance checks. This task does not modify production databases, installed apps, LaunchAgents or the active QA worker.
