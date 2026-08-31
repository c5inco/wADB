import XCTest
@testable import wADB

final class DiagnosticsExporterTests: XCTestCase {
    func testRedactorRemovesKnownDeviceValuesAndKeepsCorrelation() {
        var redactor = DiagnosticsRedactor(sensitiveValues: [
            "Pixel 10 Pro",
            "adb-ABCD1234",
            "192.168.4.52:34433",
        ])

        let result = redactor.redact("""
        Connecting Pixel 10 Pro at 192.168.4.52:34433 via adb-ABCD1234
        Pixel 10 Pro failed at 192.168.4.52:34433
        """)

        XCTAssertFalse(result.contains("Pixel 10 Pro"))
        XCTAssertFalse(result.contains("192.168.4.52"))
        XCTAssertFalse(result.contains("adb-ABCD1234"))
        let lines = result.components(separatedBy: "\n")
        let firstLineTokens = Set(lines[0].split(separator: " ").filter { $0.hasPrefix("<device-") })
        let secondLineTokens = Set(lines[1].split(separator: " ").filter { $0.hasPrefix("<device-") })
        XCTAssertEqual(firstLineTokens.count, 3)
        XCTAssertEqual(secondLineTokens.count, 2)
        XCTAssertEqual(firstLineTokens.intersection(secondLineTokens).count, 2)
    }

    func testRedactorRemovesCommonPersonalIdentifiers() {
        var redactor = DiagnosticsRedactor(sensitiveValues: [])
        let result = redactor.redact("""
        /Users/alice/Library/Android/sdk
        alice@example.com 12:34:56:78:9A:BC
        203.0.113.7:5037 [fe80::1234%en0]:37123 phone.local.
        550e8400-e29b-41d4-a716-446655440000
        ZX1G22BQQ7 device product:foo
        device 'ZX1G22BQQ7' not found
        wADB[34179:f0d212]
        """)

        for secret in [
            "alice", "example.com", "12:34:56:78:9A:BC", "203.0.113.7",
            "fe80::1234", "phone.local", "550e8400", "ZX1G22BQQ7",
        ] {
            XCTAssertFalse(result.localizedCaseInsensitiveContains(secret), secret)
        }
        XCTAssertTrue(result.contains("<home-1>/Library/Android/sdk"))
        XCTAssertEqual(result.components(separatedBy: "<serial-1>").count - 1, 2)
        XCTAssertTrue(result.contains("wADB[34179:f0d212]"))
    }

    func testReportExplainsCollectionAndDoesNotLeakSensitiveValues() {
        let report = DiagnosticsExporter.buildReport(
            context: DiagnosticsContext(
                appVersion: "1.2",
                appBuild: "34",
                adbVersion: "1.0.41",
                sensitiveValues: ["Secret Phone"]
            ),
            appLogs: "Connected Secret Phone at 192.0.2.10:5037",
            adbLogs: "/Users/alice/.android/adbkey",
            now: Date(timeIntervalSince1970: 0)
        )

        XCTAssertTrue(report.contains("was not uploaded automatically"))
        XCTAssertTrue(report.contains("Review this file before sharing it"))
        XCTAssertTrue(report.contains("wADB unified log (last 24h)"))
        XCTAssertTrue(report.contains("ADB server log (recent tail)"))
        XCTAssertFalse(report.contains("Secret Phone"))
        XCTAssertFalse(report.contains("192.0.2.10"))
        XCTAssertFalse(report.contains("/Users/alice"))
    }
}
