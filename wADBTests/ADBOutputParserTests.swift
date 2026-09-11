import XCTest
@testable import wADB

final class ADBOutputParserTests: XCTestCase {
    func testParsesLongDeviceOutput() throws {
        let output = """
        List of devices attached
        adb-phone-one._adb-tls-connect._tcp device product:example model:Example_Phone device:example transport_id:1
        192.0.2.10:36203 unauthorized product:example model:Example_Phone device:example transport_id:2

        """

        let transports = ADBOutputParser.parseDeviceList(output)

        XCTAssertEqual(transports.count, 2)
        XCTAssertEqual(transports[0].serial, "adb-phone-one._adb-tls-connect._tcp")
        XCTAssertEqual(transports[0].state, .authorized)
        XCTAssertEqual(transports[0].modelDisplayName, "Example Phone")
        XCTAssertEqual(transports[1].state, .unauthorized)
    }

    func testTrackDevicesParserHonorsHexFramesAcrossChunks() throws {
        let first = "serial-one device product:p model:Pixel_10 device:d transport_id:1\n"
        let second = ""
        let bytes = Data(String(format: "%04x", first.utf8.count).utf8)
            + Data(first.utf8)
            + Data(String(format: "%04x", second.utf8.count).utf8)

        var parser = TrackDevicesFrameParser()
        XCTAssertTrue(try parser.append(bytes.prefix(3)).isEmpty)
        let snapshots = try parser.append(bytes.dropFirst(3))

        XCTAssertEqual(snapshots.count, 2)
        XCTAssertEqual(snapshots[0].map(\.serial), ["serial-one"])
        XCTAssertEqual(snapshots[1], [])
    }

    func testDuplicateAuthorizedRowsCollapseIntoOnePhysicalDevice() {
        let rows = [
            ADBTransport(serial: "adb-service._adb-tls-connect._tcp", state: .authorized,
                         attributes: ["product": "example", "model": "Example_Phone", "device": "example"]),
            ADBTransport(serial: "192.0.2.10:36203", state: .authorized,
                         attributes: ["product": "example", "model": "Example_Phone", "device": "example"]),
        ]

        let devices = ADBOutputParser.collapsePhysicalDevices(rows)

        XCTAssertEqual(devices.count, 1)
        XCTAssertEqual(devices[0].transports.count, 2)
        XCTAssertTrue(devices[0].isAuthorized)
    }

    func testConnectSuccessIsJudgedByOutputNotExitStatus() {
        // adb exits 0 for all of these; only the text distinguishes them.
        XCTAssertTrue(ADBOutputParser.connectSucceeded("connected to 192.0.2.10:36747"))
        XCTAssertTrue(ADBOutputParser.connectSucceeded("already connected to 192.0.2.10:36747"))
        XCTAssertFalse(
            ADBOutputParser.connectSucceeded(
                "failed to connect to '192.0.2.10:36747': No route to host"
            )
        )
        XCTAssertFalse(ADBOutputParser.connectSucceeded("cannot connect to daemon"))
        XCTAssertFalse(ADBOutputParser.connectSucceeded(""))
    }

    func testBareConnectFailureIsDistinguishedFromSocketFailures() {
        XCTAssertTrue(ADBOutputParser.connectWasRejectedWithoutReason(
            "failed to connect to 192.0.2.10:36747"
        ))
        XCTAssertTrue(ADBOutputParser.connectWasRejectedWithoutReason(
            "failed to connect to [fe80::10%en0]:36747\n"
        ))
        XCTAssertTrue(ADBOutputParser.connectWasRejectedWithoutReason(
            "failed to connect to '192.0.2.10:36747'"
        ))
        XCTAssertFalse(ADBOutputParser.connectWasRejectedWithoutReason(
            "failed to connect to '192.0.2.10:36747': Connection refused"
        ))
        XCTAssertFalse(ADBOutputParser.connectWasRejectedWithoutReason(
            "failed to connect to 192.0.2.10:36747: No route to host"
        ))
        XCTAssertFalse(ADBOutputParser.connectWasRejectedWithoutReason(
            "failed to authenticate to 192.0.2.10:36747"
        ))
        XCTAssertFalse(ADBOutputParser.connectWasRejectedWithoutReason(
            "* daemon not running; starting now\nfailed to connect to 192.0.2.10:36747"
        ))
        XCTAssertFalse(ADBOutputParser.connectWasRejectedWithoutReason("connected to 192.0.2.10:36747"))
        XCTAssertFalse(ADBOutputParser.connectWasRejectedWithoutReason(""))
    }
}
