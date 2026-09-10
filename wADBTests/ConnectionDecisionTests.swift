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

    func testFailoverStopsWhenAttemptedEndpointBecomesUnauthorized() {
        let transport = ADBTransport(
            serial: "[fd00::10]:43545",
            state: .unauthorized,
            attributes: [:]
        )

        XCTAssertFalse(ADBAutomaticReconnectPolicy.shouldContinueFailover(
            remembered,
            attemptedEndpoint: transport.serial,
            failureDetail: "failed to connect to [fd00::10]:43545",
            transports: [transport],
            services: []
        ))
    }

    func testFailoverStopsWhenConnectReportsAuthenticationFailure() {
        // adb reports the authentication failure before the tracker publishes
        // the unauthorized transport, so the snapshot is still empty here.
        XCTAssertFalse(ADBAutomaticReconnectPolicy.shouldContinueFailover(
            remembered,
            attemptedEndpoint: "192.0.2.10:36203",
            failureDetail: "failed to authenticate to 192.0.2.10:36203",
            transports: [],
            services: []
        ))
        XCTAssertTrue(ADBAutomaticReconnectPolicy.shouldContinueFailover(
            remembered,
            attemptedEndpoint: "192.0.2.10:36203",
            failureDetail: "failed to connect to 192.0.2.10:36203",
            transports: [],
            services: []
        ))
    }

    func testReconcileIgnoresAnotherPhoneThatInheritedTheRememberedAddress() {
        // DHCP handed the offline phone's old address to a different paired
        // phone. Its service advertises the remembered host, and its transport
        // could even share a fingerprint, but neither is this device.
        let otherPhone = LastVerifiedDevice(
            endpoint: "192.0.2.10:41000",
            host: "192.0.2.10",
            serviceName: "adb-other",
            displayName: "Other Phone",
            fingerprint: remembered.fingerprint
        )
        let otherService = BonjourService(
            name: otherPhone.serviceName,
            type: BonjourService.connectType,
            domain: "local.",
            hosts: ["192.0.2.10", "fd00::20"],
            port: 41000,
            interfaceIndex: 4
        )
        let transport = ADBTransport(
            serial: "[fd00::20]:41000",
            state: .authorized,
            attributes: ["product": "example", "model": "Example_Phone", "device": "example"]
        )

        XCTAssertEqual(
            ADBRememberedEndpointResolver.reconcile(
                [remembered, otherPhone],
                transports: [transport],
                services: [otherService]
            ),
            [
                remembered,
                LastVerifiedDevice(
                    endpoint: "[fd00::20]:41000",
                    host: "fd00::20",
                    serviceName: otherPhone.serviceName,
                    displayName: otherPhone.displayName,
                    fingerprint: otherPhone.fingerprint
                ),
            ]
        )
    }

    func testSuccessfulSecondaryConnectionUpdatesRememberedEndpoint() {
        let service = BonjourService(
            name: remembered.serviceName,
            type: BonjourService.connectType,
            domain: "local.",
            hosts: ["192.0.2.10", "fd00::10"],
            port: 43545,
            interfaceIndex: 4
        )

        XCTAssertEqual(
            ADBRememberedEndpointResolver.resolve(
                device: remembered,
                connectedEndpoint: "[fd00::10]:43545",
                services: [service]
            ),
            LastVerifiedDevice(
                endpoint: "[fd00::10]:43545",
                host: "fd00::10",
                serviceName: remembered.serviceName,
                displayName: remembered.displayName,
                fingerprint: remembered.fingerprint
            )
        )
    }

    func testSuccessfulHostCorrelatedConnectionDoesNotRewriteRememberedEndpoint() {
        // The reconnect target was correlated by host only: another paired
        // phone now advertises this device's old address under its own name.
        let otherService = BonjourService(
            name: "adb-other",
            type: BonjourService.connectType,
            domain: "local.",
            hosts: ["192.0.2.10", "fd00::20"],
            port: 41000,
            interfaceIndex: 4
        )

        XCTAssertEqual(
            ADBRememberedEndpointResolver.resolve(
                device: remembered,
                connectedEndpoint: "[fd00::20]:41000",
                services: [otherService]
            ),
            remembered
        )
    }

    func testAuthorizedSecondaryTransportUpdatesRememberedEndpoint() {
        let service = BonjourService(
            name: remembered.serviceName,
            type: BonjourService.connectType,
            domain: "local.",
            hosts: ["192.0.2.10", "fd00::10"],
            port: 36203,
            interfaceIndex: 4
        )
        let transport = ADBTransport(serial: "[fd00::10]:36203", state: .authorized, attributes: [:])

        XCTAssertEqual(
            ADBRememberedEndpointResolver.reconcile(
                [remembered],
                transports: [transport],
                services: [service]
            ),
            [LastVerifiedDevice(
                endpoint: "[fd00::10]:36203",
                host: "fd00::10",
                serviceName: remembered.serviceName,
                displayName: remembered.displayName,
                fingerprint: remembered.fingerprint
            )]
        )
    }

    func testRememberedEndpointKeepsStoredAddressWhenItIsStillAuthorized() {
        let service = BonjourService(
            name: remembered.serviceName,
            type: BonjourService.connectType,
            domain: "local.",
            hosts: ["192.0.2.10", "fd00::10"],
            port: 36203,
            interfaceIndex: 4
        )
        let transports = [
            ADBTransport(serial: "[fd00::10]:36203", state: .authorized, attributes: [:]),
            ADBTransport(serial: "192.0.2.10:36203", state: .authorized, attributes: [:]),
        ]

        XCTAssertEqual(
            ADBRememberedEndpointResolver.reconcile(
                [remembered],
                transports: transports,
                services: [service]
            ),
            [remembered]
        )
    }

    func testNativeAndUnauthorizedTransportsDoNotRewriteRememberedEndpoint() {
        let transports = [
            ADBTransport(
                serial: "\(remembered.serviceName).\(BonjourService.connectType)",
                state: .authorized,
                attributes: [:]
            ),
            ADBTransport(serial: "[fd00::10]:36203", state: .unauthorized, attributes: [:]),
        ]

        XCTAssertEqual(
            ADBRememberedEndpointResolver.reconcile(
                [remembered],
                transports: transports,
                services: []
            ),
            [remembered]
        )
    }

    func testFailoverStopsWhenBonjourRepublishesTheTargetMidSequence() {
        func service(port: UInt16, hosts: [String]) -> BonjourService {
            BonjourService(
                name: remembered.serviceName,
                type: BonjourService.connectType,
                domain: "local.",
                hosts: hosts,
                port: port,
                interfaceIndex: 4
            )
        }
        let original = service(port: 36203, hosts: ["192.0.2.10", "fd00::10"])
        let target = ADBConnectionTarget(device: remembered, service: original)

        XCTAssertTrue(ADBAutomaticReconnectPolicy.targetIsCurrent(
            target, device: remembered, services: [original]
        ))
        // A transient empty publish keeps the sequence alive.
        XCTAssertTrue(ADBAutomaticReconnectPolicy.targetIsCurrent(
            target, device: remembered, services: []
        ))
        XCTAssertFalse(ADBAutomaticReconnectPolicy.targetIsCurrent(
            target,
            device: remembered,
            services: [service(port: 40001, hosts: ["192.0.2.10", "fd00::10"])]
        ))
        XCTAssertFalse(ADBAutomaticReconnectPolicy.targetIsCurrent(
            target,
            device: remembered,
            services: [service(port: 36203, hosts: ["192.0.2.10"])]
        ))
    }

    func testRememberedServiceNameBeatsAnotherDeviceOnTheRememberedHost() {
        // "adb-aaa" sorts before the remembered service and now advertises the
        // remembered host after DHCP reassignment. Identity must still win.
        let impostor = BonjourService(
            name: "adb-aaa",
            type: BonjourService.connectType,
            domain: "local.",
            hosts: ["192.0.2.10"],
            port: 41000,
            interfaceIndex: 4
        )
        let exact = BonjourService(
            name: remembered.serviceName,
            type: BonjourService.connectType,
            domain: "local.",
            hosts: ["192.0.2.77", "fd00::10"],
            port: 36203,
            interfaceIndex: 4
        )

        XCTAssertEqual(
            BonjourCorrelator.connectService(for: remembered, among: [impostor, exact]),
            exact
        )
        XCTAssertEqual(
            ADBConnectionTargetResolver.resolve(
                device: remembered,
                services: [impostor, exact],
                previous: nil
            ).endpoints,
            ["192.0.2.77:36203", "[fd00::10]:36203"]
        )
        // Host fallback still applies when no service carries the name.
        XCTAssertEqual(
            BonjourCorrelator.connectService(for: remembered, among: [impostor]),
            impostor
        )
    }

    func testPairSucceededRequiresZeroStatusAndSuccessLine() {
        XCTAssertTrue(ADBOutputParser.pairSucceeded(ADBProcessResult(
            status: 0,
            standardOutput: "Successfully paired to 192.0.2.10:37001 [guid=adb-phone]",
            standardError: ""
        )))
        XCTAssertFalse(ADBOutputParser.pairSucceeded(ADBProcessResult(
            status: 0,
            standardOutput: "",
            standardError: "Failed: Unable to start pairing client."
        )))
        XCTAssertFalse(ADBOutputParser.pairSucceeded(ADBProcessResult(
            status: 1,
            standardOutput: "Successfully paired to 192.0.2.10:37001",
            standardError: ""
        )))
    }

    func testRecoveryUsesOnlyTheFailureFromTheEndpointItProbes() {
        let failures = [
            ADBConnectionFailure(endpoint: "192.0.2.10:43545", detail: "connection refused"),
            ADBConnectionFailure(endpoint: "[fd00::10]:43545", detail: "No route to host"),
        ]

        XCTAssertEqual(
            ADBConnectionFailurePolicy.recoveryDetail(
                for: "192.0.2.10:43545",
                failures: failures
            ),
            "connection refused"
        )
        XCTAssertEqual(
            ADBConnectionFailurePolicy.combinedDetail(failures),
            "192.0.2.10:43545: connection refused; [fd00::10]:43545: No route to host"
        )
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
        let routeFailure = [ADBConnectionFailure(
            endpoint: "192.0.2.10:43545",
            detail: "failed to connect to '192.0.2.10:43545': No route to host"
        )]

        XCTAssertEqual(ADBDeviceRecoveryPolicy.recoveryToConfirm(
            consecutiveFailures: 1,
            failures: routeFailure,
            probedEndpoint: "192.0.2.10:43545",
            hasAdvertisedService: true
        ), .none)
        XCTAssertEqual(ADBDeviceRecoveryPolicy.recoveryToConfirm(
            consecutiveFailures: 2,
            failures: routeFailure,
            probedEndpoint: "192.0.2.10:43545",
            hasAdvertisedService: false
        ), .none)
        XCTAssertEqual(ADBDeviceRecoveryPolicy.recoveryToConfirm(
            consecutiveFailures: 2,
            failures: [ADBConnectionFailure(
                endpoint: "192.0.2.10:43545",
                detail: "failed to authenticate to 192.0.2.10:43545"
            )],
            probedEndpoint: "192.0.2.10:43545",
            hasAdvertisedService: true
        ), .none)
        XCTAssertEqual(ADBDeviceRecoveryPolicy.recoveryToConfirm(
            consecutiveFailures: 2,
            failures: routeFailure,
            probedEndpoint: "192.0.2.10:43545",
            hasAdvertisedService: true
        ), .restartServer)
    }

    // Pixel 10 Pro, Android 17: after the phone forgot this host, every
    // advertised address accepted TCP, and adb reported a bare
    // "failed to connect" for each one because the TLS handshake was
    // rejected with SSLV3_ALERT_CERTIFICATE_UNKNOWN.
    private let revokedFailures = [
        ADBConnectionFailure(endpoint: "192.0.2.10:43545", detail: "failed to connect to 192.0.2.10:43545"),
        ADBConnectionFailure(endpoint: "[fd00::10]:43545", detail: "failed to connect to [fd00::10]:43545\n"),
        ADBConnectionFailure(endpoint: "[fd00::11]:43545", detail: "failed to connect to [fd00::11]:43545"),
        ADBConnectionFailure(endpoint: "[fe80::10%en0]:43545", detail: "failed to connect to [fe80::10%en0]:43545"),
    ]

    func testRevokedPairingIsRecognizedOnlyAfterThreeFullyRejectedRounds() {
        for failures in 1..<ADBDeviceRecoveryPolicy.failuresBeforePairingRecommendation {
            XCTAssertEqual(ADBDeviceRecoveryPolicy.recoveryToConfirm(
                consecutiveFailures: failures,
                failures: revokedFailures,
                probedEndpoint: "192.0.2.10:43545",
                hasAdvertisedService: true
            ), .none, "round \(failures)")
        }
        XCTAssertEqual(ADBDeviceRecoveryPolicy.recoveryToConfirm(
            consecutiveFailures: 3,
            failures: revokedFailures,
            probedEndpoint: "192.0.2.10:43545",
            hasAdvertisedService: true
        ), .needsPairing)
        XCTAssertEqual(ADBDeviceRecoveryPolicy.recoveryToConfirm(
            consecutiveFailures: 7,
            failures: revokedFailures,
            probedEndpoint: "192.0.2.10:43545",
            hasAdvertisedService: true
        ), .needsPairing)
        XCTAssertEqual(ADBDeviceRecoveryPolicy.recoveryToConfirm(
            consecutiveFailures: 3,
            failures: revokedFailures,
            probedEndpoint: "192.0.2.10:43545",
            hasAdvertisedService: false
        ), .none)
    }

    func testMixedAddressFailuresNeverSuggestPairing() {
        // One address failed at the socket level; the phone did not reject
        // every handshake, so keep retrying.
        let mixed = Array(revokedFailures.dropLast()) + [ADBConnectionFailure(
            endpoint: "[fe80::10%en0]:43545",
            detail: "failed to connect to '[fe80::10%en0]:43545': Connection refused"
        )]
        XCTAssertEqual(ADBDeviceRecoveryPolicy.recoveryToConfirm(
            consecutiveFailures: 5,
            failures: mixed,
            probedEndpoint: "192.0.2.10:43545",
            hasAdvertisedService: true
        ), .none)

        // Wireless debugging switched off: the port is closed everywhere.
        let refused = revokedFailures.map {
            ADBConnectionFailure(
                endpoint: $0.endpoint,
                detail: "failed to connect to '\($0.endpoint)': Connection refused"
            )
        }
        XCTAssertEqual(ADBDeviceRecoveryPolicy.recoveryToConfirm(
            consecutiveFailures: 5,
            failures: refused,
            probedEndpoint: "192.0.2.10:43545",
            hasAdvertisedService: true
        ), .none)

        // A route failure on the preferred address still means restart, even
        // when the other addresses were rejected without a reason.
        let routeFirst = [ADBConnectionFailure(
            endpoint: "192.0.2.10:43545",
            detail: "failed to connect to '192.0.2.10:43545': No route to host"
        )] + Array(revokedFailures.dropFirst())
        XCTAssertEqual(ADBDeviceRecoveryPolicy.recoveryToConfirm(
            consecutiveFailures: 3,
            failures: routeFirst,
            probedEndpoint: "192.0.2.10:43545",
            hasAdvertisedService: true
        ), .restartServer)

        // The probed address must be among the failures at all.
        XCTAssertEqual(ADBDeviceRecoveryPolicy.recoveryToConfirm(
            consecutiveFailures: 3,
            failures: revokedFailures,
            probedEndpoint: "192.0.2.99:43545",
            hasAdvertisedService: true
        ), .none)
    }

    func testAuthorizedTransportClearsPerDeviceRecoveryVerdicts() {
        let service = BonjourService(
            name: remembered.serviceName,
            type: BonjourService.connectType,
            domain: "local.",
            hosts: ["192.0.2.10", "fd00::10"],
            port: 43545,
            interfaceIndex: 4
        )
        var pairingRequired: Set<String> = [remembered.serviceName, "other-phone"]

        pairingRequired.subtract(WirelessDeviceResolver.authorizedRememberedIDs(
            transports: [ADBTransport(serial: "[fd00::10]:43545", state: .unauthorized, attributes: [:])],
            services: [service],
            rememberedDevices: [remembered]
        ))
        XCTAssertEqual(pairingRequired, [remembered.serviceName, "other-phone"])

        pairingRequired.subtract(WirelessDeviceResolver.authorizedRememberedIDs(
            transports: [ADBTransport(serial: "[fd00::10]:43545", state: .authorized, attributes: [:])],
            services: [service],
            rememberedDevices: [remembered]
        ))
        XCTAssertEqual(pairingRequired, ["other-phone"])
    }

    func testNeedsPairingRowTitle() {
        XCTAssertEqual(WirelessDeviceState.needsPairing.title, "Needs pairing")
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
