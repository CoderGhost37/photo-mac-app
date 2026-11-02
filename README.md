# Stillroom

Stillroom is a native Mac app that shows photos, videos, screenshots, and screen recordings that already live on that Mac. It reads them in place. It does not move, rename, modify, or delete your files, and it does not upload them.

This version is the library, local conversion and PDF tools, and search. It reads files in place, and when you convert or export it writes a new file. Search reads text on the Mac and, if you install the description model, ranks pictures by that description. Nothing is uploaded.

## What it indexes

- Screenshots, from the folder in `com.apple.screencapture` (`location`). If that preference is unset, it uses `~/Desktop`.
- Screen recordings in that same folder (video files only).
- `~/Downloads`.
- The Photos library, through PhotoKit, read-only.
- Any folder you add. The choice is stored as a security-scoped bookmark so it still works after a relaunch or a rename.

Pictures and videos are classified as photos, videos, screenshots, or screen recordings. The sidebar shows a count for each source and each media type. The grid sorts newest first. The inspector shows the preview, dates, dimensions, file size, camera details, location, and path, and can reveal the file in Finder or open it.

The index is a SQLite database in `~/Library/Application Support/Stillroom/` on the Mac that is running the app. Thumbnails are cached beside it. Each Mac keeps its own index. There is no account, license, or sync.

## Build and run

You need a Mac with macOS 14 or later and Xcode 16.3 or any newer Xcode that includes Swift 6.1 (Xcode 26 is fine). The app runs on Apple silicon and Intel.

```bash
git clone <this-repo>
cd photo-mac-app
open Stillroom.xcodeproj
```

In Xcode, select the **Stillroom** scheme and **My Mac**, then press Run. Signing is set to “Sign to Run Locally” (`CODE_SIGN_IDENTITY = -`), so a paid developer team is not required.

The app is not sandboxed. A build you run yourself can read Desktop and Downloads directly. The first time the Photos library source is on, macOS asks for Photos access. PhotoKit only offers a read/write permission, and Stillroom never writes to the library. Choose **Add Folder…** for any other directory; that grant is remembered on that Mac only.

To put it on another Mac, clone the repo there and build it again. Do not copy the Application Support folder across machines. Each Mac indexes the files that are actually on its disk.

Core tests, which do not need Xcode:

```bash
swift test
```

On Linux, install a Swift 6.1+ toolchain and `libsqlite3-dev` first. Apple-only code (PhotoKit, AppKit, ImageIO, AVFoundation, Vision, Core ML, FSEvents) is compiled only where those frameworks exist.

## Convert and PDF

Convert takes files you drop on it, or the photos and videos selected in the grid, and writes a new file. Still images can become JPEG, PNG, HEIC, AVIF, WebP, or TIFF. Video can become MP4, HEVC (in a MOV file), a short GIF, or an M4A of the audio track. WebP and AVIF are offered only when ImageIO on that Mac can write them; otherwise the panel says so and writes nothing. Output goes next to the original or into a folder you pick, and an existing file is never replaced.

PDF turns photos into one new PDF, one picture per page, on A4, Letter, or a page fitted to the photo. Wide photos use a landscape page. Searchable text is optional and runs on the Mac. Straighten looks for a document page, corrects its perspective, and raises contrast before the crop you set. Separate PDFs can be merged into a new file. Scan with iPhone uses Continuity Camera when a phone on the same Apple ID is nearby; the scan is saved as a new file. There is no watermark.

## Search

Press ⌘F. The field matches words read from pictures, file names, place names already stored in the file, and dates (`june 2024`, `2024-06-15`, `today`, a year from 1900 through 2100). A month name on its own, such as `may`, is a word, not a date. Results are one grid, best match first.

Stillroom reads text in the background with Vision (`VNRecognizeTextRequest`, accurate, language correction). On macOS 14 that is revision 3, which includes handwriting. It stores each line with the asset id, the text, a normalized box, and a confidence, and indexes the text with SQLite FTS5. Only new or changed assets are read, on a background queue. Videos and screen recordings are skipped unless **Text in Videos** is on; that reads up to four frames. Original files are not modified.

Select a result and the inspector draws a box around each matched line. Hover a phrase and that box is the one that stays strong.

Place search uses IPTC sub-location, city, state, and country when ImageIO can read them. Coordinates are not turned into names, and there is no network lookup.

## Describing a picture

A description such as "a red bicycle" is ranked with OpenAI CLIP ViT-B/32, an image-and-text model with 512-length vectors. The weights are MIT licensed (Copyright 2021 OpenAI): <https://github.com/openai/CLIP/blob/main/LICENSE>. Apple's MobileCLIP weights are research-only, so they are not used. The same Core ML program is meant for Intel and Apple silicon (CPU and GPU, not Apple Intelligence).

The weights are not in this repository. On a Mac, run:

```bash
bash Scripts/fetch-clip.sh
```

That downloads the published checkpoint `ViT-B-32.pt` (SHA-256 `40d365715913c9da98579312b702a82c18be219cc2a73407c4526f58eba950af`) and the BPE merge list (gzip SHA-256 `924691ac288e54409236115652ad4aa250f48203de50a9e4722a6ecd48d6804a`), converts them with `Scripts/convert_clip.py`, compiles with `xcrun coremlcompiler`, and installs:

`~/Library/Application Support/Stillroom/Models/openai-clip-vit-b32/`

Pass `--output` to write that directory somewhere else, including an app-bundle resource of the same name. The install contains `ImageEncoder.mlmodelc`, `TextEncoder.mlmodelc`, `vocab.bpe`, and `checksums.sha256`. Stillroom checks those hashes before it loads the models and does not download them itself. Image embeddings are stored in the local index and reused until the file changes. A text match and a description match are blended (text 0.6, description 0.4).

The conversion script was not run where this repository was built. There is no Xcode there, so the Core ML programs are untested until you run the script on a Mac.

## What this version does not do

Similar-photo grouping, face grouping, highlights, and a hidden album are later work. They are not in this build.
