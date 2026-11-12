import AppKit

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
            try? await Task.sleep(nanoseconds: 90_000_000_000)
            exit(0)
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.appearance = NSAppearance(named: .darkAqua)
        NSApp.activate(ignoringOtherApps: true)
        UserDefaults.standard.set(true, forKey: "sidebar.mediaTypesExpanded")
        model.start()
        await settle(0.8)
        prepareWindow()
        await settle(0.6)
        capture("empty-state")

        await model.installScreenshotLibrary()
        model.timelineScale = .days
        model.sort = .newest
        model.selectAll()
        model.inspectorVisible = false
        await model.waitUntilSettled()
        await settle(1.6)
        prepareWindow()
        capture("all-photos")
        scrollSidebar(toEnd: true)
        await settle(0.5)
        capture("sidebar")
        scrollSidebar(toEnd: false)
        await settle(0.4)

        model.inspectorVisible = false
        model.selectPeople()
        model.highlightedSubjectID = model.subjectClusters.first { !$0.name.isEmpty }?.id ?? model.subjectClusters.first?.id
        await model.waitUntilSettled()
        scrollSidebar(toEnd: false)
        await settle(0.8)
        prepareWindow()
        capture("people")

        scrollSidebar(toEnd: false)
        model.selectAll()
        await model.waitUntilSettled()
        await settle(0.8)
        if let hero = model.assets.first(where: { $0.placeName != nil }) ?? model.assets.first {
            model.replaceSelection([hero], focused: hero)
            model.inspectorVisible = true
            await settle(1.4)
            prepareWindow()
            capture("inspector")
        }

        watchdog.cancel()
        NSApp.terminate(nil)
        exit(0)
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
        window.appearance = NSAppearance(named: .darkAqua)
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let width = min(1280, visible.width - 16)
        let height = min(820, visible.height - 16)
        window.setFrame(
            NSRect(x: visible.minX + 8, y: visible.minY + 8, width: width, height: height),
            display: true
        )
        window.makeKeyAndOrderFront(nil)
    }

    @MainActor
    private static func scrollSidebar(toEnd: Bool) {
        guard let content = (NSApp.keyWindow ?? NSApp.windows.first { $0.isVisible })?.contentView else { return }
        func walk(_ view: NSView) {
            if let scroll = view as? NSScrollView,
               scroll.frame.width < 420,
               scroll.frame.height > 180,
               let document = scroll.documentView {
                let clip = scroll.contentView
                let maxOffset = max(0, document.bounds.height - clip.bounds.height)
                let y: CGFloat
                if clip.isFlipped {
                    y = toEnd ? maxOffset : 0
                } else {
                    y = toEnd ? 0 : maxOffset
                }
                clip.scroll(to: NSPoint(x: 0, y: y))
                scroll.reflectScrolledClipView(clip)
                let anchorY = toEnd ? document.bounds.maxY - 1 : document.bounds.minY
                document.scrollToVisible(NSRect(x: 0, y: anchorY, width: 1, height: 1))
            }
            view.subviews.forEach(walk)
        }
        walk(content)
    }

    @MainActor
    private static func capture(_ name: String) {
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
            chosen = image
            break
        }
        guard var image = chosen else {
            print("screenshot \(name): no composited window image")
            fflush(stdout)
            return
        }
        if name == "sidebar" {
            image = cropSidebar(image) ?? image
        }
        let url = directory.appendingPathComponent("\(name).png")
        guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return }
        try? data.write(to: url)
        print("screenshot \(name): \(image.width)x\(image.height)")
        fflush(stdout)
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

    /// Window-server shots of an uncomposited sidebar come back white, and a missed surface is a rainbow edge.
    private static func isUsableWindowShot(_ image: CGImage) -> Bool {
        guard image.width > 400, image.height > 300, !isPlaceholder(image) else { return false }
        let side = averageColor(image, x: max(24, image.width / 12), y: image.height / 2)
        if side.0 > 200 && side.1 > 200 && side.2 > 200 { return false }
        let edge = averageColor(image, x: image.width - 16, y: image.height / 2)
        let spread = max(edge.0, edge.1, edge.2) - min(edge.0, edge.1, edge.2)
        if spread > 90 && max(edge.0, edge.1, edge.2) > 120 { return false }
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

    private static func cropSidebar(_ image: CGImage) -> CGImage? {
        let cropWidth = max(1, min(image.width, Int(Double(image.width) * 0.30)))
        return image.cropping(to: CGRect(x: 0, y: 0, width: cropWidth, height: image.height))
    }

    private static func settle(_ seconds: Double) async {
        let slices = max(1, Int(seconds / 0.1))
        for _ in 0..<slices {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }
}
