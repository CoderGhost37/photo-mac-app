import AppKit
import PhotoIndex
import SwiftUI
import UniformTypeIdentifiers

enum FileDrop {
    static func urls(from providers: [NSItemProvider]) async -> [URL] {
        var urls: [URL] = []
        for provider in providers {
            if let url = await load(provider) {
                urls.append(url)
            }
        }
        return urls
    }

    private static func load(_ provider: NSItemProvider) async -> URL? {
        if provider.canLoadObject(ofClass: URL.self) {
            return await withCheckedContinuation { continuation in
                _ = provider.loadObject(ofClass: URL.self) { object, _ in
                    continuation.resume(returning: object as? URL)
                }
            }
        }
        return await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                if let url = item as? URL {
                    continuation.resume(returning: url)
                } else if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}

enum ScanStore {
    static func directory() throws -> URL {
        let url = IndexLocation.scanDirectory(home: FileManager.default.homeDirectoryForCurrentUser)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Copies a scan into Stillroom's scan folder. The source file is left in place.
    static func keep(_ url: URL) throws -> URL {
        let directory = try directory()
        if url.deletingLastPathComponent().standardizedFileURL.path == directory.standardizedFileURL.path {
            return url
        }
        let ext = url.pathExtension.isEmpty ? "png" : url.pathExtension
        var reserved = Set<String>()
        let path = try OutputNamer.allocate(
            displayName: url.lastPathComponent,
            sourcePath: url.path,
            fileExtension: ext,
            directory: directory.path,
            reserved: &reserved,
            exists: { FileManager.default.fileExists(atPath: $0) },
            forbiddenPaths: [url.path]
        ).get()
        let destination = URL(fileURLWithPath: path)
        try FileManager.default.copyItem(at: url, to: destination)
        return destination
    }

    static func savePNG(_ image: NSImage) throws -> URL {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: .png, properties: [:]) else {
            throw PDFFailure.writeFailed("scan")
        }
        let directory = try directory()
        var reserved = Set<String>()
        let path = try OutputNamer.allocate(
            displayName: "Scan.png",
            sourcePath: nil,
            fileExtension: "png",
            directory: directory.path,
            reserved: &reserved,
            exists: { FileManager.default.fileExists(atPath: $0) }
        ).get()
        let destination = URL(fileURLWithPath: path)
        try OutputNamer.writeAtomically(to: destination) { partial in
            try data.write(to: partial)
        }
        return destination
    }
}

struct ContinuityScanButton: NSViewRepresentable {
    var onImages: ([URL]) -> Void

    func makeNSView(context: Context) -> ContinuityScanView {
        let view = ContinuityScanView()
        view.onImages = onImages
        return view
    }

    func updateNSView(_ view: ContinuityScanView, context: Context) {
        view.onImages = onImages
    }
}

final class ContinuityScanView: NSView {
    var onImages: ([URL]) -> Void = { _ in }
    private let button = NSButton(title: "Scan with iPhone", target: nil, action: nil)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        button.bezelStyle = .rounded
        button.target = self
        button.action = #selector(showMenu(_:))
        button.translatesAutoresizingMaskIntoConstraints = false
        addSubview(button)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: leadingAnchor),
            button.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { nil }

    @objc private func showMenu(_ sender: NSButton) {
        window?.makeFirstResponder(self)
        let menu = NSMenu()
        let item = NSMenuItem(
            title: "Scan with iPhone",
            action: Selector(("importFromDevice:")),
            keyEquivalent: ""
        )
        item.target = self
        menu.addItem(item)
        menu.popUp(positioning: item, at: NSPoint(x: 0, y: bounds.height + 4), in: self)
    }

    override func validRequestor(forSendType sendType: NSPasteboard.PasteboardType?, returnType: NSPasteboard.PasteboardType?) -> Any? {
        guard let returnType else {
            return super.validRequestor(forSendType: sendType, returnType: returnType)
        }
        if returnType == .fileURL || returnType == .pdf || NSImage.imageTypes.contains(returnType.rawValue) {
            return self
        }
        return super.validRequestor(forSendType: sendType, returnType: returnType)
    }

    @objc(readSelectionFromPasteboard:)
    func readSelection(from pasteboard: NSPasteboard) -> Bool {
        var stored: [URL] = []
        if let files = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] {
            for url in files {
                if let copy = try? ScanStore.keep(url) {
                    stored.append(copy)
                }
            }
        }
        if stored.isEmpty, let images = pasteboard.readObjects(forClasses: [NSImage.self]) as? [NSImage] {
            for image in images {
                if let url = try? ScanStore.savePNG(image) {
                    stored.append(url)
                }
            }
        }
        guard !stored.isEmpty else { return false }
        let callback = onImages
        DispatchQueue.main.async {
            callback(stored)
        }
        return true
    }
}
