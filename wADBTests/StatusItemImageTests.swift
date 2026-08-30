import AppKit
import XCTest
@testable import wADB

final class StatusItemImageTests: XCTestCase {
    func testMenuBarStatusSymbolsExist() {
        for name in StatusItemSymbol.all {
            XCTAssertNotNil(
                NSImage(systemSymbolName: name, accessibilityDescription: nil),
                "Menu bar status symbol \(name) must exist on the deployment target"
            )
        }
    }

    func testWirelessDebuggingStatusImageExists() {
        XCTAssertNotNil(NSImage(named: "StatusWirelessDebugging"))
    }
}
