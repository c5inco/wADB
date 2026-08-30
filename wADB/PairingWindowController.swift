import AppKit
import CoreImage

enum PairingWindowError: LocalizedError {
    case qrGenerationFailed

    var errorDescription: String? { "The pairing QR code could not be created." }
}

final class PairingWindowController: NSWindowController, NSWindowDelegate {
    private enum Layout {
        static let width: CGFloat = 480
        static let waitingHeight: CGFloat = 476
        static let statusHeight: CGFloat = 156
        static let connectedHeight: CGFloat = 160
    }

    var onClose: (() -> Void)?

    private let instructionsLabel = NSTextField(wrappingLabelWithString: "On your Android phone, open:\nSettings → Developer options → Wireless debugging\nThen choose “Pair device with QR code” and scan below.")
    private let imageView = NSImageView()
    private let statusLabel = NSTextField(wrappingLabelWithString: "Waiting for your phone to scan the QR code…")
    private let successImageView = NSImageView()
    private let successLabel = NSTextField(wrappingLabelWithString: "")
    private let successView = NSStackView()
    private var qrBitmap: NSBitmapImageRep?
    private var suppressCloseCallback = false

    init() {
        let window = NSWindow(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: Layout.width,
                height: Layout.waitingHeight
            ),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Pair with wADB"
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.delegate = self
        configureContent(in: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func show(qrPayload: Data) throws {
        let (image, bitmap) = try Self.qrImage(from: qrPayload)
        qrBitmap = bitmap
        imageView.image = image
        imageView.isHidden = false
        instructionsLabel.isHidden = false
        statusLabel.stringValue = "Waiting for your phone to scan the QR code…"
        statusLabel.isHidden = false
        successView.isHidden = true
        setContentHeight(Layout.waitingHeight)
        showWindow(nil)
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }

    func clearQRCode() {
        if let bitmapData = qrBitmap?.bitmapData, let bytesPerRow = qrBitmap?.bytesPerRow,
           let pixelsHigh = qrBitmap?.pixelsHigh {
            memset(bitmapData, 0, bytesPerRow * pixelsHigh)
        }
        qrBitmap = nil
        imageView.image = nil
        imageView.isHidden = true
        setContentHeight(successView.isHidden ? Layout.statusHeight : Layout.connectedHeight)
    }

    func setStatus(_ text: String) {
        instructionsLabel.isHidden = false
        statusLabel.stringValue = text
        statusLabel.isHidden = false
        successView.isHidden = true
        if imageView.isHidden { setContentHeight(Layout.statusHeight) }
    }

    func showConnected(to deviceName: String) {
        instructionsLabel.isHidden = true
        statusLabel.isHidden = true
        successLabel.stringValue = "Connected to \(deviceName)."
        successView.isHidden = false
        clearQRCode()
    }

    func closeWithoutCancelling() {
        suppressCloseCallback = true
        close()
    }

    func windowWillClose(_ notification: Notification) {
        clearQRCode()
        if suppressCloseCallback {
            suppressCloseCallback = false
        } else {
            onClose?()
        }
    }

    private func configureContent(in window: NSWindow) {
        instructionsLabel.identifier = NSUserInterfaceItemIdentifier("pairing.instructions")
        instructionsLabel.alignment = .center
        instructionsLabel.textColor = .secondaryLabelColor
        instructionsLabel.maximumNumberOfLines = 4

        imageView.identifier = NSUserInterfaceItemIdentifier("pairing.qr")
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            imageView.widthAnchor.constraint(equalToConstant: 300),
            imageView.heightAnchor.constraint(equalToConstant: 300),
        ])

        statusLabel.identifier = NSUserInterfaceItemIdentifier("pairing.status")
        statusLabel.alignment = .center
        statusLabel.maximumNumberOfLines = 2

        successImageView.identifier = NSUserInterfaceItemIdentifier("pairing.successIcon")
        successImageView.image = NSImage(
            systemSymbolName: "checkmark.circle.fill",
            accessibilityDescription: "Connected"
        )
        successImageView.contentTintColor = .systemGreen
        successImageView.imageScaling = .scaleProportionallyUpOrDown
        successImageView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            successImageView.widthAnchor.constraint(equalToConstant: 56),
            successImageView.heightAnchor.constraint(equalToConstant: 56),
        ])

        successLabel.identifier = NSUserInterfaceItemIdentifier("pairing.successLabel")
        successLabel.alignment = .center
        successLabel.font = .systemFont(ofSize: 17, weight: .medium)
        successLabel.maximumNumberOfLines = 2

        successView.identifier = NSUserInterfaceItemIdentifier("pairing.success")
        successView.orientation = .vertical
        successView.alignment = .centerX
        successView.spacing = 12
        successView.addArrangedSubview(successImageView)
        successView.addArrangedSubview(successLabel)
        successView.isHidden = true

        let stack = NSStackView(views: [instructionsLabel, imageView, statusLabel, successView])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 18
        stack.setCustomSpacing(24, after: instructionsLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView?.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -32),
            stack.centerYAnchor.constraint(equalTo: window.contentView!.centerYAnchor),
            stack.topAnchor.constraint(greaterThanOrEqualTo: window.contentView!.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: window.contentView!.bottomAnchor, constant: -24),
        ])
    }

    private func setContentHeight(_ height: CGFloat) {
        guard let window, abs(window.contentLayoutRect.height - height) > 0.5 else { return }
        let oldFrame = window.frame
        let newSize = window.frameRect(
            forContentRect: NSRect(x: 0, y: 0, width: Layout.width, height: height)
        ).size
        let newFrame = NSRect(
            x: oldFrame.minX,
            y: oldFrame.maxY - newSize.height,
            width: newSize.width,
            height: newSize.height
        )
        window.setFrame(newFrame, display: window.isVisible)
    }

    private static func qrImage(from payload: Data) throws -> (NSImage, NSBitmapImageRep) {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else {
            throw PairingWindowError.qrGenerationFailed
        }
        filter.setValue(payload, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { throw PairingWindowError.qrGenerationFailed }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        let width = Int(scaled.extent.width)
        let height = Int(scaled.extent.height)
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: width * 4,
            bitsPerPixel: 32
        ), let bitmapData = bitmap.bitmapData else {
            throw PairingWindowError.qrGenerationFailed
        }
        let context = CIContext(options: [.useSoftwareRenderer: false])
        context.render(
            scaled,
            toBitmap: bitmapData,
            rowBytes: bitmap.bytesPerRow,
            bounds: scaled.extent,
            format: .RGBA8,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        let image = NSImage(size: NSSize(width: 300, height: 300))
        image.addRepresentation(bitmap)
        return (image, bitmap)
    }
}
