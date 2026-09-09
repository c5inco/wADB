import Darwin
import XCTest
@testable import wADB

final class SupervisorModelTests: XCTestCase {
    private let remembered = LastVerifiedDevice(
        endpoint: "192.0.2.10:36203",
        host: "192.0.2.10",
        serviceName: "adb-phone",
        displayName: "Example Phone",
        fingerprint: "example|Example_Phone|example"
    )

    func testWatchdogProbesOnlyAfterRepeatedSnapshotFailures() {
        XCTAssertFalse(ADBWatchdogPolicy.shouldProbeServer(snapshotFailures: 0))
        XCTAssertFalse(ADBWatchdogPolicy.shouldProbeServer(
            snapshotFailures: ADBWatchdogPolicy.snapshotFailuresBeforeProbe - 1
        ))
        XCTAssertTrue(ADBWatchdogPolicy.shouldProbeServer(
            snapshotFailures: ADBWatchdogPolicy.snapshotFailuresBeforeProbe
        ))
    }

    func testResponsiveServerOnlyRestartsObserver() {
        XCTAssertEqual(
            ADBWatchdogPolicy.recoveryAction(serverResponsive: true),
            .restartObserver
        )
    }

    func testOnlyFailedServerProbeRequestsStart() {
        XCTAssertEqual(
            ADBWatchdogPolicy.recoveryAction(serverResponsive: false),
            .startServer
        )
    }

    func testConnectionFailuresBackOffToFiveMinutes() {
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        var retry = ADBConnectionRetryState()
        let targetIdentity = "adb-phone|36203"

        XCTAssertTrue(retry.shouldAttempt(targetIdentity: targetIdentity, now: start))
        XCTAssertEqual(retry.recordFailure(targetIdentity: targetIdentity, now: start), 15)
        XCTAssertFalse(retry.shouldAttempt(
            targetIdentity: targetIdentity,
            now: start.addingTimeInterval(14)
        ))
        XCTAssertTrue(retry.shouldAttempt(
            targetIdentity: targetIdentity,
            now: start.addingTimeInterval(15)
        ))

        XCTAssertEqual(retry.recordFailure(targetIdentity: targetIdentity, now: start), 30)
        XCTAssertEqual(retry.recordFailure(targetIdentity: targetIdentity, now: start), 60)
        XCTAssertEqual(retry.recordFailure(targetIdentity: targetIdentity, now: start), 120)
        XCTAssertEqual(retry.recordFailure(targetIdentity: targetIdentity, now: start), 300)
        XCTAssertEqual(retry.recordFailure(targetIdentity: targetIdentity, now: start), 300)
    }

    func testConnectionPortChangeResetsBackoff() {
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        var retry = ADBConnectionRetryState()
        _ = retry.recordFailure(targetIdentity: "adb-phone|36203", now: start)

        XCTAssertTrue(retry.shouldAttempt(
            targetIdentity: "adb-phone|40002",
            now: start.addingTimeInterval(1)
        ))
        XCTAssertEqual(retry.consecutiveFailures, 0)
    }

    func testAddressFamilyChangePreservesBackoffForSamePort() {
        let ipv6 = BonjourService(
            name: remembered.serviceName,
            type: BonjourService.connectType,
            domain: "local.",
            host: "fe80::1234%en0",
            port: 43545,
            interfaceIndex: 4
        )
        let ipv4 = BonjourService(
            name: remembered.serviceName,
            type: BonjourService.connectType,
            domain: "local.",
            host: remembered.host,
            port: 43545,
            interfaceIndex: 4
        )
        let ipv6Target = ADBConnectionTarget(device: remembered, service: ipv6)
        let ipv4Target = ADBConnectionTarget(device: remembered, service: ipv4)
        var retry = ADBConnectionRetryState()
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        _ = retry.recordFailure(targetIdentity: ipv6Target.retryIdentity, now: start)

        XCTAssertNotEqual(ipv6Target.endpoint, ipv4Target.endpoint)
        XCTAssertEqual(ipv6Target.retryIdentity, ipv4Target.retryIdentity)
        XCTAssertFalse(retry.shouldAttempt(
            targetIdentity: ipv4Target.retryIdentity,
            now: start.addingTimeInterval(1)
        ))
        XCTAssertEqual(retry.consecutiveFailures, 1)
    }

    func testConnectionTargetRetainsEveryBonjourAddressInOrder() {
        let service = BonjourService(
            name: remembered.serviceName,
            type: BonjourService.connectType,
            domain: "local.",
            hosts: ["fe80::10%en0", "fd00::10", "192.0.2.10"],
            port: 43545,
            interfaceIndex: 4
        )

        XCTAssertEqual(
            ADBConnectionTarget(device: remembered, service: service).endpoints,
            ["192.0.2.10:43545", "[fd00::10]:43545", "[fe80::10%en0]:43545"]
        )
    }

    func testAuthorizedAndUnauthorizedTransportsDoNotReconnectButOfflineDoes() {
        let service = BonjourService(
            name: remembered.serviceName,
            type: BonjourService.connectType,
            domain: "local.",
            host: remembered.host,
            port: 43545,
            interfaceIndex: 4
        )

        for state in [ADBTransportState.authorized, .unauthorized] {
            XCTAssertFalse(ADBAutomaticReconnectPolicy.shouldReconnect(
                remembered,
                transports: [ADBTransport(
                    serial: service.endpoint,
                    state: state,
                    attributes: [:]
                )],
                services: [service]
            ))
        }
        XCTAssertTrue(ADBAutomaticReconnectPolicy.shouldReconnect(
            remembered,
            transports: [ADBTransport(
                serial: service.endpoint,
                state: .offline,
                attributes: [:]
            )],
            services: [service]
        ))
    }

    func testSecondaryBonjourEndpointSatisfiesAutomaticReconnect() {
        let service = BonjourService(
            name: remembered.serviceName,
            type: BonjourService.connectType,
            domain: "local.",
            hosts: ["192.0.2.10", "fd00::10"],
            port: 43545,
            interfaceIndex: 4
        )
        let secondaryTransport = ADBTransport(
            serial: "[fd00::10]:43545",
            state: .authorized,
            attributes: [:]
        )

        XCTAssertFalse(ADBAutomaticReconnectPolicy.shouldReconnect(
            remembered,
            transports: [secondaryTransport],
            services: [service]
        ))
        XCTAssertTrue(WirelessDeviceResolver.matches(
            secondaryTransport,
            rememberedDevice: remembered,
            services: [service]
        ))
    }

    func testTemporaryBonjourDisappearanceKeepsLastLiveTarget() {
        let service = BonjourService(
            name: remembered.serviceName,
            type: BonjourService.connectType,
            domain: "local.",
            host: remembered.host,
            port: 43545,
            interfaceIndex: 4
        )
        let live = ADBConnectionTargetResolver.resolve(
            device: remembered,
            services: [service],
            previous: nil
        )

        XCTAssertEqual(
            ADBConnectionTargetResolver.resolve(
                device: remembered,
                services: [],
                previous: live
            ),
            live
        )
        XCTAssertNotEqual(live.endpoint, remembered.endpoint)
    }

    func testNewBonjourPortReplacesCachedTargetImmediately() {
        let old = ADBConnectionTarget(
            device: remembered,
            service: BonjourService(
                name: remembered.serviceName,
                type: BonjourService.connectType,
                domain: "local.",
                host: remembered.host,
                port: 43545,
                interfaceIndex: 4
            )
        )
        let newService = BonjourService(
            name: remembered.serviceName,
            type: BonjourService.connectType,
            domain: "local.",
            host: remembered.host,
            port: 45001,
            interfaceIndex: 4
        )
        let resolved = ADBConnectionTargetResolver.resolve(
            device: remembered,
            services: [newService],
            previous: old
        )

        XCTAssertEqual(resolved.endpoint, "192.0.2.10:45001")
        XCTAssertNotEqual(resolved.retryIdentity, old.retryIdentity)
    }

    func testNetworkEndpointParsesIPv4AndScopedIPv6() {
        XCTAssertEqual(
            ADBNetworkEndpoint.parse("192.0.2.10:43545"),
            ADBNetworkEndpoint(host: "192.0.2.10", port: 43545)
        )
        XCTAssertEqual(
            ADBNetworkEndpoint.parse("[fe80::1234%en0]:43545"),
            ADBNetworkEndpoint(host: "fe80::1234%en0", port: 43545)
        )
        XCTAssertNil(ADBNetworkEndpoint.parse("fe80::1234:43545"))
        XCTAssertNil(ADBNetworkEndpoint.parse("192.0.2.10:not-a-port"))
    }

    func testRestartRecommendationRequiresRepeatedRouteFailuresAndBonjour() {
        XCTAssertFalse(ADBDeviceRecoveryPolicy.shouldCheckEndpoint(
            consecutiveFailures: 1,
            failureDetail: "No route to host",
            hasAdvertisedService: true
        ))
        XCTAssertFalse(ADBDeviceRecoveryPolicy.shouldCheckEndpoint(
            consecutiveFailures: 2,
            failureDetail: "No route to host",
            hasAdvertisedService: false
        ))
        XCTAssertFalse(ADBDeviceRecoveryPolicy.shouldCheckEndpoint(
            consecutiveFailures: 2,
            failureDetail: "failed to authenticate",
            hasAdvertisedService: true
        ))
        XCTAssertTrue(ADBDeviceRecoveryPolicy.shouldCheckEndpoint(
            consecutiveFailures: 2,
            failureDetail: "failed to connect: No route to host",
            hasAdvertisedService: true
        ))
    }

    func testRestartRecommendationHasExplicitRowTitle() {
        XCTAssertEqual(WirelessDeviceState.restartRecommended.title, "Restart ADB")
    }

    func testWatchdogOnlyRetriesAnUnavailableServer() {
        XCTAssertTrue(
            AppDelegate.ADBServerState.unavailable("start failed")
                .shouldAttemptStartOnWatchdogTick
        )
        XCTAssertFalse(AppDelegate.ADBServerState.stopped.shouldAttemptStartOnWatchdogTick)
        XCTAssertFalse(AppDelegate.ADBServerState.starting.shouldAttemptStartOnWatchdogTick)
        XCTAssertFalse(AppDelegate.ADBServerState.running.shouldAttemptStartOnWatchdogTick)
    }

    func testADBCommandsRemoveInheritedRemoteServerOverrides() {
        let environment = ADBManager.standardServerEnvironment(from: [
            "PATH": "/usr/bin",
            "ADB_SERVER_SOCKET": "tcp:127.0.0.1:5037",
            "ANDROID_ADB_SERVER_PORT": "5038",
            "ANDROID_ADB_SERVER_ADDRESS": "192.0.2.100",
            "ADB_VENDOR_KEYS": "/tmp/keys",
        ])

        XCTAssertEqual(environment["PATH"], "/usr/bin")
        XCTAssertNil(environment["ADB_SERVER_SOCKET"])
        XCTAssertNil(environment["ANDROID_ADB_SERVER_PORT"])
        XCTAssertNil(environment["ANDROID_ADB_SERVER_ADDRESS"])
        XCTAssertNil(environment["ADB_VENDOR_KEYS"])
    }

    func testServerHealthProbeDoesNotRunAnADBCommand() throws {
        let fixture = try makeADBFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let manager = ADBManager(
            executableURL: fixture.executable,
            serverProbe: { true },
            postStartProbeDelay: 0
        )
        let probed = expectation(description: "ADB server probed")

        manager.checkServerResponsive { responsive in
            XCTAssertTrue(responsive)
            probed.fulfill()
        }

        wait(for: [probed], timeout: 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.commandLog.path))
    }

    func testResponsiveServerSkipsStartCommand() throws {
        let fixture = try makeADBFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let manager = ADBManager(
            executableURL: fixture.executable,
            serverProbe: { true },
            postStartProbeDelay: 0
        )
        let prepared = expectation(description: "ADB prepared")

        manager.prepare { result in
            switch result {
            case let .success(preparation):
                XCTAssertEqual(preparation.serverStartOutcome, .alreadyResponsive)
            case let .failure(error):
                XCTFail("Expected preparation to succeed: \(error)")
            }
            prepared.fulfill()
        }

        wait(for: [prepared], timeout: 2)
        XCTAssertEqual(try fixture.commands(), ["version"])
    }

    func testSuccessfulStarterReportsDirectStartOutcome() throws {
        let fixture = try makeADBFixture(startServerExitStatus: 0)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let manager = ADBManager(
            executableURL: fixture.executable,
            serverProbe: { false },
            postStartProbeDelay: 0
        )
        let prepared = expectation(description: "ADB prepared")

        manager.prepare { result in
            switch result {
            case let .success(preparation):
                XCTAssertEqual(preparation.serverStartOutcome, .started(exitStatus: 0))
            case let .failure(error):
                XCTFail("Expected direct start to succeed: \(error)")
            }
            prepared.fulfill()
        }

        wait(for: [prepared], timeout: 2)
        XCTAssertEqual(try fixture.commands(), ["version", "start-server"])
    }

    func testFailedStarterAcceptsServerThatWonRace() throws {
        let fixture = try makeADBFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        var probes = [false, true]
        let manager = ADBManager(
            executableURL: fixture.executable,
            serverProbe: { probes.removeFirst() },
            postStartProbeDelay: 0
        )
        let prepared = expectation(description: "ADB prepared")

        manager.prepare { result in
            switch result {
            case let .success(preparation):
                XCTAssertEqual(
                    preparation.serverStartOutcome,
                    .competingStarterWon(exitStatus: 1)
                )
            case let .failure(error):
                XCTFail("Expected lost-race recovery to succeed: \(error)")
            }
            prepared.fulfill()
        }

        wait(for: [prepared], timeout: 2)
        XCTAssertEqual(try fixture.commands(), ["version", "start-server"])
    }

    func testFailedStarterReportsFailureWhenServerRemainsUnavailable() throws {
        let fixture = try makeADBFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let manager = ADBManager(
            executableURL: fixture.executable,
            serverProbe: { false },
            postStartProbeDelay: 0
        )
        let prepared = expectation(description: "ADB preparation failed")

        manager.prepare { result in
            if case .success = result {
                XCTFail("Expected preparation to fail while the server remained unavailable")
            }
            prepared.fulfill()
        }

        wait(for: [prepared], timeout: 2)
        XCTAssertEqual(try fixture.commands(), ["version", "start-server"])
    }

    func testAuthorizedMDNSTransportIsConnectedWirelessDevice() {
        let transport = ADBTransport(
            serial: "adb-phone._adb-tls-connect._tcp",
            state: .authorized,
            attributes: examplePhoneAttributes
        )

        XCTAssertEqual(
            WirelessDeviceResolver.resolve(
                transports: [transport],
                services: [],
                rememberedDevices: []
            ),
            [
                WirelessDevice(
                    id: "adb-phone",
                    displayName: "Example Phone",
                    endpoint: nil,
                    state: .connected
                ),
            ]
        )
    }

    func testUSBAndEmulatorTransportsAreExcluded() {
        let transports = [
            ADBTransport(serial: "EXAMPLE-USB-SERIAL", state: .authorized, attributes: examplePhoneAttributes),
            ADBTransport(serial: "emulator-5554", state: .authorized, attributes: [
                "model": "sdk_gphone64_arm64",
            ]),
        ]

        XCTAssertTrue(
            WirelessDeviceResolver.resolve(
                transports: transports,
                services: [],
                rememberedDevices: []
            ).isEmpty
        )
    }

    func testExplicitEndpointIsWirelessWhenItMatchesBonjour() {
        let service = connectService()
        let transport = ADBTransport(
            serial: service.endpoint,
            state: .authorized,
            attributes: examplePhoneAttributes
        )

        XCTAssertEqual(
            WirelessDeviceResolver.resolve(
                transports: [transport],
                services: [service],
                rememberedDevices: []
            ).first,
            WirelessDevice(
                id: service.name,
                displayName: "Example Phone",
                endpoint: service.endpoint,
                state: .connected
            )
        )
    }

    func testUSBTransportCannotSatisfyRememberedWirelessDevice() {
        let usb = ADBTransport(
            serial: "EXAMPLE-USB-SERIAL",
            state: .authorized,
            attributes: examplePhoneAttributes
        )

        XCTAssertTrue(
            WirelessDeviceResolver.resolve(
                transports: [usb],
                services: [],
                rememberedDevices: [remembered]
            ).isEmpty
        )
    }

    func testRememberedDeviceOnlyAppearsWhileCurrentlyAdvertised() {
        XCTAssertTrue(
            WirelessDeviceResolver.resolve(
                transports: [],
                services: [],
                rememberedDevices: [remembered]
            ).isEmpty
        )

        let service = connectService()
        XCTAssertEqual(
            WirelessDeviceResolver.resolve(
                transports: [],
                services: [service],
                rememberedDevices: [remembered]
            ),
            [
                WirelessDevice(
                    id: service.name,
                    displayName: remembered.displayName,
                    endpoint: service.endpoint,
                    state: .connecting
                ),
            ]
        )
    }

    func testUnknownBonjourDeviceIsNotPresentedWithoutATransport() {
        XCTAssertTrue(
            WirelessDeviceResolver.resolve(
                transports: [],
                services: [connectService()],
                rememberedDevices: []
            ).isEmpty
        )
    }

    func testUnauthorizedWirelessTransportNeedsPairing() {
        let transport = ADBTransport(
            serial: "adb-phone._adb-tls-connect._tcp",
            state: .unauthorized,
            attributes: examplePhoneAttributes
        )

        XCTAssertEqual(
            WirelessDeviceResolver.resolve(
                transports: [transport],
                services: [],
                rememberedDevices: []
            ).first?.state,
            .needsPairing
        )
    }

    func testDuplicateEndpointAndMDNSTransportsCollapseToOneDevice() {
        let service = connectService()
        let transports = [
            ADBTransport(
                serial: "adb-phone._adb-tls-connect._tcp",
                state: .authorized,
                attributes: examplePhoneAttributes
            ),
            ADBTransport(
                serial: service.endpoint,
                state: .authorized,
                attributes: examplePhoneAttributes
            ),
        ]

        XCTAssertEqual(
            WirelessDeviceResolver.resolve(
                transports: transports,
                services: [service],
                rememberedDevices: [remembered]
            ).count,
            1
        )
    }

    func testSameModelPhonesWithDistinctServicesRemainSeparateDevices() {
        let services = [
            BonjourService(
                name: "adb-phone-one", type: BonjourService.connectType, domain: "local.",
                host: "192.0.2.10", port: 40001, interfaceIndex: 4
            ),
            BonjourService(
                name: "adb-phone-two", type: BonjourService.connectType, domain: "local.",
                host: "192.0.2.11", port: 40002, interfaceIndex: 4
            ),
        ]
        let transports = [
            ADBTransport(
                serial: "adb-phone-one._adb-tls-connect._tcp",
                state: .authorized,
                attributes: examplePhoneAttributes
            ),
            ADBTransport(
                serial: "adb-phone-two._adb-tls-connect._tcp",
                state: .authorized,
                attributes: examplePhoneAttributes
            ),
        ]

        XCTAssertEqual(
            Set(WirelessDeviceResolver.resolve(
                transports: transports,
                services: services,
                rememberedDevices: []
            ).map(\.id)),
            ["adb-phone-one", "adb-phone-two"]
        )
    }

    private var examplePhoneAttributes: [String: String] {
        ["product": "example", "model": "Example_Phone", "device": "example"]
    }

    private func connectService() -> BonjourService {
        BonjourService(
            name: "adb-phone",
            type: BonjourService.connectType,
            domain: "local.",
            host: "192.0.2.10",
            port: 40001,
            interfaceIndex: 4
        )
    }

    private func makeADBFixture(startServerExitStatus: Int32 = 1) throws -> ADBFixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wADB-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let executable = directory.appendingPathComponent("adb")
        let commandLog = directory.appendingPathComponent("commands.txt")
        let script = """
        #!/bin/sh
        printf '%s\\n' "$1" >> '\(commandLog.path)'
        if [ "$1" = version ]; then
          printf '%s\\n' 'Android Debug Bridge version 1.0.41' 'Version 37.0.1-15733141'
          exit 0
        fi
        if [ \(startServerExitStatus) -eq 0 ]; then
          exit 0
        fi
        printf '%s\\n' 'ADB server did not ACK' >&2
        exit \(startServerExitStatus)
        """
        try Data(script.utf8).write(to: executable)
        XCTAssertEqual(chmod(executable.path, 0o700), 0)
        return ADBFixture(
            directory: directory,
            executable: executable,
            commandLog: commandLog
        )
    }
}

private struct ADBFixture {
    let directory: URL
    let executable: URL
    let commandLog: URL

    func commands() throws -> [String] {
        let text = try String(contentsOf: commandLog, encoding: .utf8)
        return text.split(whereSeparator: \.isNewline).map(String.init)
    }
}
