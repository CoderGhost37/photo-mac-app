# Stillroom

Stillroom is a native Mac app that shows photos, videos, screenshots, and screen recordings that already live on that Mac. It reads them in place. It does not move, rename, modify, or delete your files, and it does not upload them.

This version is the library, local conversion and PDF tools, search, a place map, people and pets, highlights, duplicate groups, a locked Hidden album, iPhone import, and WebP export. It reads files in place, and when you convert, export, or import from a device it writes a new file. Search reads text on the Mac and, if you install the description model, ranks pictures by that description. Faces, pets, labels, and duplicate prints are computed on the Mac. Nothing is uploaded.

## What it indexes

- Screenshots, from the folder in `com.apple.screencapture` (`location`). If that preference is unset, it uses `~/Desktop`.
- Screen recordings in that same folder (video files only).
- `~/Downloads`.
- The Photos library, through PhotoKit, read-only.
- CleanShot X and Shottr, when their preference files name a save folder that exists and is not already a source. CleanShot is read from `exportPath` in `pl.maketheweb.cleanshotx` (and the Setapp and `com.getcleanshot.app` domains). Shottr is read from its container preferences.
- Any folder you add. The choice is stored as a security-scoped bookmark so it still works after a relaunch or a rename.
- A folder you pick while importing from an iPhone. That folder becomes a source.

Pictures and videos are classified as photos, videos, screenshots, or screen recordings. The sidebar shows a count for each source and each media type. The grid sorts newest first. The inspector shows the preview, dates, dimensions, file size, camera details, location, and path, and can reveal the file in Finder or open it.

The index is a SQLite database in `~/Library/Application Support/Stillroom/` on the Mac that is running the app. Thumbnails are cached beside it. Each Mac keeps its own index. There is no account, license, or sync.

## Running it on more than one Mac

Each Mac builds or runs its own copy and keeps its own index. Do not copy `~/Library/Application Support/Stillroom/` between machines. The index only describes files on that Mac.

The straightforward way is to clone the repo on each Mac and build it there. An Xcode build matches the chip you built it on, so an Apple silicon build does not run on Intel, and the reverse.

To copy an already built app to another Mac of the same kind:

1. Copy `Stillroom.app` across.
2. The copy is ad-hoc signed (`Sign to Run Locally`). Gatekeeper will refuse a quarantined copy until you clear that and open it once:

```bash
xattr -dr com.apple.quarantine /path/to/Stillroom.app
codesign --force --deep --sign - /path/to/Stillroom.app
```

3. Right-click the app and choose Open the first time, then Open in the dialog. After that it launches normally. There is no developer team and no license check.

## Build and run

You need a Mac with macOS 14 or later and Xcode 16.3 or any newer Xcode that includes Swift 6.1 (Xcode 26 is fine). The app runs on Apple silicon and Intel.

```bash
git clone <this-repo>
cd photo-mac-app
open Stillroom.xcodeproj
```

In Xcode, select the **Stillroom** scheme and **My Mac**, then press Run. Signing is set to “Sign to Run Locally” (`CODE_SIGN_IDENTITY = -`), so a paid developer team is not required.

The app is not sandboxed. A build you run yourself can read Desktop and Downloads directly. The first time the Photos library source is on, macOS asks for Photos access. PhotoKit only offers a read/write permission, and Stillroom never writes to the library. Choose **Add Folder…** for any other directory; that grant is remembered on that Mac only.

To put it on another Mac, clone the repo there and build it again, or copy the `.app` as described above. Do not copy the Application Support folder across machines.

Core tests, which do not need Xcode:

```bash
swift test
```

On Linux, install a Swift 6.1+ toolchain and `libsqlite3-dev` first. Apple-only code (PhotoKit, AppKit, ImageIO, AVFoundation, Vision, Core ML, FSEvents, ImageCaptureCore, LocalAuthentication, IOKit) is compiled only where those frameworks exist. WebP encoding uses libwebp and is tested on Linux.

GitHub Actions runs `swift test` and `xcodebuild -project Stillroom.xcodeproj -scheme Stillroom -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" build` on `macos-latest` for pushes and pull requests. See `.github/workflows/macos.yml`.

## Convert and PDF

Convert takes files you drop on it, or the photos and videos selected in the grid, and writes a new file. Still images can become JPEG, PNG, HEIC, AVIF, WebP, or TIFF. Video can become MP4, HEVC (in a MOV file), a short GIF, or an M4A of the audio track. WebP is written with libwebp (BSD-3-Clause, https://github.com/the-swift-collective/libwebp). AVIF is offered only when ImageIO on that Mac can write it; otherwise the panel says so and writes nothing. Output goes next to the original or into a folder you pick, and an existing file is never replaced.

PDF turns photos into one new PDF, one picture per page, on A4, Letter, or a page fitted to the photo. Wide photos use a landscape page. Searchable text is optional and runs on the Mac. Straighten looks for a document page, corrects its perspective, and raises contrast before the crop you set. Separate PDFs can be merged into a new file. Scan with iPhone uses Continuity Camera when a phone on the same Apple ID is nearby; the scan is saved as a new file. There is no watermark.

## Search

Press ⌘F. The field matches words read from pictures, file names, place names already stored in the file, and dates (`june 2024`, `2024-06-15`, `today`, a year from 1900 through 2100). A month name on its own, such as `may`, is a word, not a date. Results are one grid, best match first.

Stillroom reads text in the background with Vision (`VNRecognizeTextRequest`, accurate, language correction). On macOS 14 that is revision 3, which includes handwriting. It stores each line with the asset id, the text, a normalized box, and a confidence, and indexes the text with SQLite FTS5. Only new or changed assets are read, on a background queue. Videos and screen recordings are skipped unless **Text in Videos** is on; that reads up to four frames. Original files are not modified.

Select a result and the inspector draws a box around each matched line. Hover a phrase and that box is the one that stays strong.

Place search uses IPTC sub-location, city, state, and country when ImageIO can read them. Coordinates are also turned into a place name with `CLGeocoder`, slowly and cached in the index, so a later search for that name hits. The lookup sends the coordinate to Apple. The photo stays on the Mac. A failed lookup is remembered for 30 days.

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

## Places

The sidebar Map shows every geotagged photo and video. Markers cluster on a grid and show a count. Zooming in uses smaller cells, so a marker splits. Click a marker to limit the grid to those photos. Map tiles come from Apple Maps.

## People and pets

Still photos and screenshots are read with Vision. Faces are found with `VNDetectFaceRectanglesRequest`, then clustered with an image feature print of each face crop. Cats and dogs use `VNRecognizeAnimalsRequest`, then an image feature print of the crop, and are clustered into individual pets when the prints are close. The sidebar lists each group and its count. You can rename a group, merge two groups of the same kind, or remove a photo from a group. Removing a photo does not delete the file, and the photo is not put back into that group on the next pass. Groups stay in the local index.

## Highlights

Stillroom builds stories from the index: For you, On this day, each earlier year on this calendar day, recent days, trips, people, pets, and food. A trip is a run of geotagged photos away from the most common location, close to each other in time and distance. Food comes from Vision labels and, when the description model is installed, from how close a photo is to "a plate of food". Open a story to play it full-window: the right side and the right arrow advance, the left side and the left arrow go back, it advances on its own, and the bars at the top show progress. Shuffle a memory picks a random set, preferring photos older than 30 days. Nothing is written.

## Duplicates

Duplicates, in the media types, groups exact copies by content hash and similar photos by the distance between image feature prints. Each group shows its count. You can open a photo or reveal it in Finder. There is no delete button. Stillroom does not remove files.

## Hidden

Hide a photo from the inspector, or from the menu on a thumbnail. It leaves the library, search, the map, people, highlights, and duplicates. The Hidden album in the sidebar shows it after Touch ID or the Mac password (`LocalAuthentication` policy `.deviceOwnerAuthentication`). The album locks when Stillroom goes inactive, and again 60 seconds after the last selection in the album. Hiding sets a flag in the local index. The file is not moved, renamed, or changed.

## iPhone over USB

Import from iPhone… looks for a camera with ImageCaptureCore. Plug the phone in with a cable, unlock it, and tap Trust. Choose a folder. Stillroom copies into `YYYY/MM` (or `undated` when the camera has no date), skips a file it has already copied or that is already in that folder with the same size, and never deletes anything on the device. The folder is added as a source.

## Background work

Indexing, text recognition, description embeddings, and face and pet reading pause while Low Power Mode is on, while the Mac is on battery at 20% or below, and while the thermal state is serious or critical. They continue when that clears. The toolbar says why the work is paused. A desktop Mac with no battery is not treated as low battery.
