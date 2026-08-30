import AppKit
import XCTest
@testable import wADB

@MainActor
final class PairingWindowControllerTests: XCTestCase {
    func testWindowUsesNativeTitleWithoutDuplicateContentHeading() {
        let controller = PairingWindowController()
        let window = tryUnwrap(controller.window)

        XCTAssertEqual(window.title, "Pair with wADB")
        XCTAssertTrue(window.styleMask.contains(.titled))
        XCTAssertTrue(window.styleMask.contains(.closable))
        XCTAssertFalse(window.styleMask.contains(.resizable))
        XCTAssertFalse(textFields(in: window).contains {
            $0.stringValue == "Pair with wADB"
        })
    }

    func testWaitingAndLongestErrorLayoutsFitWithoutExcessSpace() throws {
        let controller = PairingWindowController()
        let window = tryUnwrap(controller.window)
        try controller.show(qrPayload: Data("test QR payload".utf8))
        defer { controller.closeWithoutCancelling() }

        layout(window)
        XCTAssertEqual(window.contentLayoutRect.height, 476, accuracy: 0.5)
        assertFits(identifier: "pairing.instructions", in: window)
        assertFits(identifier: "pairing.qr", in: window)
        assertFits(identifier: "pairing.status", in: window)

        controller.clearQRCode()
        controller.setStatus(tryUnwrap(PairingCoordinatorError.connectionTimedOut.errorDescription))
        layout(window)

        XCTAssertEqual(window.contentLayoutRect.height, 156, accuracy: 0.5)
        let status = tryUnwrap(view(identifier: "pairing.status", in: window))
        XCTAssertFalse(status.isHidden)
        assertFits(identifier: "pairing.instructions", in: window)
        assertFits(identifier: "pairing.status", in: window)
    }

    func testConnectedPresentationShowsCheckmarkAndUsesApprovedCloseDelay() throws {
        let controller = PairingWindowController()
        let window = tryUnwrap(controller.window)

        controller.showConnected(to: "Example Phone")
        layout(window)

        XCTAssertEqual(PairingCoordinator.connectedPresentationDuration, 2.5)
        XCTAssertEqual(window.contentLayoutRect.height, 160, accuracy: 0.5)
        XCTAssertTrue(tryUnwrap(view(identifier: "pairing.instructions", in: window)).isHidden)
        XCTAssertTrue(tryUnwrap(view(identifier: "pairing.qr", in: window)).isHidden)
        XCTAssertTrue(tryUnwrap(view(identifier: "pairing.status", in: window)).isHidden)
        XCTAssertFalse(textFields(in: window).contains {
            !$0.isHidden && $0.stringValue.contains("Pair device with QR code")
        })
        XCTAssertFalse(tryUnwrap(view(identifier: "pairing.successIcon", in: window)).isHidden)
        let label = tryUnwrap(
            view(identifier: "pairing.successLabel", in: window) as? NSTextField
        )
        XCTAssertEqual(label.stringValue, "Connected to Example Phone.")
        let contentView = tryUnwrap(window.contentView)
        let successView = tryUnwrap(view(identifier: "pairing.success", in: window))
        let successFrame = successView.convert(successView.bounds, to: contentView)
        XCTAssertEqual(successFrame.midY, contentView.bounds.midY, accuracy: 0.5)
        assertFits(identifier: "pairing.successIcon", in: window)
        assertFits(identifier: "pairing.successLabel", in: window)
    }

    private func layout(_ window: NSWindow) {
        window.contentView?.layoutSubtreeIfNeeded()
    }

    private func textFields(in window: NSWindow) -> [NSTextField] {
        descendants(in: tryUnwrap(window.contentView)).compactMap { $0 as? NSTextField }
    }

    private func view(identifier: String, in window: NSWindow) -> NSView? {
        descendants(in: tryUnwrap(window.contentView)).first {
            $0.identifier?.rawValue == identifier
        }
    }

    private func assertFits(
        identifier: String,
        in window: NSWindow,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let contentView = tryUnwrap(window.contentView, file: file, line: line)
        let view = tryUnwrap(view(identifier: identifier, in: window), file: file, line: line)
        let frame = view.convert(view.bounds, to: contentView)
        XCTAssertTrue(contentView.bounds.contains(frame), "\(identifier) is clipped", file: file, line: line)
    }

    private func descendants(in view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    private func tryUnwrap<T>(
        _ value: T?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> T {
        guard let value else {
            XCTFail("Expected a value", file: file, line: line)
            fatalError("Expected a value")
        }
        return value
    }
}
