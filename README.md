# PhotoMirror

[![CI](https://github.com/eugertjani-lab/amazon-photos-sync/actions/workflows/ci.yml/badge.svg)](https://github.com/eugertjani-lab/amazon-photos-sync/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/eugertjani-lab/amazon-photos-sync?sort=semver)](https://github.com/eugertjani-lab/amazon-photos-sync/releases/latest)

Sync your Amazon Photos back to your Mac so you always have a local backup, especially when several devices upload to Amazon Photos.

PhotoMirror is a Swift package with three front ends on one shared library: a command line tool called `apmirror`, an MCP server (`apmirror mcp`) that lets an AI assistant ask about your backup, and a macOS menu-bar app. The current milestone is read-only monitoring. PhotoMirror compares the photos and videos in your Amazon Photos account with the files on a backup drive, by MD5, and reports which items are backed up, which exist only online and which exist only on the drive. Downloading the missing items and signing in to Amazon directly are planned for later milestones (see the roadmap).

## Disclaimer

PhotoMirror is an unofficial community project. It is not affiliated with, endorsed by or supported by Amazon. "Amazon" and "Amazon Photos" are trademarks of Amazon.com, Inc. or its affiliates.

The tool reads the local index database that the Amazon Photos desktop app keeps on your computer. That file is an internal detail of the app, so Amazon can change its location or format at any time, and PhotoMirror may stop working without notice. It is intended for backing up your own account. Use it at your own risk, and keep more than one copy of anything you care about.

## How it works

The Amazon Photos desktop app for Mac keeps a SQLite catalog of your whole library (names, sizes, dates and MD5 checksums) in `~/Library/Application Support/Amazon Cloud Drive/`. The app has that database open and writes to it, so PhotoMirror never opens the original. Each refresh copies the database together with its `-wal` and `-shm` files into a private temporary folder, reads the copy and deletes it afterwards.

The catalog rows are copied into PhotoMirror's own database (`state.sqlite`). The backup drive is indexed the same way: a scan walks the drive, records the size and modification time of every file and computes an MD5 for each file that is new or has changed. Files that are already hashed are not read again. The drive is only ever opened for reading, and nothing is ever written to it.

A comparison by MD5 then gives these categories:

- In sync: a cloud photo or video whose MD5 matches a hashed file on the drive. One copy on the drive satisfies every cloud item with that MD5, so duplicates in the cloud do not show up as missing.
- Online only: a cloud photo or video with no matching file on the drive.
- Drive only: a hashed file on the drive whose MD5 is in neither the photo and video catalog nor the Live Photo video catalog.
- Live Photo videos: the video half of a Live Photo is reported as its own category with the same in sync and online only split, and is not included in the photo and video totals.

Years in the per-year table use the capture date from the catalog (the content date, or the creation date when there is none), interpreted as UTC. Trashed and purged items are ignored.

### Which drive files count

Only files inside the scan folder count. That folder is the drive root plus the optional scan subpath, for example `/Volumes/MyBackupDrive` plus `Amazon Photos Backup`. Index rows outside it are ignored by every report and removed by the next scan. Operating-system housekeeping is never indexed: `desktop.ini`, `Thumbs.db`, `.DS_Store`, files starting with `._`, and everything inside `$RECYCLE.BIN`, `System Volume Information`, `.Spotlight-V100`, `.fseventsd`, `.Trashes` and `.TemporaryItems`. The same rules apply to imported hash files, and rows that match them are removed on the next scan or import.

A scan that walks the whole scan folder also forgets files that have disappeared from the drive. It only does so when a successful folder listing proves the file is gone: either the file's own folder was listed without it, or an ancestor folder was listed without the sub-folder that contained it. A folder whose listing failed, even after the retries described below, never causes anything to be forgotten, so a drive that drops out cannot make real backups look missing. Scans that stop early (a file limit, or Stop in the app) never forget anything.

### Flaky drives

Some drives, for example NTFS volumes mounted through macOS's FSKit driver, drop out briefly and answer with "Input/output error", "Device not configured" or a spurious "No such file or directory". The scanner retries every directory listing and every file read up to five times, waiting 2, 4, 6, 8 and 10 seconds, before it records the error for that file and moves on. The next scan retries files that failed.

### Several programs at once

The command line tool, the MCP server and the menu-bar app can all use the same `state.sqlite`. The database runs in WAL mode with a 5 second busy timeout, readers never block, and write transactions are short: a catalog refresh reads the Amazon index into a temporary table first and only swaps it into place in one quick transaction.

## Install

### Download the app

Download `PhotoMirror-<version>-macos.zip` from the [latest release](https://github.com/eugertjani-lab/amazon-photos-sync/releases/latest), unzip it and move `PhotoMirror.app` to your Applications folder. The release build is made on an Apple silicon runner and needs macOS 14 or later. PhotoMirror reads the local index of the Amazon Photos desktop app, so that app has to be installed and signed in on the same Mac.

The app is ad-hoc signed and is not notarized by Apple, so macOS asks for confirmation on the first launch. Right-click `PhotoMirror.app`, choose Open and confirm the dialog. Newer macOS versions may show a dialog without an Open button; in that case use Open Anyway under System Settings, Privacy & Security. Alternatively, remove the quarantine flag that the download added and open the app normally:

```sh
xattr -dr com.apple.quarantine /Applications/PhotoMirror.app
```

### Download the command line tool

Each release also carries `apmirror-<version>-macos-universal.tar.gz` (Apple silicon and Intel, macOS 14 or later) and `apmirror-<version>-linux-x86_64.tar.gz`. Unpack the archive for your system and put `apmirror` somewhere on your `PATH`:

```sh
tar -xzf apmirror-<version>-macos-universal.tar.gz apmirror
sudo mv apmirror /usr/local/bin/
apmirror --version
```

A binary downloaded with a browser carries the quarantine flag as well; `xattr -d com.apple.quarantine apmirror` clears it. The Linux build links the Swift runtime dynamically and the system SQLite, so it needs a Swift 6 runtime and `libsqlite3` on the machine.

Every release has a `SHA256SUMS.txt` file. To check the files you downloaded, run this in the folder that holds them:

```sh
shasum -a 256 -c SHA256SUMS.txt --ignore-missing
```

### Build from source

Install a Swift 6.1 or newer toolchain, clone the repository and follow [Requirements and build](#requirements-and-build). In short, `swift build -c release` produces `.build/release/apmirror`, and `scripts/build-app.sh` produces `build/PhotoMirror.app`.

## Requirements and build

- macOS 14 or later, with a Swift 6.1 or newer toolchain (Xcode or the open source toolchain). Swift 6.1 is needed because the MCP Swift SDK declares tools version 6.1.
- Linux is a goal for the library, the command line tool and the MCP server, see the notes below.

```sh
swift build -c release
swift test
.build/release/apmirror --help
```

The command line binary is `.build/release/apmirror`. Copy it anywhere on your `PATH` if you like.

## Command line usage

```sh
# Tell PhotoMirror where the backup drive is. The optional subpath limits everything to one folder.
apmirror config set-drive /Volumes/MyBackupDrive --scan-subpath "Amazon Photos Backup"
apmirror config show

# Copy the cloud catalog from the Amazon Photos app index.
apmirror refresh-catalog

# Optional: import MD5s that another tool computed earlier, so they do not have to be recomputed.
apmirror import-hashes ~/hashes.csv --prefix "Amazon Photos Backup"

# Index the drive. Start with a quick metadata-only pass, then hash.
apmirror scan --no-hash --limit 2000
apmirror scan

# See how things stand.
apmirror status
apmirror status --json

# List the details.
apmirror online-only --year 2019 --limit 20
apmirror drive-only --limit 20 --json
```

`status` refreshes the cloud catalog first when the last refresh is more than ten minutes old; add `--no-refresh` to skip that. `--limit` on `scan` stops the run after that many files needed work (new, changed or not hashed yet), and files that are already up to date do not count, so repeated limited runs keep making progress.

`apmirror sync` is a placeholder for the future download feature. It prints a message and exits with code 2.

Example output of `apmirror status` (the numbers are made up):

```
PhotoMirror status
  Catalog as of:          2026-01-15 09:12 (3 min ago)
  Catalog refreshed:      2026-01-15 09:14
  Drive:                  /Volumes/MyBackupDrive / Amazon Photos Backup
  Drive mounted:          yes
  Last drive scan:        2026-01-14 21:30

Cloud photos and videos
  Total:                  120,000  (610.00 GB), 118,500 distinct MD5s
  In sync (on drive):     96,000  (480.00 GB)  80.0%
  Online only:            24,000  (130.00 GB)

Live Photo videos (counted separately)
  Total:                  9,000  (45.00 GB)
  In sync (on drive):     7,000  (35.00 GB)
  Online only:            2,000  (10.00 GB)

Drive
  Hashed files:           97,500
  Drive only:             120  (350.00 MB)  (hashed, not in the cloud)
  Not hashed yet:         0
  With errors:            0
```

### Hash CSV format

`import-hashes` reads a CSV with the header `path,size,md5,result`. The `path` column is relative to `<driveRoot>/<prefix>`, fields may be quoted when they contain commas, and the `result` column is free text. Rows with an empty MD5 or a size of -1 are stored as errors without a hash. Imported rows count as hashed. On the next scan the scanner keeps their hash and only fills in the real modification time, as long as the file size still matches.

## MCP server

`apmirror mcp` runs an MCP server on stdin and stdout, built on the official [MCP Swift SDK](https://github.com/modelcontextprotocol/swift-sdk). The server is called `photomirror` and offers these tools:

- `sync_status` returns the full report as JSON. The optional `refresh` argument re-reads the Amazon index first; by default that only happens when the last refresh is more than ten minutes old. The report includes `onlineOnlyDistinctBytes` (the space a full mirror still needs, counting each distinct MD5 once) and, while the drive is mounted on macOS, `driveSpace` (volume name, total and available bytes).
- `list_online_only` lists photos and videos that exist only in the cloud, with optional `year`, `limit` (default 50, at most 500) and `offset`.
- `list_drive_only` lists hashed drive files that are in no cloud catalog, with `limit` and `offset`.
- `breakdown_by_year` returns the per-year rows.
- `refresh_catalog` takes a fresh snapshot of the Amazon index and returns the counts.
- `scan_drive` indexes the drive incrementally. The `hash` argument (default true) switches MD5 computation on or off and `limit` (default 500, at most 5000) bounds the number of files that get work, so one call returns in reasonable time. The result says whether the whole drive was covered and how many files still have no hash; call it again to continue. Full scans of a big drive are better run from the command line or the app.

Problems such as an unmounted drive or a missing Amazon index come back as tool errors with a readable message.

Register it with Claude Code:

```sh
claude mcp add photomirror -- /path/to/apmirror mcp
```

Register it with Claude Desktop by adding this to `~/Library/Application Support/Claude/claude_desktop_config.json` and restarting the app:

```json
{
  "mcpServers": {
    "photomirror": {
      "command": "/path/to/apmirror",
      "args": ["mcp"]
    }
  }
}
```

## Menu-bar app (macOS)

`PhotoMirrorBar` is a SwiftUI menu-bar app that uses the same library directly. Build the app bundle with:

```sh
scripts/build-app.sh
open build/PhotoMirror.app
```

The script makes a release build, assembles `build/PhotoMirror.app` with an `Info.plist` (a menu-bar-only app, macOS 14 or later, version taken from the same constant as the command line tool) and signs it ad hoc. Because the signature is ad hoc, the app is meant for your own machine; distributing it would need a Developer ID signature and notarization.

The menu-bar item shows a checkmark cloud when everything is backed up, a cloud with a down arrow and a compact count (for example "185k") of the photos, videos and Live Photo videos that exist only in the cloud, a progress symbol while a scan runs, and a drive with a warning badge when the drive is not mounted or the catalog cannot be read. The symbols are template images, so the system tints them for light and dark menu bars.

The popover is 360 pt wide and follows the system appearance. It opens on a ring gauge with the in sync percentage and three figures (on your drive, only in the cloud, Live Photo videos), the five years with the most photos that are only in the cloud, a card with the drive's free space and whether a full mirror of the cloud would fit, and the catalog and scan status. A "Scan drive" button shows live progress and a Stop button while a scan runs, a refresh button re-reads the catalog, and a gear menu opens the settings, the data folder or quits. "All years" replaces the overview with a year map, one cell per year from 2000 on, with a blue fill for the share that is on the drive. The settings window chooses the drive folder, the scan subpath and an optional Amazon index override, and opens the data folder.

The app loads the report at launch, refreshes it every ten minutes and whenever a volume is mounted or unmounted. All database and scan work runs off the main thread.

To check the layout without clicking, render the popover with your real numbers into a PNG:

```sh
build/PhotoMirror.app/Contents/MacOS/PhotoMirror --render-snapshot build/snapshot-light.png
build/PhotoMirror.app/Contents/MacOS/PhotoMirror --render-snapshot build/snapshot-dark.png --dark
build/PhotoMirror.app/Contents/MacOS/PhotoMirror --render-snapshot build/snapshot-years-light.png --years
build/PhotoMirror.app/Contents/MacOS/PhotoMirror --render-snapshot build/snapshot-years-dark.png --years --dark
```

## Where PhotoMirror keeps its data

- macOS: `~/Library/Application Support/PhotoMirror/`
- Linux: `$XDG_DATA_HOME/photomirror`, or `~/.local/share/photomirror` when `XDG_DATA_HOME` is not set.

The folder holds `config.json` (drive root, optional scan subpath, optional explicit path of the Amazon Photos index) and `state.sqlite`. Setting the environment variable `PHOTOMIRROR_DATA_DIR` uses a different folder, which is handy for experiments. If the automatic detection of the Amazon Photos index picks the wrong file, point to the right one with `apmirror config set-index <path>`.

## Architecture

- `Sources/MirrorCore` is the library that everything else builds on: the SQLite wrapper, the catalog source for the Amazon Photos index (behind a `CloudCatalogSource` protocol so other sources can be added), the state store, the drive scanner, the CSV importer, the reconciler that produces a `SyncReport`, and `MirrorTools` with `MirrorToolRegistry`, the plain functions behind the MCP tools and the app.
- `Sources/apmirror` is the command line tool, built with swift-argument-parser. It also holds the thin adapter that exposes `MirrorToolRegistry` through the MCP Swift SDK, so the library itself has no MCP dependency.
- `Sources/PhotoMirrorBar` is the menu-bar app. It is declared only on macOS, so Linux builds skip it.
- `Sources/CSQLite` is a system library target that links the system SQLite on Linux. macOS uses the SQLite that ships with the SDK.
- `Tests/MirrorCoreTests` holds the unit tests, which run against a generated fake catalog and temporary folders.
- `scripts/build-app.sh` assembles the app bundle.

## Linux

The code is written to build on Linux: it uses the system SQLite through the `CSQLite` target (install `libsqlite3-dev`), swift-crypto for MD5 where CryptoKit is missing, and POSIX calls for file access. The menu-bar app is skipped there. Linux has no Amazon Photos desktop app, so you would copy the app's index files to the machine and select them with `apmirror config set-index`. Linux support has not been tested yet.

## Roadmap

- Sign in to Amazon Photos directly, so the catalog no longer depends on the desktop app's local index.
- Download online-only items to the drive (`apmirror sync`), from the command line, the MCP server and the menu-bar app.
- A signed and notarized build of the menu-bar app.
- Tested Linux support, for example running headless in a Proxmox container.

## License

MIT, see [LICENSE](LICENSE).
