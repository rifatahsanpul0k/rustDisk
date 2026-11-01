# 🦀 RustDisk

**A high-performance macOS disk cleaner built with Rust and SwiftUI.**

[![CI](https://github.com/rifatahsanpul0k/rustDisk/actions/workflows/ci.yml/badge.svg)](https://github.com/rifatahsanpul0k/rustDisk/actions/workflows/ci.yml)
[![macOS](https://img.shields.io/badge/macOS-13%2B-blue?logo=apple)](https://www.apple.com/macos/)
[![License](https://img.shields.io/badge/license-MIT-green)](LICENSE)

---

## Why This Exists

Every MacBook Pro ships with 256 GB of storage. Between Xcode's ever-growing `DerivedData`, nested `node_modules` trees across dozens of dead projects, Homebrew caches, Python virtualenvs, and Docker's sparse virtual disk, the real reclaim opportunity is invisible inside macOS's native Storage UI.

RustDisk is a **systems-level answer to a systems-level problem.** It is written at the language layer where APFS block allocation is native — not wrapped in Electron, not throttled by a webview, not guessing from file metadata alone. The scanner uses actual Unix allocated blocks (`st_blocks × 512`) to surface *physical* disk pressure, not misleading logical sizes.

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│  SwiftUI Front-end  (macos-app/)                                    │
│  ┌───────────────────────────────────────────────────────────────┐  │
│  │  DiskAuditViewModel  →  NavigationTab  →  Audit Views         │  │
│  └────────────────────────────┬──────────────────────────────────┘  │
│                 UniFFI FFI Bridge  (generated Swift + C header)      │
│                 ↕  librustdisk_core.a  (static, zero .dylib)        │
│  ┌───────────────────────────────────────────────────────────────┐  │
│  │  Rust Engine  (rust-core/)                                    │  │
│  │  jwalk + rayon → multi-threaded APFS crawl                    │  │
│  │  BLAKE3 content hashing · System Armor blocklist              │  │
│  │  CleanupReport · Trash / permanent-delete modes               │  │
│  └───────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────┘
```

### Key Design Decisions

| Decision | Rationale |
|---|---|
| **Rust `staticlib`** | No dynamic linker path baked into the binary; ships as a single `.app` |
| **Mozilla UniFFI** | Type-safe, generated FFI — no hand-written C glue, no runtime marshalling surprises |
| **`jwalk` + `rayon`** | Parallel directory traversal saturates all P-cores on M-series; a 100 GB `~/Library` scans in seconds |
| **`st_blocks × 512`** | Physical APFS allocation, not `st_size`. HFS+ metadata forks and sparse files report correctly |
| **No daemon / no background service** | On-demand only — zero battery and privacy footprint when not actively scanning |

---

## Features

### 🧹 Smart Caches & Terminal Junk

Deep-enumerates known cache roots across every major toolchain category:

- **Homebrew** — formula/cask-level download cache and build intermediates
- **npm / pnpm / Yarn / Playwright / Cypress** — web ecosystem caches
- **pip / uv / Conda / PyPI / Torch / Hugging Face** — Python & ML caches
- **Gradle / Maven / JVM build** — Java ecosystem build caches
- **Cargo registry** — downloaded crate sources and build metadata
- **Xcode DerivedData + Simulator caches** — the single biggest reclaim on most developer Macs
- **macOS user logs** — `/Library/Logs` and app-specific log directories

Each item is individually enumerated (not a flat folder total), grouped into labelled sections, and shows both physical and logical size where they diverge.

---

### 📦 Stale Project Dependencies

Detects manifest-backed artifact directories that haven't seen *source-code activity* in 14, 30, 60, or 90 days (configurable):

- `node_modules` (requires sibling `package.json`)
- Python `.venv` / `env` (requires `requirements.txt`, `pyproject.toml`, etc.)
- Rust `target/` (requires sibling `Cargo.toml`)
- Swift `.build/` (requires `Package.swift`)
- JVM `build/` and `.gradle/` (requires `build.gradle`, `pom.xml`, etc.)

Ambiguous folders without a required sibling manifest are never flagged. Activity is checked **outside** all artifact trees — modifying a build output doesn't keep the project alive.

---

### 🔍 3-Tier Duplicate Finder

Identifies identical files using a staged pipeline that avoids hashing every byte of every file:

1. **Size clustering** — groups files by physical allocated size; different-size files cannot be duplicates
2. **8 KB edge hashing** — reads only the first and last 4 KB of each candidate; eliminates most non-duplicates without a full read
3. **Full BLAKE3 cryptographic hash** — only files that survive both filters are fully hashed

Duplicate *folders* are detected when all their children resolve to the same hash tree. Hardlinks are excluded from the reclaim estimate (they share blocks). One recommended original is protected in every group.

---

### 🛡️ Safety First: System Armor

Every path — both as written and after `canonicalize` resolves symlinks — is validated against a **case-insensitive** blocklist before any deletion is allowed:

| Protected Scope | Rule |
|---|---|
| OS & system binaries | `/System`, `/bin`, `/sbin`, `/usr`, `/Applications`, all of `/Library` |
| Third-party installs | `/opt` **except** strict children of `/opt/homebrew` |
| User accounts | `/Users` and every account home directory |
| Sensitive credentials | Any path component named `.git`, `.ssh`, `.gnupg`, `.aws` |
| Container VMs | `Docker.raw` in any casing |
| Relative traversal | Paths containing `..` are rejected outright |

**Resilient batch cleanup** via `CleanupReport`:
- Locked paths are skipped; unlocked siblings are still reclaimed
- Returns `trashed_physical_bytes` (still occupying the volume until Trash is emptied) and `permanently_freed_physical_bytes` (immediately reclaimed) as separate values
- The status banner reads *"Empty Trash to reclaim space"* after a Trash-mode run
- `cancel_active_scan()` is exported across FFI — cancels every running `jwalk` walker, `rayon` task, and BLAKE3 hash at its next cooperative check point

**Package uninstall safety:**
- Package names are validated against an allowlist (`[A-Za-z0-9\-_.@+]`, no leading `-`)
- The target path must be a **direct child** of the manager's install prefix — `cellar/name` cannot be combined with another package's actual path

---

## Installation

1. Go to [**Releases**](https://github.com/your-username/rustdisk/releases) and download `RustDisk-macos-arm64.dmg`
2. Verify the checksum (optional but recommended):
   ```bash
   shasum -a 256 -c RustDisk-macos-arm64.dmg.sha256
   ```
3. Open the `.dmg`, drag **RustDisk.app** into **Applications**
4. Launch RustDisk, then grant **Full Disk Access**:
   > **System Settings → Privacy & Security → Full Disk Access → enable RustDisk**

   Without Full Disk Access, protected container paths (Docker data directory, some app sandboxes) cannot be inspected.

> **Requirements:** macOS 13 Ventura or later · Apple Silicon (M1/M2/M3)

---

## Build from Source

### Prerequisites

- Rust (stable) with `aarch64-apple-darwin` target
- Xcode 15+ with Swift 5.9+

```bash
# 1. Clone
git clone https://github.com/your-username/rustdisk.git
cd rustdisk

# 2. Build the Rust static library and generate UniFFI Swift bindings
./scripts/build_rust_bridge.sh

# 3a. Open in Xcode (recommended)
open macos-app/Package.swift

# 3b. Or build from the command line
swift build --package-path macos-app --configuration debug --arch arm64
```

### Run checks locally

```bash
cargo fmt  --manifest-path rust-core/Cargo.toml -- --check
cargo test --manifest-path rust-core/Cargo.toml
swift build --package-path macos-app --configuration debug --arch arm64
```

### Package a release DMG

```bash
./scripts/package_dmg.sh
# → dist/RustDisk-macos-arm64.dmg
# → dist/RustDisk-macos-arm64.dmg.sha256
```

---

## Repository Layout

```
rust-core/                       Rust scanner, safety, package & cleaner engine
  src/lib.rs                     UniFFI interface surface (exported types & functions)
  src/scanner.rs                 jwalk + rayon APFS crawler
  src/duplicates.rs              3-tier duplicate detection pipeline
  src/cleaner.rs                 CleanupReport, System Armor, deletion modes
  src/packages.rs                Terminal package manager detection & measurement
  uniffi-bindgen.rs              CLI binary that drives UniFFI code generation

scripts/
  build_rust_bridge.sh           Compile aarch64 release → generate Swift bindings → stage .a
  package_release_app.sh         Build and sign dist/RustDisk.app
  package_dmg.sh                 Wrap app into a compressed, ad-hoc-signed DMG

macos-app/
  Package.swift                  SwiftPM manifest; links librustdisk_core.a by explicit path
  RustDisk/Generated/            Generated UniFFI Swift file + C header (not hand-edited)
  RustDiskCoreFFI/               SwiftPM system-library target for the generated C header
  lib/                           Staged librustdisk_core.a (git-ignored)
  RustDisk/ViewModels/           DiskAuditViewModel — single source of truth for UI state
  RustDisk/Views/                SwiftUI views (one file per tab)
```

---

## Tech Stack

| Layer | Technology |
|---|---|
| Scanner engine | Rust 1.x · `jwalk` · `rayon` · `blake3` · `libc` |
| Safety & cleanup | `trash` crate · custom System Armor blocklist |
| FFI bridge | Mozilla UniFFI 0.28 |
| Front-end | SwiftUI · Swift Package Manager |
| CI | GitHub Actions · `macos-14` (Apple Silicon) |

---

*Built to learn what actually lives on a developer's SSD — and to reclaim it safely.*
