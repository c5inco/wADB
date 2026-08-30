import XCTest
@testable import wADB

final class QRPayloadTests: XCTestCase {
    func testPayloadUsesExactAOSPFormatAndQRSafeCredentials() throws {
        let payload = try ADBQRPayload(
            instanceName: Data("studio-Abc_123-xyz".utf8),
            password: Data("Password_123-xyz".utf8)
        )
        var encoded = payload.encoded()
        defer { encoded.resetBytes(in: 0..<encoded.count) }

        XCTAssertEqual(
            String(decoding: encoded, as: UTF8.self),
            "WIFI:T:ADB;S:studio-Abc_123-xyz;P:Password_123-xyz;;"
        )
        XCTAssertTrue(ADBQRPayload.isValid(encoded))
    }

    func testValidationRejectsUnsafeOrMalformedPayloads() {
        XCTAssertFalse(ADBQRPayload.isValid(Data("WIFI:T:ADB;S:studio-name;P:bad:semicolon;;".utf8)))
        XCTAssertFalse(ADBQRPayload.isValid(Data("WIFI:T:WPA;S:studio-name;P:password;;".utf8)))
        XCTAssertFalse(ADBQRPayload.isValid(Data("WIFI:T:ADB;S:not-studio;P:password;;".utf8)))
    }

    func testRandomPayloadsAreValidAndDistinct() throws {
        let first = try ADBQRPayload.random()
        let second = try ADBQRPayload.random()
        var firstData = first.encoded()
        var secondData = second.encoded()
        defer {
            firstData.resetBytes(in: 0..<firstData.count)
            secondData.resetBytes(in: 0..<secondData.count)
        }

        XCTAssertTrue(ADBQRPayload.isValid(firstData))
        XCTAssertTrue(ADBQRPayload.isValid(secondData))
        XCTAssertNotEqual(firstData, secondData)

        let text = String(decoding: firstData, as: UTF8.self)
        let content = text.dropFirst("WIFI:T:ADB;S:studio-".count).dropLast(2)
        let fields = content.components(separatedBy: ";P:")
        XCTAssertEqual(fields.count, 2)
        XCTAssertEqual(fields[0].count, 10)
        XCTAssertEqual(fields[1].count, 10)
        XCTAssertTrue(first.matches(serviceName: "studio-\(fields[0])"))
        XCTAssertFalse(first.matches(serviceName: "studio-unrelated"))
    }
}
