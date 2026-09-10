import XCTest
import dnssd
@testable import wADB

final class BonjourCorrelationTests: XCTestCase {
    func testAddressBatchPublishesUsableResultsWhenOtherFamilyEndsWithError() {
        XCTAssertFalse(BonjourDiscovery.shouldPublishAddressResults(
            flags: DNSServiceFlags(kDNSServiceFlagsMoreComing),
            errorCode: DNSServiceErrorType(kDNSServiceErr_NoError),
            hasResolvedAddresses: true,
            removedAddressInBatch: false
        ))
        XCTAssertTrue(BonjourDiscovery.shouldPublishAddressResults(
            flags: 0,
            errorCode: DNSServiceErrorType(kDNSServiceErr_NoSuchRecord),
            hasResolvedAddresses: true,
            removedAddressInBatch: false
        ))
        XCTAssertFalse(BonjourDiscovery.shouldPublishAddressResults(
            flags: 0,
            errorCode: DNSServiceErrorType(kDNSServiceErr_NoSuchRecord),
            hasResolvedAddresses: false,
            removedAddressInBatch: false
        ))
        XCTAssertTrue(BonjourDiscovery.shouldPublishAddressResults(
            flags: 0,
            errorCode: DNSServiceErrorType(kDNSServiceErr_NoSuchRecord),
            hasResolvedAddresses: false,
            removedAddressInBatch: true
        ))
    }

    func testServiceTypeNormalizesDNSServiceTrailingDot() {
        let service = BonjourService(
            name: "adb-connect", type: "_adb-tls-connect._tcp.", domain: "local.",
            host: "192.0.2.10", port: 37001, interfaceIndex: 4
        )

        XCTAssertEqual(service.type, BonjourService.connectType)
    }

    func testPairingRecordCorrelatesOnlyToConnectRecordOnSameAddressAndInterface() {
        let pairing = BonjourService(
            name: "adb-pairing", type: BonjourService.pairingType, domain: "local.",
            host: "192.0.2.10", port: 33001, interfaceIndex: 4
        )
        let expected = BonjourService(
            name: "adb-connect", type: BonjourService.connectType, domain: "local.",
            host: "192.0.2.10", port: 37001, interfaceIndex: 4
        )
        let wrongAddress = BonjourService(
            name: "adb-other", type: BonjourService.connectType, domain: "local.",
            host: "192.0.2.11", port: 37002, interfaceIndex: 4
        )
        let wrongInterface = BonjourService(
            name: "adb-other-interface", type: BonjourService.connectType, domain: "local.",
            host: "192.0.2.10", port: 37003, interfaceIndex: 9
        )

        XCTAssertEqual(
            BonjourCorrelator.connectService(for: pairing, among: [wrongAddress, wrongInterface, expected]),
            expected
        )
    }

    func testPairingRecordFallsBackToUniqueConnectRecordOnSameHost() {
        let pairing = BonjourService(
            name: "adb-pairing", type: BonjourService.pairingType, domain: "local.",
            host: "192.0.2.10", port: 33001, interfaceIndex: 4
        )
        let connect = BonjourService(
            name: "adb-connect", type: BonjourService.connectType, domain: "local.",
            host: "192.0.2.10", port: 37001, interfaceIndex: 9
        )

        XCTAssertEqual(
            BonjourCorrelator.connectService(for: pairing, among: [connect]),
            connect
        )
    }

    func testEndpointFormatsIPv6ForADB() {
        let service = BonjourService(
            name: "adb-connect", type: BonjourService.connectType, domain: "local.",
            host: "fe80::1234%en0", port: 37001, interfaceIndex: 4
        )
        XCTAssertEqual(service.endpoint, "[fe80::1234%en0]:37001")
    }

    func testPairingPersistsTheAuthorizedSecondaryBonjourEndpoint() {
        let service = BonjourService(
            name: "adb-connect", type: BonjourService.connectType, domain: "local.",
            hosts: ["192.0.2.10", "fd00::10"], port: 37001, interfaceIndex: 4
        )
        let transport = ADBTransport(
            serial: "[fd00::10]:37001",
            state: .authorized,
            attributes: [:]
        )

        XCTAssertEqual(
            ADBRememberedEndpointResolver.resolve(
                service: service,
                authorizedTransport: transport
            ),
            ADBRememberedEndpoint(endpoint: "[fd00::10]:37001", host: "fd00::10")
        )
    }

    func testPairingResolvesNewAuthorizedTransportThroughItsConnectService() {
        let pairing = BonjourService(
            name: "studio-request", type: BonjourService.pairingType, domain: "local.",
            host: "192.0.2.10", port: 33001, interfaceIndex: 4
        )
        let connect = BonjourService(
            name: "adb-phone", type: BonjourService.connectType, domain: "local.",
            host: "192.0.2.10", port: 37001, interfaceIndex: 9
        )
        let transport = ADBTransport(
            serial: "adb-phone._adb-tls-connect._tcp",
            state: .authorized,
            attributes: ["model": "Example_Phone"]
        )

        let resolved = PairingCoordinator.resolveAuthorizedConnection(
            transports: [transport],
            services: [connect],
            preferredService: nil,
            pairingService: pairing,
            excludingAuthorizedSerials: []
        )

        XCTAssertEqual(resolved?.0, connect)
        XCTAssertEqual(resolved?.1, transport)
    }

    func testPairingDoesNotAdoptPreviouslyAuthorizedTransport() {
        let connect = BonjourService(
            name: "adb-phone", type: BonjourService.connectType, domain: "local.",
            host: "192.0.2.10", port: 37001, interfaceIndex: 4
        )
        let transport = ADBTransport(
            serial: "adb-phone._adb-tls-connect._tcp",
            state: .authorized,
            attributes: ["model": "Example_Phone"]
        )

        XCTAssertNil(PairingCoordinator.resolveAuthorizedConnection(
            transports: [transport],
            services: [connect],
            preferredService: connect,
            pairingService: nil,
            excludingAuthorizedSerials: [transport.serial]
        ))
    }

    func testPairingAdoptsCorrelatedAlreadyAuthorizedTransport() {
        let pairing = BonjourService(
            name: "studio-request", type: BonjourService.pairingType, domain: "local.",
            host: "192.0.2.10", port: 33001, interfaceIndex: 4
        )
        let connect = BonjourService(
            name: "adb-phone", type: BonjourService.connectType, domain: "local.",
            host: "192.0.2.10", port: 37001, interfaceIndex: 9
        )
        let transport = ADBTransport(
            serial: "adb-phone._adb-tls-connect._tcp",
            state: .authorized,
            attributes: ["model": "Example_Phone"]
        )

        let resolved = PairingCoordinator.resolveAuthorizedConnection(
            transports: [transport],
            services: [connect],
            preferredService: nil,
            pairingService: pairing,
            excludingAuthorizedSerials: [transport.serial]
        )

        XCTAssertEqual(resolved?.0, connect)
        XCTAssertEqual(resolved?.1, transport)
    }

    func testPairingAdoptsAuthorizedWirelessTransportByStableTargetHost() {
        let pairing = BonjourService(
            name: "studio-request", type: BonjourService.pairingType, domain: "local.",
            host: "fe80::1234%en0", targetHost: "Example_Phone.local.",
            port: 33001, interfaceIndex: 9
        )
        let connect = BonjourService(
            name: "adb-phone", type: BonjourService.connectType, domain: "local.",
            host: "192.0.2.10", targetHost: "example_phone.local",
            port: 37001, interfaceIndex: 4
        )
        let transport = ADBTransport(
            serial: "adb-phone._adb-tls-connect._tcp",
            state: .authorized,
            attributes: ["model": "Example_Phone"]
        )

        let resolved = PairingCoordinator.resolveAuthorizedConnection(
            transports: [transport],
            services: [connect],
            preferredService: nil,
            pairingService: pairing,
            excludingAuthorizedSerials: [transport.serial]
        )

        XCTAssertEqual(resolved?.0, connect)
        XCTAssertEqual(resolved?.1, transport)
    }

    func testPairingDoesNotAdoptLoneAuthorizedTransportFromDifferentTargetHost() {
        let pairing = BonjourService(
            name: "studio-request", type: BonjourService.pairingType, domain: "local.",
            host: "fe80::1234%en0", targetHost: "Android_NewPhone.local.",
            port: 33001, interfaceIndex: 4
        )
        let connect = BonjourService(
            name: "adb-phone", type: BonjourService.connectType, domain: "local.",
            host: "192.0.2.10", targetHost: "Example_Existing.local.",
            port: 37001, interfaceIndex: 4
        )
        let transport = ADBTransport(
            serial: "adb-phone._adb-tls-connect._tcp",
            state: .authorized,
            attributes: ["model": "Example_Phone"]
        )

        XCTAssertNil(PairingCoordinator.resolveAuthorizedConnection(
            transports: [transport],
            services: [connect],
            preferredService: nil,
            pairingService: pairing,
            excludingAuthorizedSerials: [transport.serial]
        ))
    }

    func testPairingDoesNotTreatUSBTransportAsWirelessPairingSuccess() {
        let pairing = BonjourService(
            name: "studio-request", type: BonjourService.pairingType, domain: "local.",
            host: "192.0.2.10", port: 33001, interfaceIndex: 4
        )
        let connect = BonjourService(
            name: "adb-phone", type: BonjourService.connectType, domain: "local.",
            host: "192.0.2.10", port: 37001, interfaceIndex: 4
        )
        let usb = ADBTransport(
            serial: "EXAMPLE-USB-SERIAL",
            state: .authorized,
            attributes: ["model": "Example_Phone"]
        )

        XCTAssertNil(PairingCoordinator.resolveAuthorizedConnection(
            transports: [usb],
            services: [connect],
            preferredService: connect,
            pairingService: pairing,
            excludingAuthorizedSerials: []
        ))
    }
}
