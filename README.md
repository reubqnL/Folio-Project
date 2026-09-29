# <img src="assets/folio-app-icon.png" alt="The Folio icon: a sleek F with a vibrant yellow feather" width="72" align="top"> Folio is an AI-driven application

**The new 2-in-1 AI-driven Personal Project Management & Integrated Development Environment application.**

Folio combines a local-first Markdown knowledge workspace (**FolioNotes**) with an
integrated development environment (**FolioDev**) in one native macOS application.
It is written in Swift with SwiftUI, AppKit and Metal.

> **Status: development source, not a released product.** FolioNotes is the
> active focus and ships first; FolioDev is present in the interface but stays
> deliberately disabled until its real capabilities are ready. Nothing in this
> repository should be treated as production-ready yet — see
> [`docs/progress/PROGRESS.md`](docs/progress/PROGRESS.md) for the engineering
> status before relying on any part of it.

---

## What Folio is

### FolioNotes

A local-first personal project and knowledge management environment:

- **Markdown projects** — your notes remain plain Markdown files in a folder you
  choose; Folio never rewrites your front matter or moves files behind your back.
- **Editor & preview** — native Markdown editing with source, preview and split
  layouts; the preview updates smoothly as you type, refreshing only the part of
  the note that changed.
- **Repairable links** — links between notes resolve as you read them; links
  that are broken or point at several notes at once can be reviewed in one
  compact list and repaired one confirmation at a time, with the original link
  kept until you confirm a replacement.
- **Honest save states** — edits are reported as pending until the write is
  acknowledged on disk; a queued or timed write is never shown as saved, and
  local durability, archive checkpoints and sync are reported separately.
- **Search** — fast local full-text search across your project.
- **Command palette & shortcuts** — keyboard-first navigation, with protected
  mappings so remapping never breaks native editing shortcuts.
- **Roadmaps & timeline** — structured tasks and milestones with a timeline,
  Kanban-style board and an Unscheduled tray.
- **Connections graph** — a knowledge graph over notes, tasks and dependencies:
  2D by default, opt-in 3D.
- **AI-assisted capture** — review-first workflows that show exactly what context
  the assistant sees and require your approval before anything is written.
- **Voice capture** — on-device speech input with explicit recording controls and
  transcript review; a text entry path always remains available.
- **Encrypted projects (experimental)** — a single-file `.rdm` container with
  passphrase and recovery-code protection for sensitive project material.

### FolioDev

The long-term goal is to connect roadmap and project entities with real source
code: repository-linked notes, read-only source preview and traceable planning.
FolioDev is intentionally disabled in the current builds; it will be introduced
only when those capabilities actually exist. Folio will never present
functionality that is not implemented.

## Design

Folio is built to feel like a serious professional desktop application: the
knowledge-management and graph concepts of Obsidian, the information density and
workflow discipline of JetBrains IDEs, and a polished, high-contrast dark
macOS-native experience with smooth animations, clear hierarchy and careful
keyboard and mouse support. Its visual identity is the Folio **F** with the
vibrant yellow feather.

## Platform strategy

macOS is the first and current platform. Windows parity and an Android
read-only preview are planned only after the macOS product and its security
gates are complete — Folio is developed Mac-first rather than diluted across
platforms prematurely.

## Repository layout

```
Folio/
├── Package.swift        SwiftPM manifest (portable core, probes, tests)
├── project.yml          XcodeGen spec that generates the macOS app target
│
├── App/                 macOS application (SwiftUI / AppKit / Metal)
│   ├── Capture/         AI capture proposal + review flow
│   ├── Commands/        Command palette and shortcut preferences
│   ├── Editor/          Native Markdown editor and preview
│   ├── Encrypted/       Encrypted .rdm project UI and Keychain access
│   ├── Graph/           Knowledge graph view (Metal) and controller
│   ├── Planning/        Roadmap and timeline UI
│   ├── Search/          Local search index and UI
│   ├── Speech/          On-device voice capture
│   ├── Views/           Launcher, workspace, settings, recovery
│   └── Resources/       App icon and logo assets
│
├── Sources/             Portable core (Swift + C)
│   ├── FolioCore/       Storage, Markdown, search, graph, planning,
│   │                    capture, speech and encryption logic
│   ├── FolioFileIO/     C file I/O and lock-free audio ring buffer
│   ├── FolioRDMPrimitives/  C AES-256-GCM/HKDF and ZIP64 archive layer
│   ├── CArgon2/         Pinned upstream Argon2 reference implementation
│   ├── CSQLite/         System SQLite module map
│   └── Folio*Probe/     Executable probes used by the test scripts
│
├── Tests/               Unit and crash-recovery tests (XCTest + C harness)
├── scripts/             Build, test and verification automation
├── tools/               Packaging and verification tooling
├── assets/              Project branding (approved app icon)
│
├── docs/
│   ├── architecture/    Security and behaviour contracts
│   ├── planning/        Implementation plan, scope, recorded decisions
│   ├── progress/        Development status and completion estimate
│   ├── design/          Browser design prototype and concept captures
│   ├── reference/       Original baseline, roadmap workbook, handover notes
│   ├── notices/         Third-party licence notices
│   └── CHANGELOG.md     Release history
│
└── Evidence/            Generated test reports (not committed)
```

Generated and machine-specific files are excluded by
[`.gitignore`](.gitignore) and recreated on demand; nothing ignored is needed
to build from a clean clone.

## Building

### Core package and tests (macOS or Linux)

Requires Swift 6, Clang with sanitizer runtimes, and OpenSSL/SQLite3 development
libraries. On Linux, `bash scripts/setup-linux-swift.sh` installs a pinned
Swift 6.0.3 toolchain into `~/.cache` first.

```sh
bash scripts/test-core.sh
```

This runs the XCTest suite in Debug and Release, executes the storage, reading,
planning, capture and speech probes, and runs the C audio-ring harness under
AddressSanitizer and UndefinedBehaviorSanitizer. Reports are written to
`Evidence/`.

### Mac application

Requires an Apple Silicon Mac on macOS 26+ with Xcode 26+, Python 3 and
[XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
brew install xcodegen
bash scripts/verify-on-mac.sh
```

The script runs the core checks, generates `Folio.xcodeproj` from `project.yml`,
builds an ad-hoc-signed Debug app into `.build-output/`, and verifies the App
Sandbox, user-selected-file and audio-input entitlements are present.

> Ad-hoc signing is local development only. It is not Developer ID signing,
> notarization, an installer or production security approval. The bundle
> identifier `com.example.folio.development` is a placeholder and must be
> replaced before any distribution.

### Packaging a development source bundle

```sh
python3 tools/package-native.py
```

## Documentation

- [`docs/README.md`](docs/README.md) — index of all documentation
- [`docs/native-development.md`](docs/native-development.md) — native build and
  developer guide
- [`docs/CHANGELOG.md`](docs/CHANGELOG.md) — increment history
- [`docs/progress/PROGRESS.md`](docs/progress/PROGRESS.md) — development status
- [`docs/architecture/`](docs/architecture/) — security and behaviour contracts
  for storage, search, planning/graph, capture, speech and the encrypted container

## Security notes

- No credentials, keys or tokens are stored in this repository. Encryption
  passphrases are handled at runtime through the macOS Keychain
  (`App/Encrypted/EncryptedPassphraseKeychain.swift`); `App/Folio.entitlements`
  requests no network entitlement and there is no cloud fallback.
- The encrypted `.rdm` container and its encrypted local working copy are
  experimental and under active hardening. Read
  [`docs/architecture/ENCRYPTED-RDM-CONTRACT.md`](docs/architecture/ENCRYPTED-RDM-CONTRACT.md)
  before using them for anything sensitive. Plain-vault notes and roadmaps
  remain plaintext on disk.
- Third-party code is vendored under `Sources/CArgon2` with its licence and
  provenance recorded in [`docs/notices/`](docs/notices/).
