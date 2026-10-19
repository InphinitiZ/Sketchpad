import AppKit
import ImageCaptureCore
import Quartz
import UniformTypeIdentifiers

/// Paint's "From scanner or camera": lists connected scanners and cameras with ImageKit's
/// device views (the ones Image Capture uses). Each scan or downloaded photo opens as a new,
/// unsaved picture, as Paint opens an acquired image in place of a file.
final class DeviceImportWindowController: NSWindowController {
    static let shared = DeviceImportWindowController()

    private let browser = IKDeviceBrowserView()
    private let scannerView = IKScannerDeviceView()
    private let cameraView = IKCameraDeviceView()
    private let placeholder = NSTextField(labelWithString: localized("Select a scanner or camera."))
    private let deviceArea = NSView()
    /// Scans and photos land here and are deleted once opened.
    private let downloads = FileManager.default.temporaryDirectory.appendingPathComponent("Sketchpad Imports", isDirectory: true)

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 880, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: true
        )
        window.title = localized("From Scanner or Camera")
        window.minSize = NSSize(width: 640, height: 400)
        super.init(window: window)
        try? FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)

        browser.delegate = self
        browser.mode = .outline
        browser.displaysLocalScanners = true
        browser.displaysNetworkScanners = true
        browser.displaysLocalCameras = true
        browser.displaysNetworkCameras = false

        scannerView.delegate = self
        scannerView.transferMode = .fileBased
        scannerView.hasDisplayModeSimple = true
        scannerView.hasDisplayModeAdvanced = true
        scannerView.mode = .simple
        scannerView.displaysDownloadsDirectoryControl = false
        scannerView.displaysPostProcessApplicationControl = false
        scannerView.downloadsDirectory = downloads
        scannerView.documentName = localized("Scan")

        cameraView.delegate = self
        cameraView.transferMode = .fileBased
        cameraView.hasDisplayModeIcon = true
        cameraView.hasDisplayModeTable = true
        cameraView.mode = .icon
        cameraView.displaysDownloadsDirectoryControl = false
        cameraView.displaysPostProcessApplicationControl = false
        cameraView.downloadsDirectory = downloads

        placeholder.textColor = .secondaryLabelColor
        placeholder.alignment = .center

        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.addArrangedSubview(browser)
        split.addArrangedSubview(deviceArea)
        browser.widthAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true
        window.contentView = split
        split.setPosition(220, ofDividerAt: 0)
        show(placeholder)
        window.center()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// A new untitled picture holding the image file at `url`, marked as changed so closing
    /// it asks to save.
    static func makeDocument(fromImageAt url: URL) throws -> CanvasDocument {
        let type = NSDocumentController.shared.defaultType ?? UTType.png.identifier
        let document = try CanvasDocument(type: type)
        try document.read(from: Data(contentsOf: url), ofType: type)
        document.updateChangeCount(.changeDone)
        return document
    }

    private func show(_ view: NSView) {
        deviceArea.subviews.forEach { $0.removeFromSuperview() }
        view.translatesAutoresizingMaskIntoConstraints = false
        deviceArea.addSubview(view)
        if view === placeholder {
            NSLayoutConstraint.activate([
                view.centerXAnchor.constraint(equalTo: deviceArea.centerXAnchor),
                view.centerYAnchor.constraint(equalTo: deviceArea.centerYAnchor),
            ])
        } else {
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: deviceArea.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: deviceArea.trailingAnchor),
                view.topAnchor.constraint(equalTo: deviceArea.topAnchor),
                view.bottomAnchor.constraint(equalTo: deviceArea.bottomAnchor),
            ])
        }
    }

    private func open(_ url: URL?, error: Error?) {
        if let error {
            report(error)
            return
        }
        guard let url else { return }
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            let document = try Self.makeDocument(fromImageAt: url)
            NSDocumentController.shared.addDocument(document)
            document.makeWindowControllers()
            document.showWindows()
        } catch {
            report(error)
        }
    }

    private func report(_ error: Error) {
        guard let window else { return }
        presentError(error, modalFor: window, delegate: nil, didPresent: nil, contextInfo: nil)
    }
}

extension DeviceImportWindowController: IKDeviceBrowserViewDelegate {
    func deviceBrowserView(_ deviceBrowserView: IKDeviceBrowserView!, selectionDidChange device: ICDevice!) {
        if let scanner = device as? ICScannerDevice {
            scannerView.scannerDevice = scanner
            show(scannerView)
        } else if let camera = device as? ICCameraDevice {
            cameraView.cameraDevice = camera
            show(cameraView)
        } else {
            show(placeholder)
        }
    }

    func deviceBrowserView(_ deviceBrowserView: IKDeviceBrowserView!, didEncounterError error: Error!) {
        report(error)
    }
}

extension DeviceImportWindowController: IKScannerDeviceViewDelegate {
    func scannerDeviceView(_ scannerDeviceView: IKScannerDeviceView!, didScanTo url: URL!, error: Error!) {
        open(url, error: error)
    }

    func scannerDeviceView(_ scannerDeviceView: IKScannerDeviceView!, didEncounterError error: Error!) {
        report(error)
    }
}

extension DeviceImportWindowController: IKCameraDeviceViewDelegate {
    func cameraDeviceView(
        _ cameraDeviceView: IKCameraDeviceView!,
        didDownloadFile file: ICCameraFile!,
        location url: URL!,
        fileData data: Data!,
        error: Error!
    ) {
        open(url, error: error)
    }

    func cameraDeviceView(_ cameraDeviceView: IKCameraDeviceView!, didEncounterError error: Error!) {
        report(error)
    }
}
