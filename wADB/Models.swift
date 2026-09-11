import Foundation

enum ADBTransportState: Equatable {
    case authorized
    case unauthorized
    case offline
    case other(String)

    init(adbValue: String) {
        switch adbValue {
        case "device": self = .authorized
        case "unauthorized": self = .unauthorized
        case "offline": self = .offline
        default: self = .other(adbValue)
        }
    }
}

struct ADBTransport: Equatable {
    let serial: String
    let state: ADBTransportState
    let attributes: [String: String]

    var fingerprint: String? {
        let values = [attributes["product"], attributes["model"], attributes["device"]]
        guard values.contains(where: { $0 != nil }) else { return nil }
        return values.map { $0 ?? "" }.joined(separator: "|")
    }

    var modelDisplayName: String {
        (attributes["model"] ?? attributes["device"] ?? "Android device")
            .replacingOccurrences(of: "_", with: " ")
    }

    var connectServiceName: String? {
        let suffix = ".\(BonjourService.connectType)"
        guard serial.hasSuffix(suffix) else { return nil }
        return String(serial.dropLast(suffix.count))
    }
}

struct ADBPhysicalDevice: Equatable {
    let key: String
    let transports: [ADBTransport]

    var isAuthorized: Bool { transports.contains { $0.state == .authorized } }
    var displayName: String { transports.first?.modelDisplayName ?? "Android device" }
}

/// Non-sensitive identity retained after a successful QR pairing. Connection
/// state is never persisted; endpoint and host are only fallback correlation
/// hints for older ADB Wi-Fi implementations.
struct LastVerifiedDevice: Codable, Equatable {
    let endpoint: String
    let host: String
    let serviceName: String
    let displayName: String
    let fingerprint: String?
}

struct BonjourService: Hashable {
    static let pairingType = "_adb-tls-pairing._tcp"
    static let connectType = "_adb-tls-connect._tcp"

    let name: String
    let type: String
    let domain: String
    let hosts: [String]
    let targetHost: String?
    let port: UInt16
    let interfaceIndex: UInt32

    init(
        name: String,
        type: String,
        domain: String,
        host: String,
        targetHost: String? = nil,
        port: UInt16,
        interfaceIndex: UInt32
    ) {
        self.init(
            name: name,
            type: type,
            domain: domain,
            hosts: [host],
            targetHost: targetHost,
            port: port,
            interfaceIndex: interfaceIndex
        )
    }

    init(
        name: String,
        type: String,
        domain: String,
        hosts: [String],
        targetHost: String? = nil,
        port: UInt16,
        interfaceIndex: UInt32
    ) {
        precondition(!hosts.isEmpty, "A resolved Bonjour service must have at least one address")
        self.name = name
        self.type = type.hasSuffix(".") ? String(type.dropLast()) : type
        self.domain = domain
        self.hosts = Self.orderedHosts(hosts)
        self.targetHost = targetHost
        self.port = port
        self.interfaceIndex = interfaceIndex
    }

    var host: String { hosts[0] }

    var endpoint: String {
        Self.endpoint(host: host, port: port)
    }

    var endpoints: [String] { hosts.map { Self.endpoint(host: $0, port: port) } }

    var identity: String {
        "\(name)|\(type)|\(domain)|\(interfaceIndex)"
    }

    var normalizedHost: String {
        normalizedHosts[0]
    }

    var normalizedHosts: [String] { hosts.map(Self.normalizedHost) }

    var normalizedTargetHost: String? {
        guard var value = targetHost?.lowercased(), !value.isEmpty else { return nil }
        while value.hasSuffix(".") { value.removeLast() }
        return value
    }

    private static func endpoint(host: String, port: UInt16) -> String {
        host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
    }

    private static func orderedHosts(_ hosts: [String]) -> [String] {
        hosts.sorted { left, right in
            let leftRank = addressRank(left)
            let rightRank = addressRank(right)
            return leftRank == rightRank ? left < right : leftRank < rightRank
        }
    }

    private static func addressRank(_ host: String) -> Int {
        guard host.contains(":") else { return 0 }
        let unscoped = host.split(separator: "%", maxSplits: 1).first?.lowercased() ?? ""
        return unscoped.hasPrefix("fe80:") ? 2 : 1
    }

    private static func normalizedHost(_ host: String) -> String {
        var value = host.lowercased()
        if value.hasPrefix("[") && value.hasSuffix("]") {
            value.removeFirst()
            value.removeLast()
        }
        while value.hasSuffix(".") { value.removeLast() }
        return value
    }
}

enum BonjourCorrelator {
    static func connectService(
        for pairingService: BonjourService,
        among services: [BonjourService]
    ) -> BonjourService? {
        if let exact = services.first(where: {
            $0.type == BonjourService.connectType
                && $0.interfaceIndex == pairingService.interfaceIndex
                && sameDeviceHost($0, pairingService)
        }) {
            return exact
        }
        let sameHost = services.filter {
            $0.type == BonjourService.connectType
                && sameDeviceHost($0, pairingService)
        }
        return sameHost.count == 1 ? sameHost.first : nil
    }

    /// The device's own service name is the identity; a host match is only a
    /// fallback for older ADB Wi-Fi builds that advertise no stable name. The
    /// exact name is checked across every service first, because after DHCP
    /// another device can advertise the remembered host and sort earlier.
    static func connectService(
        for lastDevice: LastVerifiedDevice,
        among services: [BonjourService]
    ) -> BonjourService? {
        let connectServices = services.filter { $0.type == BonjourService.connectType }
        if let exact = connectServices.first(where: { $0.name == lastDevice.serviceName }) {
            return exact
        }
        let host = normalizedHost(lastDevice.host)
        return connectServices.first { $0.normalizedHosts.contains(host) }
    }

    private static func normalizedHost(_ host: String) -> String {
        var value = host.lowercased()
        while value.hasSuffix(".") { value.removeLast() }
        return value
    }

    private static func sameDeviceHost(
        _ left: BonjourService,
        _ right: BonjourService
    ) -> Bool {
        if let leftTarget = left.normalizedTargetHost,
           let rightTarget = right.normalizedTargetHost,
           leftTarget == rightTarget {
            return true
        }
        return !Set(left.normalizedHosts).isDisjoint(with: right.normalizedHosts)
    }
}

enum WirelessDeviceState: Equatable {
    case connected
    case connecting
    case restartRecommended
    case needsPairing

    var title: String {
        switch self {
        case .connected: "Connected"
        case .connecting: "Connecting"
        case .restartRecommended: "Restart ADB"
        case .needsPairing: "Needs pairing"
        }
    }
}

struct WirelessDevice: Equatable {
    let id: String
    let displayName: String
    let endpoint: String?
    let state: WirelessDeviceState
    /// The remembered device this row stands for, when there is one. The row
    /// `id` follows the live Bonjour name, which differs from the remembered
    /// name whenever the device was correlated by host fallback.
    var rememberedServiceName: String? = nil

    /// The key per-device recovery verdicts (restart ADB, needs pairing) are
    /// recorded under. Reconnect records them by remembered service name, so
    /// every lookup that starts from a row goes through this, never `id`.
    var recoveryID: String { rememberedServiceName ?? id }
}

enum WirelessDeviceResolver {
    static func resolve(
        transports: [ADBTransport],
        services: [BonjourService],
        rememberedDevices: [LastVerifiedDevice]
    ) -> [WirelessDevice] {
        let connectServices = services.filter { $0.type == BonjourService.connectType }
        let wirelessTransports = transports.filter {
            isWireless($0, services: connectServices, rememberedDevices: rememberedDevices)
        }
        let transportGroups = groupByWirelessIdentity(
            wirelessTransports,
            services: connectServices,
            rememberedDevices: rememberedDevices
        )
        var devices: [String: WirelessDevice] = [:]

        for group in transportGroups {
            guard let representative = preferredTransport(in: group) else { continue }
            let remembered = rememberedDevices.first { device in
                group.contains {
                    matches($0, rememberedDevice: device, services: connectServices)
                }
            }
            let service = service(
                for: group,
                rememberedDevice: remembered,
                among: connectServices
            )
            let id = service?.name
                ?? representative.connectServiceName
                ?? remembered?.serviceName
                ?? representative.serial
            let displayName = representative.modelDisplayName == "Android device"
                ? (remembered?.displayName ?? "Android device")
                : representative.modelDisplayName
            let state: WirelessDeviceState
            if group.contains(where: { $0.state == .authorized }) {
                state = .connected
            } else if group.contains(where: { $0.state == .unauthorized }) {
                state = .needsPairing
            } else {
                state = .connecting
            }
            devices[id] = WirelessDevice(
                id: id,
                displayName: displayName,
                endpoint: service?.endpoint ?? remembered?.endpoint ?? endpoint(from: representative.serial),
                state: state,
                rememberedServiceName: remembered?.serviceName
            )
        }

        // A QR-paired device may advertise before ADB finishes its transport.
        for remembered in rememberedDevices {
            guard let service = BonjourCorrelator.connectService(
                for: remembered,
                among: connectServices
            ), devices[service.name] == nil else { continue }
            devices[service.name] = WirelessDevice(
                id: service.name,
                displayName: remembered.displayName,
                endpoint: service.endpoint,
                state: .connecting,
                rememberedServiceName: remembered.serviceName
            )
        }

        return devices.values.sorted {
            if $0.state == $1.state {
                return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
            return stateRank($0.state) < stateRank($1.state)
        }
    }

    /// Service names of remembered devices that currently have an authorized
    /// transport. Any per-device recovery verdict (restart, needs pairing) is
    /// void for these, because the phone has plainly accepted this host.
    static func authorizedRememberedIDs(
        transports: [ADBTransport],
        services: [BonjourService],
        rememberedDevices: [LastVerifiedDevice]
    ) -> Set<String> {
        Set(rememberedDevices.compactMap { remembered in
            transports.contains {
                $0.state == .authorized
                    && matches($0, rememberedDevice: remembered, services: services)
            } ? remembered.serviceName : nil
        })
    }

    static func isWireless(
        _ transport: ADBTransport,
        services: [BonjourService],
        rememberedDevices: [LastVerifiedDevice]
    ) -> Bool {
        if transport.serial.hasPrefix("emulator-") { return false }
        if transport.connectServiceName != nil { return true }
        if services.contains(where: {
            $0.type == BonjourService.connectType && $0.endpoints.contains(transport.serial)
        }) {
            return true
        }
        return rememberedDevices.contains {
            matches(transport, rememberedDevice: $0, services: services)
        }
    }

    static func matches(
        _ transport: ADBTransport,
        rememberedDevice: LastVerifiedDevice,
        services: [BonjourService]
    ) -> Bool {
        if transport.serial == rememberedDevice.endpoint
            || transport.connectServiceName == rememberedDevice.serviceName {
            return true
        }
        if let service = BonjourCorrelator.connectService(
            for: rememberedDevice,
            among: services
        ), service.endpoints.contains(transport.serial)
            || transport.connectServiceName == service.name {
            return true
        }
        guard let host = endpointHost(transport.serial),
              host == normalizedHost(rememberedDevice.host),
              let fingerprint = rememberedDevice.fingerprint else {
            return false
        }
        return transport.fingerprint == fingerprint
    }

    private static func preferredTransport(in transports: [ADBTransport]) -> ADBTransport? {
        transports.first(where: { $0.state == .authorized })
            ?? transports.first(where: { $0.state == .unauthorized })
            ?? transports.first
    }

    private static func groupByWirelessIdentity(
        _ transports: [ADBTransport],
        services: [BonjourService],
        rememberedDevices: [LastVerifiedDevice]
    ) -> [[ADBTransport]] {
        var order: [String] = []
        var groups: [String: [ADBTransport]] = [:]
        for transport in transports {
            let matchingService = services.first {
                $0.name == transport.connectServiceName || $0.endpoints.contains(transport.serial)
            }
            let remembered = rememberedDevices.first {
                matches(transport, rememberedDevice: $0, services: services)
            }
            let key = matchingService?.name
                ?? transport.connectServiceName
                ?? remembered?.serviceName
                ?? transport.serial
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(transport)
        }
        return order.compactMap { groups[$0] }
    }

    private static func service(
        for transports: [ADBTransport],
        rememberedDevice: LastVerifiedDevice?,
        among services: [BonjourService]
    ) -> BonjourService? {
        for transport in transports {
            if let match = services.first(where: {
                $0.name == transport.connectServiceName || $0.endpoints.contains(transport.serial)
            }) {
                return match
            }
        }
        guard let rememberedDevice else { return nil }
        return BonjourCorrelator.connectService(for: rememberedDevice, among: services)
    }

    private static func endpoint(from serial: String) -> String? {
        endpointHost(serial) == nil ? nil : serial
    }

    private static func endpointHost(_ endpoint: String) -> String? {
        if endpoint.hasPrefix("["), let closingBracket = endpoint.firstIndex(of: "]") {
            return normalizedHost(String(
                endpoint[endpoint.index(after: endpoint.startIndex)..<closingBracket]
            ))
        }
        guard let colon = endpoint.lastIndex(of: ":"),
              endpoint[endpoint.index(after: colon)...].allSatisfy(\.isNumber) else {
            return nil
        }
        return normalizedHost(String(endpoint[..<colon]))
    }

    private static func normalizedHost(_ host: String) -> String {
        host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    }

    private static func stateRank(_ state: WirelessDeviceState) -> Int {
        switch state {
        case .connected: 0
        case .restartRecommended: 1
        case .connecting: 2
        case .needsPairing: 3
        }
    }
}

/// Pacing for the level-triggered health check that replaced the old
/// edge-triggered supervisor. Recovery must never depend on `track-devices`
/// reporting an edge: that stream can go silent without erroring, which is
/// indistinguishable from a healthy idle connection.
enum ADBServerRecoveryAction: Equatable {
    case restartObserver
    case startServer
}

enum ADBWatchdogPolicy {
    /// How often the health check runs, regardless of what adb has told us.
    static let tickInterval: TimeInterval = 15

    /// A device refusing a connection says nothing about server health. Only
    /// repeated failures to query the shared server earn an explicit probe.
    static let snapshotFailuresBeforeProbe = 3

    static func shouldProbeServer(snapshotFailures: Int) -> Bool {
        snapshotFailures >= snapshotFailuresBeforeProbe
    }

    static func recoveryAction(serverResponsive: Bool) -> ADBServerRecoveryAction {
        serverResponsive ? .restartObserver : .startServer
    }
}

enum ADBAutomaticReconnectPolicy {
    static func shouldReconnect(
        _ device: LastVerifiedDevice,
        transports: [ADBTransport],
        services: [BonjourService]
    ) -> Bool {
        !transports.contains { transport in
            guard WirelessDeviceResolver.matches(
                transport,
                rememberedDevice: device,
                services: services
            ) else { return false }
            switch transport.state {
            case .authorized, .unauthorized:
                return true
            case .offline, .other:
                return false
            }
        }
    }

    /// Whether a failed dial should move on to the next advertised address.
    /// Authorization is the one failure that must not fail over: `adb connect`
    /// reports it before the tracker publishes the unauthorized transport, so
    /// the failure text is checked as well as the transport snapshot.
    static func shouldContinueFailover(
        _ device: LastVerifiedDevice,
        attemptedEndpoint: String,
        failureDetail: String,
        transports: [ADBTransport],
        services: [BonjourService]
    ) -> Bool {
        guard !ADBOutputParser.connectRequiresAuthorization(failureDetail) else { return false }
        return !transports.contains { transport in
            guard transport.state == .authorized || transport.state == .unauthorized else {
                return false
            }
            return transport.serial == attemptedEndpoint
                || WirelessDeviceResolver.matches(
                    transport,
                    rememberedDevice: device,
                    services: services
                )
        }
    }

    /// A failover sequence dials the endpoint list it started with. When
    /// Bonjour republishes the device with a rotated port or a different
    /// address set mid-sequence, the remaining endpoints are stale and the
    /// sequence should stop so reconciliation can start over from the live
    /// target. A transient empty publish keeps the current target.
    static func targetIsCurrent(
        _ target: ADBConnectionTarget,
        device: LastVerifiedDevice,
        services: [BonjourService]
    ) -> Bool {
        ADBConnectionTargetResolver.resolve(
            device: device,
            services: services,
            previous: target
        ) == target
    }
}

struct ADBConnectionRetryState: Equatable {
    private(set) var targetIdentity: String?
    private(set) var consecutiveFailures = 0
    private(set) var nextAttemptAt = Date.distantPast

    mutating func shouldAttempt(targetIdentity: String, now: Date) -> Bool {
        resetIfTargetChanged(to: targetIdentity)
        return now >= nextAttemptAt
    }

    mutating func recordFailure(targetIdentity: String, now: Date) -> TimeInterval {
        resetIfTargetChanged(to: targetIdentity)
        consecutiveFailures += 1
        let delay = Self.delay(afterFailureCount: consecutiveFailures)
        nextAttemptAt = now.addingTimeInterval(delay)
        return delay
    }

    static func delay(afterFailureCount failureCount: Int) -> TimeInterval {
        let delays: [TimeInterval] = [15, 30, 60, 120, 300]
        return delays[min(max(failureCount, 1) - 1, delays.count - 1)]
    }

    private mutating func resetIfTargetChanged(to targetIdentity: String) {
        guard self.targetIdentity != targetIdentity else { return }
        self.targetIdentity = targetIdentity
        consecutiveFailures = 0
        nextAttemptAt = .distantPast
    }
}

struct ADBConnectionTarget: Equatable {
    let endpoints: [String]
    /// Stable across IPv4/IPv6 address changes, but changes when Android
    /// rotates the wireless-debugging port.
    let retryIdentity: String

    var endpoint: String { endpoints[0] }

    init(device: LastVerifiedDevice, service: BonjourService?) {
        endpoints = service?.endpoints ?? [device.endpoint]
        let port = service.map { String($0.port) }
            ?? Self.port(from: device.endpoint)
            ?? device.endpoint
        retryIdentity = "\(device.serviceName)|\(port)"
    }

    private static func port(from endpoint: String) -> String? {
        guard let colon = endpoint.lastIndex(of: ":") else { return nil }
        let port = endpoint[endpoint.index(after: colon)...]
        return port.allSatisfy(\.isNumber) ? String(port) : nil
    }
}

struct ADBConnectionFailure: Equatable {
    let endpoint: String
    let detail: String
}

struct ADBRememberedEndpoint: Equatable {
    let endpoint: String
    let host: String
}

enum ADBRememberedEndpointResolver {
    static func resolve(
        service: BonjourService,
        authorizedTransport: ADBTransport
    ) -> ADBRememberedEndpoint {
        if service.endpoints.contains(authorizedTransport.serial),
           let parsed = ADBNetworkEndpoint.parse(authorizedTransport.serial) {
            return ADBRememberedEndpoint(
                endpoint: authorizedTransport.serial,
                host: parsed.host
            )
        }
        return ADBRememberedEndpoint(endpoint: service.endpoint, host: service.host)
    }

    /// Re-derives every remembered endpoint from the transports ADB actually
    /// reports as authorized. This is the single place that keeps remembered
    /// devices in step with the transport that authorized, whichever path
    /// connected it: pairing, automatic failover, or an `adb connect` issued
    /// outside wADB. A matching transport on the stored endpoint always wins so
    /// dual-stack devices do not flip between addresses.
    ///
    /// Only exact identity counts here: the stored endpoint itself, or an
    /// address advertised under the device's own Bonjour service name. The
    /// host and fingerprint heuristics that `WirelessDeviceResolver.matches`
    /// uses for display are deliberately excluded, because persisting a fuzzy
    /// match after DHCP hands one phone's address to another would let
    /// `PairedDeviceStore.upsert` overwrite the other phone's record.
    static func reconcile(
        _ devices: [LastVerifiedDevice],
        transports: [ADBTransport],
        services: [BonjourService]
    ) -> [LastVerifiedDevice] {
        devices.map { device in
            let matching = transports.filter { transport in
                transport.state == .authorized
                    && ADBNetworkEndpoint.parse(transport.serial) != nil
                    && isExactEndpoint(transport.serial, of: device, services: services)
            }
            guard !matching.contains(where: { $0.serial == device.endpoint }),
                  let transport = matching.first else { return device }
            return resolve(device: device, connectedEndpoint: transport.serial, services: services)
        }
    }

    private static func isExactEndpoint(
        _ endpoint: String,
        of device: LastVerifiedDevice,
        services: [BonjourService]
    ) -> Bool {
        endpoint == device.endpoint
            || services.contains {
                $0.type == BonjourService.connectType
                    && $0.name == device.serviceName
                    && $0.endpoints.contains(endpoint)
            }
    }

    /// The device record to keep after `connectedEndpoint` authorized. The
    /// endpoint is adopted only when it is exactly this device's: the reconnect
    /// target may have been correlated by host alone, and after DHCP moves a
    /// host between phones that address belongs to someone else.
    static func resolve(
        device: LastVerifiedDevice,
        connectedEndpoint: String,
        services: [BonjourService]
    ) -> LastVerifiedDevice {
        guard connectedEndpoint != device.endpoint,
              isExactEndpoint(connectedEndpoint, of: device, services: services),
              let parsed = ADBNetworkEndpoint.parse(connectedEndpoint) else { return device }
        return LastVerifiedDevice(
            endpoint: connectedEndpoint,
            host: parsed.host,
            serviceName: device.serviceName,
            displayName: device.displayName,
            fingerprint: device.fingerprint
        )
    }
}

enum ADBConnectionFailurePolicy {
    static func combinedDetail(_ failures: [ADBConnectionFailure]) -> String {
        failures.map { "\($0.endpoint): \($0.detail)" }.joined(separator: "; ")
    }

    static func recoveryDetail(
        for endpoint: String,
        failures: [ADBConnectionFailure]
    ) -> String? {
        failures.first { $0.endpoint == endpoint }?.detail
    }
}

struct ADBNetworkEndpoint: Equatable {
    let host: String
    let port: UInt16

    static func parse(_ endpoint: String) -> ADBNetworkEndpoint? {
        if endpoint.hasPrefix("["),
           let closingBracket = endpoint.firstIndex(of: "]") {
            let colon = endpoint.index(after: closingBracket)
            guard colon < endpoint.endIndex, endpoint[colon] == ":" else { return nil }
            let portStart = endpoint.index(after: colon)
            guard portStart < endpoint.endIndex else { return nil }
            let host = String(endpoint[endpoint.index(after: endpoint.startIndex)..<closingBracket])
            let portText = endpoint[portStart...]
            guard let port = UInt16(portText) else { return nil }
            return ADBNetworkEndpoint(host: host, port: port)
        }
        guard let colon = endpoint.lastIndex(of: ":"),
              let port = UInt16(endpoint[endpoint.index(after: colon)...]) else { return nil }
        let host = String(endpoint[..<colon])
        guard !host.contains(":") else { return nil }
        return ADBNetworkEndpoint(host: host, port: port)
    }
}

/// What a remembered device's repeated reconnect failures point at once a
/// TCP probe has confirmed the preferred address accepts connections.
enum ADBDeviceRecoveryAction: Equatable {
    case none
    /// The host reaches the phone but the ADB server cannot; restart it.
    case restartServer
    /// The phone reaches the host and turns it away; pair again.
    case needsPairing
}

enum ADBDeviceRecoveryPolicy {
    static let failuresBeforeReachabilityCheck = 2
    /// Deliberately later than the restart check: a phone can reject one or
    /// two handshakes while it re-keys, roams, or is still bringing adbd up
    /// after wireless debugging is toggled on. With the 15s/30s backoff the
    /// third round lands roughly a minute after the native session dropped.
    static let failuresBeforePairingRecommendation = 3

    /// Names the recovery that a successful TCP probe of `probedEndpoint`
    /// would confirm, or `.none` when nothing should be probed.
    ///
    /// Restart: the preferred address fails with "no route to host" while
    /// Bonjour still advertises the phone. The ADB server's routing is wedged
    /// even though the host has a route, which the probe verifies.
    ///
    /// Needs pairing: every advertised address was dialled and every one came
    /// back as a bare "failed to connect to <endpoint>" with no socket reason.
    /// That is what the server prints when TCP succeeds but the phone rejects
    /// the TLS handshake (`SSLV3_ALERT_CERTIFICATE_UNKNOWN`), which is what
    /// happens after the user forgets this host on the phone. A phone with
    /// wireless debugging switched off closes the port, so its failure
    /// carries a reason ("Connection refused") and the probe fails; neither
    /// reaches this state. Remaining false positives: a stale Bonjour record
    /// whose port has been reused by an unrelated TLS service, or a phone
    /// whose adbd is mid-restart across three consecutive rounds. Both
    /// self-heal, because the recommendation is dropped as soon as the device
    /// authorizes or Bonjour publishes a different port.
    static func recoveryToConfirm(
        consecutiveFailures: Int,
        failures: [ADBConnectionFailure],
        probedEndpoint: String,
        hasAdvertisedService: Bool
    ) -> ADBDeviceRecoveryAction {
        guard hasAdvertisedService,
              let probedDetail = ADBConnectionFailurePolicy.recoveryDetail(
                for: probedEndpoint,
                failures: failures
              ) else { return .none }
        if consecutiveFailures >= failuresBeforeReachabilityCheck,
           probedDetail.localizedCaseInsensitiveContains("no route to host") {
            return .restartServer
        }
        if consecutiveFailures >= failuresBeforePairingRecommendation,
           failures.allSatisfy({ ADBOutputParser.connectWasRejectedWithoutReason($0.detail) }) {
            return .needsPairing
        }
        return .none
    }
}

enum ADBConnectionTargetResolver {
    static func resolve(
        device: LastVerifiedDevice,
        services: [BonjourService],
        previous: ADBConnectionTarget?
    ) -> ADBConnectionTarget {
        if let service = BonjourCorrelator.connectService(for: device, among: services) {
            return ADBConnectionTarget(device: device, service: service)
        }
        // DNSServiceGetAddrInfo publishes address-family changes incrementally
        // and refresh briefly publishes no services. Keep the last live target
        // instead of bouncing back to a stale endpoint persisted at pairing.
        return previous ?? ADBConnectionTarget(device: device, service: nil)
    }
}

enum LastVerifiedDeviceStore {
    private static let key = "lastVerifiedDevice"

    static func load(defaults: UserDefaults = .standard) -> LastVerifiedDevice? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(LastVerifiedDevice.self, from: data)
    }

    static func save(_ device: LastVerifiedDevice, defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(device) else { return }
        defaults.set(data, forKey: key)
    }

    static func clear(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key)
    }
}

enum PairedDeviceStore {
    private static let key = "pairedDevices"

    static func load(defaults: UserDefaults = .standard) -> [LastVerifiedDevice] {
        if let data = defaults.data(forKey: key),
           let devices = try? JSONDecoder().decode([LastVerifiedDevice].self, from: data) {
            return devices
        }
        if let legacy = LastVerifiedDeviceStore.load(defaults: defaults) {
            save([legacy], defaults: defaults)
            return [legacy]
        }
        return []
    }

    static func save(_ devices: [LastVerifiedDevice], defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(devices) else { return }
        defaults.set(data, forKey: key)
    }

    static func upsert(_ device: LastVerifiedDevice, defaults: UserDefaults = .standard) {
        var devices = load(defaults: defaults)
        devices.removeAll { $0.endpoint == device.endpoint || $0.serviceName == device.serviceName }
        devices.append(device)
        save(devices, defaults: defaults)
    }
}
