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
            try? await Task.sleep(nanoseconds: 90_000_000_000)
            exit(0)
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.appearance = NSAppearance(named: .darkAqua)
        NSApp.activate(ignoringOtherApps: true)
        model.start()
        await settle(0.8)
        prepareWindow()
        await settle(0.6)
        capture("empty-state", model: model)

        await model.installScreenshotLibrary()
        model.timelineScale = .days
        model.sort = .newest
        model.selectAll()
        model.inspectorVisible = false
        await model.waitUntilSettled()
        await settle(1.6)
        prepareWindow()
        capture("all-photos", model: model)
        capture("sidebar", model: model)

        if let hero = model.assets.first(where: { $0.placeName != nil }) ?? model.assets.first {
            model.replaceSelection([hero], focused: hero)
            model.inspectorVisible = true
            await settle(1.2)
            prepareWindow()
            capture("inspector", model: model)
        }

        model.inspectorVisible = false
        model.selectPeople()
        model.highlightedSubjectID = model.subjectClusters.first { !$0.name.isEmpty }?.id ?? model.subjectClusters.first?.id
        await model.waitUntilSettled()
        await settle(1.2)
        prepareWindow()
        capture("people", model: model)

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
        window.setFrame(NSRect(x: 40, y: 40, width: 1280, height: 820), display: true)
        window.makeKeyAndOrderFront(nil)
    }

    @MainActor
    private static func capture(_ name: String, model: AppModel) {
        guard let directory else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let window = NSApp.windows.first { $0.isVisible && $0.canBecomeMain } ?? NSApp.windows.first { $0.isVisible }
        var windowData: Data?
        if let window, let image = windowImage(window), colorVariance(image) > 12 {
            windowData = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        }
        let rendered = render(model: model)
        let chosen = larger(windowData, rendered)
        let url = directory.appendingPathComponent("\(name).png")
        if let chosen {
            try? chosen.write(to: url)
        }
    }

    @MainActor
    private static func render(model: AppModel) -> Data? {
        let renderer = ImageRenderer(
            content: RootView(model: model)
                .frame(width: 1280, height: 820)
                .environment(\.colorScheme, .dark)
        )
        renderer.scale = 2
        renderer.proposedSize = ProposedViewSize(width: 1280, height: 820)
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
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

    private static func colorVariance(_ image: CGImage) -> Double {
        guard let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return 0 }
        let length = CFDataGetLength(data)
        guard length > 64 else { return 0 }
        let step = max(4, length / 500)
        var total = 0.0
        var count = 0.0
        var index = 0
        while index < length {
            total += Double(bytes[index])
            count += 1
            index += step
        }
        guard count > 0 else { return 0 }
        let mean = total / count
        var sum = 0.0
        index = 0
        while index < length {
            let delta = Double(bytes[index]) - mean
            sum += delta * delta
            index += step
        }
        return sum / count
    }

    private static func larger(_ lhs: Data?, _ rhs: Data?) -> Data? {
        switch (lhs, rhs) {
        case let (left?, right?):
            return left.count >= right.count ? left : right
        case let (left?, nil):
            return left
        case let (nil, right?):
            return right
        case (nil, nil):
            return nil
        }
    }

    private static func settle(_ seconds: Double) async {
        let slices = max(1, Int(seconds / 0.1))
        for _ in 0..<slices {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }
}
