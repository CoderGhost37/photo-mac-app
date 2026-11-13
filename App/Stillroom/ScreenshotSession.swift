import AppKit
import SwiftUI

/// Launched only when `STILLROOM_SCREENSHOTS` is set. Seeds a tiny library and writes window PNGs for CI.
enum ScreenshotSession {
    static var isEnabled: Bool {
        directory != nil
    }

    static var directory: URL? {
        guard let raw = ProcessInfo.processInfo.environment["STILLROOM_SCREENSHOTS"], !raw.isEmpty else { return nil }
        return URL(fileURLWithPath: raw, isDirectory: true)
    }

    @MainActor
    static func run(model: AppModel) async {
        let watchdog = Task {
            try? await Task.sleep(nanoseconds: 170_000_000_000)
            exit(0)
        }
        NSApp.setActivationPolicy(.regular)
        apply(.light, model: model)
        NSApp.activate(ignoringOtherApps: true)
        enlargeDisplay()
        await settle(0.4)
        UserDefaults.standard.set(true, forKey: "sidebar.mediaTypesExpanded")
        model.start()
        await settle(0.8)
        prepareWindow()
        await settle(0.5)
        capture("08-first-run")

        await model.installScreenshotLibrary()
        model.timelineScale = .days
        model.sort = .newest
        model.thumbnailSide = 210
        model.selectAll()
        model.inspectorVisible = false
        model.viewerAssetID = nil
        await model.waitUntilSettled()
        await settle(1.2)
        prepareWindow()
        capture("01-all-photos-light")

        apply(.dark, model: model)
        await settle(0.7)
        prepareWindow()
        capture("01-all-photos-dark")
        apply(.light, model: model)
        await settle(0.5)

        model.selectAll()
        await model.waitUntilSettled()
        if let hero = model.assets.first(where: { $0.placeName != nil }) ?? model.assets.first {
            model.openViewer(hero)
            model.inspectorVisible = true
            await settle(1.2)
            prepareWindow()
            capture("02-viewer")
            model.closeViewer()
            model.inspectorVisible = false
        }

        model.inspectorVisible = false
        model.selectAll()
        model.searchText = "Goa"
        model.find()
        // Search reloads after a short debounce. Capture the suggestion panel
        // on the current grid, then wait for the filtered results.
        await settle(0.12)
        prepareWindow()
        capture("03-search-suggestions")
        model.suggestionEpoch += 1
        resignFocus()
        await model.waitUntilSettled()
        await settle(0.8)
        prepareWindow()
        capture("03-search-results")
        model.searchText = ""
        model.searchTokens = []
        await model.waitUntilSettled()

        model.selectPlaces()
        await model.waitUntilSettled()
        await settle(0.8)
        if let fitted = MapGrid.fittingSpan(for: model.mapPoints) {
            let clusters = MapGrid.cluster(
                model.mapPoints,
                latitudeSpan: fitted.latitudeDelta,
                longitudeSpan: fitted.longitudeDelta
            )
            if let cluster = clusters.max(by: { $0.count < $1.count }) {
                model.focusPlaceCluster(cluster.memberIDs)
            }
        }
        await model.waitUntilSettled()
        await settle(0.8)
        prepareWindow()
        capture("04-places")

        model.selectPeople()
        await model.waitUntilSettled()
        model.highlightedSubjectID = model.subjectClusters.first { !$0.name.isEmpty }?.id ?? model.subjectClusters.first?.id
        await settle(0.6)
        prepareWindow()
        capture("05-people-pets")
        if let named = model.subjectClusters.first(where: { !$0.name.isEmpty }) ?? model.subjectClusters.first {
            model.openSubject(named.id)
            await model.waitUntilSettled()
            await settle(0.6)
            prepareWindow()
            capture("05-person")
        }

        model.selectMemories()
        await model.waitUntilSettled()
        await settle(0.7)
        prepareWindow()
        capture("06-memories")

        model.selectDuplicates()
        await model.waitUntilSettled()
        await settle(0.6)
        prepareWindow()
        capture("07-duplicates")

        model.selectAll()
        await model.waitUntilSettled()
        let sample = Array(model.assets.prefix(4))
        if !sample.isEmpty {
            model.replaceSelection(sample, focused: sample.first)
        }
        model.inspectorVisible = false
        model.openConvert()
        await settle(0.8)
        prepareWindow()
        capture("07-convert", includeSheet: true)
        model.presentedTool = nil
        await settle(0.4)

        model.selectAll()
        await model.waitUntilSettled()
        let pages = Array(model.assets.prefix(4))
        if !pages.isEmpty {
            model.replaceSelection(pages, focused: pages.first)
        }
        model.openPDF()
        await settle(0.8)
        prepareWindow()
        capture("07-make-pdf", includeSheet: true)
        model.presentedTool = nil
        await settle(0.3)

        model.selectHidden()
        await settle(0.5)
        prepareWindow()
        capture("09-hidden-locked")

        watchdog.cancel()
        NSApp.terminate(nil)
        exit(0)
    }

    @MainActor
    private static func apply(_ scheme: ColorScheme, model: AppModel) {
        model.forcedColorScheme = scheme
        let name: NSAppearance.Name = scheme == .dark ? .darkAqua : .aqua
        NSApp.appearance = NSAppearance(named: name)
        for window in NSApp.windows {
            window.appearance = NSAppearance(named: name)
        }
    }

    @MainActor
    private static func resignFocus() {
        NSApp.keyWindow?.makeFirstResponder(nil)
    }

    static func fixtures(now: Date) -> [(String, NSColor, NSSize, Date, String?)] {
        let calendar = Calendar.current
        func day(_ offset: Int, _ hour: Int) -> Date {
            let base = calendar.date(byAdding: .day, value: offset, to: now) ?? now
            return calendar.date(bySettingHour: hour, minute: 0, second: 0, of: base) ?? base
        }
        var items: [(String, NSColor, NSSize, Date, String?)] = []
        let hues: [CGFloat] = [0.58, 0.62, 0.72, 0.08, 0.12, 0.33, 0.45, 0.50, 0.78, 0.02, 0.55, 0.40]
        for index in 0..<6 {
            items.append((
                String(format: "goa-%02d.jpg", index),
                NSColor(calibratedHue: hues[index], saturation: 0.45, brightness: 0.78, alpha: 1),
                index.isMultiple(of: 2) ? NSSize(width: 960, height: 640) : NSSize(width: 640, height: 960),
                day(0, 9 + index),
                "Kushavati, Goa"
            ))
        }
        for index in 0..<3 {
            items.append((
                String(format: "panaji-%02d.jpg", index),
                NSColor(calibratedHue: hues[6 + index], saturation: 0.4, brightness: 0.7, alpha: 1),
                NSSize(width: 900, height: 600),
                day(-1, 11 + index),
                "Panaji"
            ))
        }
        for index in 0..<3 {
            items.append((
                String(format: "older-%02d.jpg", index),
                NSColor(calibratedHue: hues[9 + index], saturation: 0.35, brightness: 0.62, alpha: 1),
                NSSize(width: 800, height: 800),
                day(-40, 14),
                nil
            ))
        }
        return items
    }

    static func jpeg(color: NSColor, size: NSSize) -> Data? {
        let image = NSImage(size: size)
        image.lockFocus()
        color.setFill()
        NSRect(origin: .zero, size: size).fill()
        NSColor.black.withAlphaComponent(0.28).setFill()
        let oval = NSRect(x: size.width * 0.18, y: size.height * 0.22, width: size.width * 0.42, height: size.height * 0.46)
        NSBezierPath(ovalIn: oval).fill()
        NSColor.white.withAlphaComponent(0.85).setFill()
        NSBezierPath(ovalIn: NSRect(x: size.width * 0.62, y: size.height * 0.62, width: size.width * 0.16, height: size.width * 0.16)).fill()
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.82]) else { return nil }
        return data
    }

    @MainActor
    private static func prepareWindow() {
        NSApp.activate(ignoringOtherApps: true)
        let window = NSApp.windows.first { $0.canBecomeMain } ?? NSApp.windows.first
        guard let window else { return }
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        print("screenshot screen \(Int(visible.width))x\(Int(visible.height))")
        fflush(stdout)
        window.setFrame(
            NSRect(x: visible.minX, y: visible.maxY - 900, width: 1440, height: 900),
            display: true
        )
        window.makeKeyAndOrderFront(nil)
    }

    /// The runner's display is often smaller than the 1440×900 mockup. Pick a mode that can hold it.
    private static func enlargeDisplay() {
        let display = CGMainDisplayID()
        guard let modes = CGDisplayCopyAllDisplayModes(display, nil) else { return }
        let count = CFArrayGetCount(modes)
        var best: CGDisplayMode?
        var bestArea = Int.max
        for index in 0..<count {
            guard let pointer = CFArrayGetValueAtIndex(modes, index) else { continue }
            let mode = Unmanaged<CGDisplayMode>.fromOpaque(pointer).takeUnretainedValue()
            let width = mode.width
            let height = mode.height
            let area = width * height
            guard width >= 1600, height >= 1080, area < bestArea else { continue }
            best = mode
            bestArea = area
        }
        guard let best else {
            print("screenshot display: no mode at least 1440x900")
            fflush(stdout)
            return
        }
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else { return }
        CGConfigureDisplayWithDisplayMode(config, display, best, nil)
        let result = CGCompleteDisplayConfiguration(config, .forSession)
        print("screenshot display: \(best.width)x\(best.height) result \(result.rawValue)")
        fflush(stdout)
    }

    @MainActor
    private static func capture(_ name: String, includeSheet: Bool = false) {
        guard let directory else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var chosen: CGImage?
        for _ in 0..<16 {
            prepareWindow()
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            guard let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain })
                ?? NSApp.windows.first(where: \.isVisible),
                  let image = windowImage(window),
                  isUsableWindowShot(image) else { continue }
            if includeSheet, let sheet = sheetWindow(), let sheetImage = windowImage(sheet) {
                chosen = composite(base: image, overlay: sheetImage) ?? image
            } else {
                chosen = image
            }
            break
        }
        guard let image = chosen else {
            print("screenshot \(name): no composited window image")
            fflush(stdout)
            return
        }
        let url = directory.appendingPathComponent("\(name).png")
        guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return }
        try? data.write(to: url)
        print("screenshot \(name): \(image.width)x\(image.height)")
        fflush(stdout)
    }

    @MainActor
    private static func sheetWindow() -> NSWindow? {
        let main = NSApp.windows.first { $0.canBecomeMain && $0.isVisible }
        if let sheet = main?.attachedSheet ?? main?.sheets.first { return sheet }
        return NSApp.windows.first { $0.isVisible && $0.isSheet }
    }

    private static func composite(base: CGImage, overlay: CGImage) -> CGImage? {
        let width = base.width
        let height = base.height
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(base, in: CGRect(x: 0, y: 0, width: width, height: height))
        let scale = min(1, Double(width) * 0.78 / Double(overlay.width), Double(height) * 0.82 / Double(overlay.height))
        let drawnWidth = Double(overlay.width) * scale
        let drawnHeight = Double(overlay.height) * scale
        let rect = CGRect(
            x: (Double(width) - drawnWidth) / 2,
            y: (Double(height) - drawnHeight) / 2,
            width: drawnWidth,
            height: drawnHeight
        )
        context.setShadow(offset: CGSize(width: 0, height: -6), blur: 18, color: CGColor(gray: 0, alpha: 0.28))
        context.draw(overlay, in: rect)
        return context.makeImage()
    }

    private static func windowImage(_ window: NSWindow) -> CGImage? {
        guard window.windowNumber > 0 else { return nil }
        return CGWindowListCreateImage(
            .null,
            .optionIncludingWindow,
            CGWindowID(window.windowNumber),
            [.boundsIgnoreFraming, .bestResolution]
        )
    }

    /// The offscreen renderer draws a yellow field and a red prohibition mark. Never keep that.
    private static func isPlaceholder(_ image: CGImage) -> Bool {
        guard image.width > 32, image.height > 32,
              let data = image.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data) else { return true }
        let length = CFDataGetLength(data)
        let bytesPerRow = max(image.bytesPerRow, 1)
        let bytesPerPixel = max(image.bitsPerPixel / 8, 1)
        func sample(_ x: Int, _ y: Int) -> (Int, Int, Int) {
            let px = min(max(x, 0), image.width - 1)
            let py = min(max(y, 0), image.height - 1)
            let index = py * bytesPerRow + px * bytesPerPixel
            guard index + 2 < length else { return (0, 0, 0) }
            return (Int(bytes[index]), Int(bytes[index + 1]), Int(bytes[index + 2]))
        }
        func yellow(_ pixel: (Int, Int, Int)) -> Bool {
            let hi = max(pixel.0, pixel.1, pixel.2)
            let lo = min(pixel.0, pixel.1, pixel.2)
            return hi > 200 && lo < 50 && pixel.1 > 150
        }
        return yellow(sample(4, 4))
    }

    /// A missed surface is flat white, and an uncomposited edge is a rainbow.
    private static func isUsableWindowShot(_ image: CGImage) -> Bool {
        guard image.width > 400, image.height > 300, !isPlaceholder(image) else { return false }
        let edge = averageColor(image, x: image.width - 16, y: image.height / 2)
        let spread = max(edge.0, edge.1, edge.2) - min(edge.0, edge.1, edge.2)
        if spread > 90 && max(edge.0, edge.1, edge.2) > 120 { return false }
        let left = averageColor(image, x: max(24, image.width / 10), y: image.height / 2)
        let right = averageColor(image, x: image.width * 2 / 3, y: image.height / 3)
        let delta = abs(left.0 - right.0) + abs(left.1 - right.1) + abs(left.2 - right.2)
        if delta < 8 && left.0 > 245 && left.1 > 245 && left.2 > 245 { return false }
        return true
    }

    private static func averageColor(_ image: CGImage, x: Int, y: Int) -> (Int, Int, Int) {
        guard let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return (0, 0, 0) }
        let length = CFDataGetLength(data)
        let bytesPerRow = max(image.bytesPerRow, 1)
        let bytesPerPixel = max(image.bitsPerPixel / 8, 1)
        var total = (0, 0, 0)
        var count = 0
        for dy in -8...8 {
            for dx in -8...8 {
                let px = min(max(x + dx * 3, 0), image.width - 1)
                let py = min(max(y + dy * 3, 0), image.height - 1)
                let index = py * bytesPerRow + px * bytesPerPixel
                guard index + 2 < length else { continue }
                total.0 += Int(bytes[index])
                total.1 += Int(bytes[index + 1])
                total.2 += Int(bytes[index + 2])
                count += 1
            }
        }
        guard count > 0 else { return (0, 0, 0) }
        return (total.0 / count, total.1 / count, total.2 / count)
    }

    private static func settle(_ seconds: Double) async {
        let slices = max(1, Int(seconds / 0.1))
        for _ in 0..<slices {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }
}
