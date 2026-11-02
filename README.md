# Stillroom

Stillroom is a native Mac app that shows photos, videos, screenshots, and screen recordings that already live on that Mac. It reads them in place. It does not move, rename, modify, or delete your files, and it does not upload them.

This version is the library, plus local conversion and PDF tools. It reads files in place, and when you convert or export it writes a new file.

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

On Linux, install a Swift 6.1+ toolchain and `libsqlite3-dev` first. Apple-only code (PhotoKit, AppKit, ImageIO, AVFoundation, FSEvents) is compiled only where those frameworks exist.

## Convert and PDF

Convert takes files you drop on it, or the photos and videos selected in the grid, and writes a new file. Still images can become JPEG, PNG, HEIC, AVIF, WebP, or TIFF. Video can become MP4, HEVC (in a MOV file), a short GIF, or an M4A of the audio track. WebP and AVIF are offered only when ImageIO on that Mac can write them; otherwise the panel says so and writes nothing. Output goes next to the original or into a folder you pick, and an existing file is never replaced.

PDF turns photos into one new PDF, one picture per page, on A4, Letter, or a page fitted to the photo. Wide photos use a landscape page. Searchable text is optional and runs on the Mac. Straighten looks for a document page, corrects its perspective, and raises contrast before the crop you set. Separate PDFs can be merged into a new file. Scan with iPhone uses Continuity Camera when a phone on the same Apple ID is nearby; the scan is saved as a new file. There is no watermark.

## What this version does not do

Text search, similar-photo grouping, face grouping, highlights, and a hidden album are later work. They are not in this build.
