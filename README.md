# Apple Notes → Obsidian Exporter

A bash script that exports all your Apple Notes to Markdown files with images, ready to drop into an Obsidian vault.

## The problem

Apple Notes has no good/perfect built-in export. Third-party tools often miss images, fail on large libraries, or require paid licenses. This script handles everything — text, inline images, PDFs, audio files — using only standard macOS tools.

## How it works

The script uses a **dual extraction strategy**:

1. **Images (base64)** — Apple Notes embeds images as base64 data directly in the HTML body. The script decodes these and saves them as separate image files. **This works without any special permissions.**

2. **Non-image files (PDF, audio, etc.)** — These are stored on the filesystem in `~/Library/Group Containers/group.com.apple.notes/`. The script queries the `NoteStore.sqlite` database to locate exact file paths, then copies them directly. **This requires Full Disk Access.**

```
Apple Notes
    │
    ├── AppleScript → HTML body (with base64 images)
    │       │
    │       ├── Python → extract base64 → image_1.png, image_2.jpg, ...
    │       └── pandoc → convert HTML → Markdown
    │
    └── NoteStore.sqlite → media file paths
            │
            └── cp → PDFs, audio, drawings, ...
```

### Output structure

```
OutputDir/
├── iCloud/
│   ├── FolderName/
│   │   ├── Note Title.md
│   │   ├── Another Note.md
│   │   └── _attachments/
│   │       ├── Note Title/
│   │       │   ├── image_1.png
│   │       │   └── image_2.jpg
│   │       └── Another Note/
│   │           └── document.pdf
│   └── AnotherFolder/
│       └── ...
├── _export_log_20260222_143000.txt
├── _export_errors_20260222_143000.txt
└── _export_stats_20260222_143000.txt
```

Each Markdown file includes YAML frontmatter:

```yaml
---
title: "My Note"
created: "Monday, January 15, 2024 at 10:30:00 AM"
modified: "Friday, February 21, 2025 at 3:45:00 PM"
source: "Apple Notes"
apple_notes_id: "x-coredata://UUID/ICNote/p1234"
attachments: 3
export_date: "2026-02-22T14:30:00Z"
---
```

Images are referenced using Obsidian's wiki-link syntax: `![[_attachments/Note Title/image_1.png]]`

## Requirements

- **macOS** (tested on Sonoma / Sequoia / Tahoe)
- **Notes.app** with notes you want to export
- **pandoc** — `brew install pandoc`
- **python3** — included with macOS
- **Full Disk Access** — optional but recommended (required for PDF/audio export)

## Usage

```bash
# Basic usage (exports to ~/Desktop/AppleNotes_Export)
./export_apple_notes.sh

# Specify output directory
./export_apple_notes.sh ~/Documents/MyNotesExport

# Force English output
EXPORT_LANG=en ./export_apple_notes.sh

# Force French output
EXPORT_LANG=fr ./export_apple_notes.sh
```

The script auto-detects your system language (French/English) for all output messages.

## Enabling Full Disk Access

Without Full Disk Access, the script still exports **all notes and all inline images**. To also export PDFs, audio files, and other non-image attachments:

1. Open **System Settings** → **Privacy & Security** → **Full Disk Access**
2. Enable the toggle for your terminal app (Terminal, iTerm2, VS Code, etc.)
3. **Restart your terminal app**
4. Re-run the script

The script will tell you if FDA is missing and what you'll be missing without it.

## Performance

- **Inventory phase**: ~30 seconds (scans all notes via AppleScript)
- **Export phase**: ~1-2 seconds per note (AppleScript HTML extraction + base64 decode + pandoc conversion)
- **A library of ~1600 notes** takes approximately 30-50 minutes

## What it handles

- Inline images (PNG, JPEG, GIF, SVG, HEIC, WebP)
- PDF attachments
- Audio/video files
- Apple Pencil drawings
- Nested folder structures
- Duplicate note names (auto-suffixed)
- Password-protected notes (skipped with a count)
- Special characters in note/folder names
- Notes across multiple accounts
- Very large notes (multi-MB HTML)

## What it doesn't handle

- Password-protected notes (Apple doesn't expose their content via AppleScript)
- Notes stored only in iCloud and not downloaded locally (attachment files)
- Checklists (exported as plain text lists)
- Tables in some complex layouts
- Shared/collaborative note metadata

## Troubleshooting

**"Operation not permitted" errors in the log**
→ Enable Full Disk Access for your terminal app (see above).

**Some images are missing**
→ If notes were created on another device and images haven't synced, they won't be available locally. Open the note in Notes.app to trigger a download, then re-export.

**Script takes very long**
→ Each note requires an individual AppleScript call. This is a limitation of the Notes.app API. ~1600 notes ≈ 30-50 minutes.

**pandoc not found**
→ Install with `brew install pandoc`. If you don't have Homebrew: https://brew.sh

## License

MIT
