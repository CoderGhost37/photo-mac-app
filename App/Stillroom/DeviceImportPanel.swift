import AppKit
import ImageCaptureCore
import PhotoIndex
import SwiftUI

struct CameraChoice: Identifiable, Equatable {
    var id: String
    var name: String
    var restricted: Bool
}

struct DeviceImportPanel: View {
    var model: AppModel
    var session: DeviceImportSession

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Import from iPhone")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Palette.inkColor)
            Text("Stillroom copies photos and videos into a folder you choose, in year and month folders. Files already imported are skipped. Nothing is deleted from the device.")
                .font(StillroomFont.metadata)
                .foregroundStyle(Palette.secondaryColor)
                .fixedSize(horizontal: false, vertical: true)

            if session.devices.isEmpty {
                Text(session.status)
                    .font(.callout)
            } else {
                Picker("Device", selection: Binding(
                    get: { session.selectedID ?? "" },
                    set: { session.select($0) }
                )) {
                    ForEach(session.devices) { device in
                        Text(device.restricted ? "\(device.name) (locked)" : device.name).tag(device.id)
                    }
                }
                Text(session.status)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("Choose Folder…") {
                    session.chooseFolder()
                }
                if let folder = session.folderPath {
                    Text(folder)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Button(session.running ? "Copying…" : "Import") {
                    session.beginImport(model: model)
                }
                .buttonStyle(.borderedProminent)
                .tint(Palette.accentColor)
                .disabled(session.folderPath == nil || session.fileCount == 0 || session.running || session.selectedIsRestricted)
                Spacer()
                Button("Close") {
                    model.presentedTool = nil
                }
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 520)
        .background(Palette.canvasColor)
        .onAppear { session.start() }
        .onDisappear { session.stop() }
    }
}

@MainActor
@Observable
final class DeviceImportSession: NSObject {
    private let browser = ICDeviceBrowser()
    private var cameras: [String: ICCameraDevice] = [:]
    private var cameraFiles: [String: ICCameraFile] = [:]
    private let bridge = DownloadBridge()

    var devices: [CameraChoice] = []
    var selectedID: String?
    var folderPath: String?
    var fileCount = 0
    var status = "Connect an iPhone with a cable, unlock it, and tap Trust."
    var running = false

    var selectedIsRestricted: Bool {
        devices.first { $0.id == selectedID }?.restricted == true
    }

    func start() {
        guard browser.delegate == nil else { return }
        browser.delegate = self
        browser.start()
    }

    func stop() {
        browser.delegate = nil
        browser.stop()
        for camera in cameras.values {
            camera.delegate = nil
        }
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Import Here"
        panel.message = "New files are copied into YYYY/MM folders. Existing files are not replaced or deleted."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        folderPath = SourceCatalog.normalizedDirectory(url).path
    }

    func select(_ id: String) {
        selectedID = id
        fileCount = 0
        cameraFiles = [:]
        guard let camera = cameras[id] else { return }
        camera.delegate = self
        if camera.isAccessRestrictedAppleDevice {
            status = "Unlock the iPhone and trust this Mac. Stillroom does not delete photos from it."
            return
        }
        if camera.hasOpenSession {
            loadFiles(from: camera)
            return
        }
        status = "Opening the device…"
        camera.requestOpenSession(options: nil) { [weak self] error in
            Task { @MainActor in
                if let error {
                    self?.status = error.localizedDescription
                }
            }
        }
    }

    func beginImport(model: AppModel) {
        guard !running, let selectedID, let camera = cameras[selectedID], let folderPath else { return }
        running = true
        let listed = cameraFiles
        let root = folderPath
        Task {
            let existing = DeviceImportPlan.existingSizes(in: URL(fileURLWithPath: root, isDirectory: true))
            let known = model.importSignatures()
            let files = listed.map { pair in
                deviceFile(pair.value, signature: pair.key)
            }
            let calendar = Calendar(identifier: .gregorian)
            let decisions = DeviceImportPlan.plan(
                files: files,
                existingSizes: existing,
                importedSignatures: known,
                calendar: calendar
            )
            var records: [(signature: String, relativePath: String)] = []
            var copied = 0
            var skipped = 0
            for decision in decisions {
                if decision.skip {
                    skipped += 1
                    records.append((signature: decision.file.signature, relativePath: decision.relativePath))
                    status = "Skipped \(skipped) already imported"
                    continue
                }
                guard let cameraFile = listed[decision.file.signature] else { continue }
                let request = DeviceImportPlan.downloadRequest(rootPath: root, relativePath: decision.relativePath)
                let directory = URL(fileURLWithPath: request.directoryPath, isDirectory: true)
                do {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    try await bridge.download(camera: camera, file: cameraFile, request: request)
                    copied += 1
                    records.append((signature: decision.file.signature, relativePath: decision.relativePath))
                    status = "Copied \(copied) · skipped \(skipped)"
                } catch {
                    status = "Could not copy \(request.fileName). Nothing on the device was deleted."
                }
            }
            model.recordDeviceImports(records)
            if copied > 0 || skipped > 0 {
                model.adoptImportFolder(URL(fileURLWithPath: root, isDirectory: true))
            }
            running = false
            status = "Copied \(copied). Skipped \(skipped) already here. Nothing was deleted from the device."
        }
    }

    private func remember(_ camera: ICCameraDevice) {
        let id = identity(camera)
        cameras[id] = camera
        camera.delegate = self
        publishDevices()
        if selectedID == nil {
            select(id)
        }
    }

    private func forget(_ device: ICDevice) {
        guard let camera = device as? ICCameraDevice else { return }
        let id = identity(camera)
        cameras[id] = nil
        if selectedID == id {
            selectedID = nil
            fileCount = 0
            cameraFiles = [:]
        }
        publishDevices()
        if devices.isEmpty {
            status = "Connect an iPhone with a cable, unlock it, and tap Trust."
        }
    }

    private func publishDevices() {
        devices = cameras.map { id, camera in
            CameraChoice(
                id: id,
                name: camera.name ?? "Camera",
                restricted: camera.isAccessRestrictedAppleDevice
            )
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func loadFiles(from camera: ICCameraDevice) {
        var listed: [String: ICCameraFile] = [:]
        for case let file as ICCameraFile in camera.mediaFiles ?? [] {
            let item = deviceFile(file, signature: nil)
            listed[item.signature] = file
        }
        cameraFiles = listed
        fileCount = listed.count
        if camera.isAccessRestrictedAppleDevice {
            status = "Unlock the iPhone and trust this Mac. Stillroom does not delete photos from it."
        } else if listed.isEmpty {
            status = "No photos on this device yet."
        } else {
            status = "\(listed.count) files. Choose a folder. Files already imported are skipped."
        }
    }

    private func identity(_ camera: ICCameraDevice) -> String {
        if let persistent = camera.persistentIDString, !persistent.isEmpty { return persistent }
        if let name = camera.name, !name.isEmpty { return name }
        return "camera"
    }

    private func deviceFile(_ file: ICCameraFile, signature: String?) -> DeviceFile {
        let name = file.name ?? "photo"
        let created = file.creationDate ?? file.modificationDate
        let item = DeviceFile(name: name, byteSize: Int64(truncatingIfNeeded: file.fileSize), createdAt: created)
        if let signature, item.signature != signature {
            return item
        }
        return item
    }
}

extension DeviceImportSession: ICDeviceBrowserDelegate {
    nonisolated func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        guard let camera = device as? ICCameraDevice else { return }
        Task { @MainActor in
            self.remember(camera)
        }
    }

    nonisolated func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        Task { @MainActor in
            self.forget(device)
        }
    }
}

extension DeviceImportSession: ICDeviceDelegate {
    nonisolated func device(_ device: ICDevice, didOpenSessionWithError error: (any Error)?) {
        guard let error else { return }
        Task { @MainActor in
            self.status = error.localizedDescription
        }
    }

    nonisolated func device(_: ICDevice, didCloseSessionWithError _: (any Error)?) {}

    nonisolated func didRemove(_: ICDevice) {}
}

extension DeviceImportSession: ICCameraDeviceDelegate {
    nonisolated func deviceDidBecomeReady(withCompleteContentCatalog device: ICCameraDevice) {
        Task { @MainActor in
            guard self.identity(device) == self.selectedID else { return }
            self.loadFiles(from: device)
        }
    }

    nonisolated func cameraDeviceDidRemoveAccessRestriction(_ device: ICDevice) {
        guard let camera = device as? ICCameraDevice else { return }
        Task { @MainActor in
            self.publishDevices()
            if self.identity(camera) == self.selectedID {
                self.select(self.identity(camera))
            }
        }
    }

    nonisolated func cameraDevice(_ camera: ICCameraDevice, didAdd _: [ICCameraItem]) {
        Task { @MainActor in
            guard self.identity(camera) == self.selectedID else { return }
            self.loadFiles(from: camera)
        }
    }

    nonisolated func cameraDevice(_ camera: ICCameraDevice, didRemove _: [ICCameraItem]) {
        Task { @MainActor in
            guard self.identity(camera) == self.selectedID else { return }
            self.loadFiles(from: camera)
        }
    }

    nonisolated func cameraDevice(_: ICCameraDevice, didReceiveThumbnail _: CGImage?, for _: ICCameraItem, error _: (any Error)?) {}

    nonisolated func cameraDevice(_: ICCameraDevice, didReceiveMetadata _: [AnyHashable: Any]?, for _: ICCameraItem, error _: (any Error)?) {}

    nonisolated func cameraDevice(_: ICCameraDevice, didRenameItems _: [ICCameraItem]) {}

    nonisolated func cameraDeviceDidChangeCapability(_: ICCameraDevice) {}

    nonisolated func cameraDevice(_: ICCameraDevice, didReceivePTPEvent _: Data) {}

    nonisolated func cameraDeviceDidEnableAccessRestriction(_ device: ICDevice) {
        guard let camera = device as? ICCameraDevice else { return }
        Task { @MainActor in
            self.publishDevices()
            if self.identity(camera) == self.selectedID {
                self.status = "Unlock the iPhone and trust this Mac. Stillroom does not delete photos from it."
            }
        }
    }
}

/// ImageCaptureCore copy. `deleteAfterDownload` is taken from the plan, which keeps it false.
private final class DownloadBridge: NSObject, ICCameraDeviceDownloadDelegate {
    private var continuation: CheckedContinuation<Void, Error>?

    func download(camera: ICCameraDevice, file: ICCameraFile, request: DeviceDownloadRequest) async throws {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let options: [ICDownloadOption: Any] = [
                .downloadsDirectoryURL: URL(fileURLWithPath: request.directoryPath, isDirectory: true),
                .saveAsFilename: request.fileName,
                .overwrite: NSNumber(value: request.overwrite),
                .deleteAfterSuccessfulDownload: NSNumber(value: request.deleteAfterDownload),
                .sidecarFiles: NSNumber(value: request.includeSidecars)
            ]
            camera.requestDownloadFile(
                file,
                options: options,
                downloadDelegate: self,
                didDownloadSelector: #selector(DownloadBridge.didDownloadFile(_:error:options:contextInfo:)),
                contextInfo: nil
            )
        }
    }

    @objc func didDownloadFile(
        _ file: ICCameraFile,
        error: Error?,
        options: [String: Any] = [:],
        contextInfo: UnsafeMutableRawPointer?
    ) {
        if let error {
            continuation?.resume(throwing: error)
        } else {
            continuation?.resume()
        }
        continuation = nil
    }
}
